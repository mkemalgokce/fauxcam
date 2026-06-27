import Testing
@testable import Diagnostics

private struct StubInspector: DylibInspecting {
    let result: Result<DylibAudit, DylibInspectionError>
    func audit(dylibPath: String) async throws -> DylibAudit {
        switch result {
        case .success(let audit): return audit
        case .failure(let error): throw error
        }
    }
}

struct DoctorServiceTests {
    @Test func passesForLoadableDylib() async throws {
        let audit = DylibAudit(isSimulatorPlatform: true, isAdHocSigned: true, architectures: ["arm64", "x86_64"])
        let report = try await DoctorService(inspector: StubInspector(result: .success(audit))).diagnose(dylibPath: "/x/libFaux.dylib")
        #expect(report.passed)
        #expect(report.remediationLines.isEmpty)
        #expect(report.architectures == ["arm64", "x86_64"])
    }

    @Test func reportsRemediationPerUnmetRequirement() async throws {
        let audit = DylibAudit(isSimulatorPlatform: false, isAdHocSigned: false, architectures: ["arm64"])
        let report = try await DoctorService(inspector: StubInspector(result: .success(audit))).diagnose(dylibPath: "/x/libFaux.dylib")
        #expect(!report.passed)
        #expect(report.unmetRequirements == [.simulatorPlatform, .adHocSignature, .architecture("x86_64")])
        #expect(report.remediationLines.count == 3)
        #expect(report.remediationLines[0].contains("[platform]"))
        #expect(report.remediationLines[1].contains("[signature]"))
        #expect(report.remediationLines[1].contains("/x/libFaux.dylib"))
        #expect(report.remediationLines[2].contains("x86_64"))
    }

    @Test func propagatesInspectionError() async {
        let inspector = StubInspector(result: .failure(.toolFailed(tool: "lipo", exitCode: 1, message: "no such file")))
        await #expect(throws: DylibInspectionError.self) {
            _ = try await DoctorService(inspector: inspector).diagnose(dylibPath: "/missing.dylib")
        }
    }

    @Test func inspectionErrorDescriptionIsHumanReadable() {
        let error = DylibInspectionError.toolFailed(tool: "lipo", exitCode: 1, message: "lipo: file not found '/no/such.dylib'")
        #expect(error.description == "lipo failed: lipo: file not found '/no/such.dylib'")
        #expect(!error.description.contains("toolFailed("))
    }

    @Test func inspectionErrorDescriptionOmitsEmptyMessage() {
        let error = DylibInspectionError.toolFailed(tool: "otool", exitCode: 1, message: "")
        #expect(error.description == "otool failed")
    }
}
