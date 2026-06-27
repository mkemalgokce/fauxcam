import Testing
@testable import Injection

struct AutoInjectionServiceTests {
    private func makeService(env: RecordEnv, xcode: RecordXcode) -> AutoInjectionService {
        AutoInjectionService(server: NoClientsServer(), env: env, xcode: xcode,
                             aspects: FixedAspects(), dylibPath: "/x/libFaux.dylib")
    }

    @Test func enableInjectsAllDevicesAndInstallsHook() async {
        let env = RecordEnv(), xcode = RecordXcode()
        let service = makeService(env: env, xcode: xcode)
        await service.enable(source: NoopProducer(), pool: NoopPool(), devices: ["ABC", "DEF"])
        #expect(await env.installed.sorted() == ["ABC", "DEF"])
        #expect(await xcode.installCount == 1)
        #expect(await service.injectedDeviceCount == 2)
    }

    @Test func syncInjectsOnlyNewlyBooted() async {
        let env = RecordEnv()
        let service = makeService(env: env, xcode: RecordXcode())
        await service.enable(source: NoopProducer(), pool: NoopPool(), devices: ["ABC"])
        await service.sync(devices: ["ABC", "DEF"])
        #expect(await env.installed == ["ABC", "DEF"])   // ABC from enable, DEF from sync — no re-inject of ABC
    }

    @Test func disableUninstallsBothVectors() async {
        let env = RecordEnv(), xcode = RecordXcode()
        let service = makeService(env: env, xcode: xcode)
        await service.enable(source: NoopProducer(), pool: NoopPool(), devices: ["ABC"])
        await service.disable()
        #expect(await env.uninstalled == ["ABC"])
        #expect(await xcode.uninstallCount == 1)
        #expect(await service.injectedDeviceCount == 0)
    }

    @Test func enableSurfacesBindFailureAndInjectsNothing() async {
        let env = RecordEnv()
        let service = AutoInjectionService(server: BindFailingServer(), env: env, xcode: RecordXcode(),
                                           aspects: FixedAspects(), dylibPath: "/x/libFaux.dylib")
        let result = await service.enable(source: NoopProducer(), pool: NoopPool(), devices: ["ABC"])
        if case .failed = result {} else { Issue.record("expected .failed, got \(result)") }
        #expect(await env.installed.isEmpty)
        #expect(await service.isActive == false)
        #expect(await service.injectedDeviceCount == 0)
    }

    @Test func enableBailsWhileTeardownIsMidFlight() async {
        let env = GatedUninstallEnv()
        let service = AutoInjectionService(server: NoClientsServer(), env: env, xcode: RecordXcode(),
                                           aspects: FixedAspects(), dylibPath: "/x/libFaux.dylib")
        await service.enable(source: NoopProducer(), pool: NoopPool(), devices: ["ABC"])

        let teardown = Task { await service.disable() }
        await env.waitUntilInsideUninstall()   // disable() has set serverTask=nil and is parked in uninstall

        let result = await service.enable(source: NoopProducer(), pool: NoopPool(), devices: ["NEW"])
        #expect(result == .active)               // bailed, did not re-arm
        #expect(await env.installed == ["ABC"])  // "NEW" was never injected

        await env.releaseUninstall()
        await teardown.value
        #expect(await service.injectedDeviceCount == 0)
    }

    @Test func failedInjectionStaysUninjectedAndRetriesOnNextSync() async {
        let env = PartialFailEnv(failing: ["DEF"])
        let service = AutoInjectionService(server: NoClientsServer(), env: env, xcode: RecordXcode(),
                                           aspects: FixedAspects(), dylibPath: "/x/libFaux.dylib")
        await service.enable(source: NoopProducer(), pool: NoopPool(), devices: ["ABC", "DEF"])
        #expect(await service.injectedDeviceCount == 1)   // only ABC succeeded; DEF failed and is not marked injected

        await service.sync(devices: ["ABC", "DEF"])        // DEF is still "newly" and gets retried
        #expect(await env.installed == ["ABC", "DEF", "DEF"])   // DEF attempted again on the next sync
        #expect(await service.injectedDeviceCount == 1)
    }

    @Test func cleanLeftoverUnsetsOnlyOurLeftoverDevices() async {
        let env = RecordEnv(leftover: ["LEFT"])
        let service = AutoInjectionService(server: NoClientsServer(), env: env, xcode: RecordXcode(),
                                           aspects: FixedAspects(), dylibPath: "/x/libFaux.dylib")
        await service.cleanLeftover(devices: ["LEFT", "OTHER"])
        #expect(await env.uninstalled == ["LEFT"])
    }

    @Test func resetCleansInjectedUnionLeftover() async {
        let env = RecordEnv(leftover: ["LEFT"]), xcode = RecordXcode()
        let service = makeService(env: env, xcode: xcode)
        await service.enable(source: NoopProducer(), pool: NoopPool(), devices: ["ABC"])
        await service.reset(devices: ["LEFT"])
        #expect(await Set(env.uninstalled) == ["ABC", "LEFT"])
        #expect(await xcode.uninstallCount == 1)
        #expect(await service.injectedDeviceCount == 0)
    }
}
