import Testing
import FauxDomain
@testable import FauxApplication

private final class RecordingInspector: DylibInspecting, @unchecked Sendable {
    let stubbed: DylibAudit
    private(set) var receivedPath: String?

    init(stubbed: DylibAudit) { self.stubbed = stubbed }

    func audit(at path: String) throws -> DylibAudit {
        receivedPath = path
        return stubbed
    }
}

@Test func doctorForwardsPathAndReturnsInspectorAudit() throws {
    let expected = DylibAudit(isSimulatorPlatform: true, isAdHocSigned: true, architectures: ["arm64", "x86_64"])
    let inspector = RecordingInspector(stubbed: expected)
    let service = DoctorService(inspector: inspector)

    let result = try service.diagnose(dylibAt: "some/path.dylib")

    #expect(result == expected)
    #expect(inspector.receivedPath == "some/path.dylib")
}
