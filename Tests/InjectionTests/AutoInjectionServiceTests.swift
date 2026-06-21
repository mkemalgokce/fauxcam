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
}
