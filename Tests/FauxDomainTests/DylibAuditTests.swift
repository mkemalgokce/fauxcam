import Testing
@testable import FauxDomain

@Test func loadableRequiresSimulatorAdHocAndFatArches() {
    let audit = DylibAudit(isSimulatorPlatform: true, isAdHocSigned: true, architectures: ["arm64", "x86_64"])
    #expect(audit.isLoadable)
}

@Test func missingArchitectureIsNotLoadable() {
    let audit = DylibAudit(isSimulatorPlatform: true, isAdHocSigned: true, architectures: ["arm64"])
    #expect(!audit.isLoadable)
}

@Test func nonSimulatorPlatformIsNotLoadable() {
    let audit = DylibAudit(isSimulatorPlatform: false, isAdHocSigned: true, architectures: ["arm64", "x86_64"])
    #expect(!audit.isLoadable)
}

@Test func unsignedIsNotLoadable() {
    let audit = DylibAudit(isSimulatorPlatform: true, isAdHocSigned: false, architectures: ["arm64", "x86_64"])
    #expect(!audit.isLoadable)
}
