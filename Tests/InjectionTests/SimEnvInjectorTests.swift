import Testing
import Foundation
@testable import Injection

struct SimEnvInjectorTests {
    @Test func installSetsDyldAndFrameSize() async {
        let runner = RecordingRunner()
        await SimEnvInjector(runner: runner).install(onDevices: ["ABC"], dylibPath: "/x/libFaux.dylib",
                                                     frameSize: FrameSize(width: 720, height: 1560, fps: 30))
        let calls = await runner.calls
        #expect(calls.contains { $0.contains("setenv") && $0.contains("DYLD_INSERT_LIBRARIES") && $0.contains("/x/libFaux.dylib") })
        #expect(calls.contains { $0.contains("setenv") && $0.contains("FAUXCAM_WIDTH") && $0.contains("720") })
        #expect(calls.contains { $0.contains("setenv") && $0.contains("FAUXCAM_HEIGHT") && $0.contains("1560") })
    }

    @Test func uninstallUnsetsEverything() async {
        let runner = RecordingRunner()
        await SimEnvInjector(runner: runner).uninstall(fromDevices: ["ABC"])
        let calls = await runner.calls
        for key in ["DYLD_INSERT_LIBRARIES", "FAUXCAM_WIDTH", "FAUXCAM_HEIGHT", "FAUXCAM_FPS"] {
            #expect(calls.contains { $0.contains("unsetenv") && $0.contains(key) })
        }
    }

    @Test func leftoverDetectsOurDylibOnly() async {
        let ours = RecordingRunner(output: Data("/x/libFaux.dylib".utf8))
        #expect(await SimEnvInjector(runner: ours).leftoverDevices(among: ["ABC"], dylibPath: "/x/libFaux.dylib") == ["ABC"])
        let theirs = RecordingRunner(output: Data("/somebody/else.dylib".utf8))
        #expect(await SimEnvInjector(runner: theirs).leftoverDevices(among: ["ABC"], dylibPath: "/x/libFaux.dylib").isEmpty)
    }
}
