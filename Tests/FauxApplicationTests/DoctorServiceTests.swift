import Testing
import FauxDomain
@testable import FauxApplication

private struct StubInspector: DylibInspecting {
    let stubbed: DylibAudit
    func audit(at path: String) throws -> DylibAudit { stubbed }
}

@Test func doctorReturnsAuditFromInspector() throws {
    let expected = DylibAudit(isSimulatorPlatform: true, isAdHocSigned: true, architectures: ["arm64", "x86_64"])
    let service = DoctorService(inspector: StubInspector(stubbed: expected))
    #expect(try service.diagnose(dylibAt: "any/path") == expected)
}
