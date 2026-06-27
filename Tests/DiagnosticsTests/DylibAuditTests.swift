import Testing
@testable import Diagnostics

struct DylibAuditTests {
    @Test func loadableRequiresSimulatorAdHocAndBothArchitectures() {
        let audit = DylibAudit(isSimulatorPlatform: true, isAdHocSigned: true, architectures: ["arm64", "x86_64"])
        #expect(audit.isLoadable)
        #expect(audit.unmetRequirements.isEmpty)
    }

    @Test func missingArchitectureIsNotLoadable() {
        let audit = DylibAudit(isSimulatorPlatform: true, isAdHocSigned: true, architectures: ["arm64"])
        #expect(!audit.isLoadable)
        #expect(audit.unmetRequirements == [.architecture("x86_64")])
    }

    @Test func nonSimulatorPlatformIsNotLoadable() {
        let audit = DylibAudit(isSimulatorPlatform: false, isAdHocSigned: true, architectures: ["arm64", "x86_64"])
        #expect(!audit.isLoadable)
        #expect(audit.unmetRequirements == [.simulatorPlatform])
    }

    @Test func unsignedIsNotLoadable() {
        let audit = DylibAudit(isSimulatorPlatform: true, isAdHocSigned: false, architectures: ["arm64", "x86_64"])
        #expect(!audit.isLoadable)
        #expect(audit.unmetRequirements == [.adHocSignature])
    }

    @Test func unmetRequirementsListsEveryFailedCriterion() {
        let audit = DylibAudit(isSimulatorPlatform: false, isAdHocSigned: false, architectures: ["arm64"])
        #expect(audit.unmetRequirements == [.simulatorPlatform, .adHocSignature, .architecture("x86_64")])
    }
}
