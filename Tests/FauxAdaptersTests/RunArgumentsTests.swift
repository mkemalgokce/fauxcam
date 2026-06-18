import Testing
import FauxAdapters

@Test func runRequiresABundleIdentifier() {
    #expect(RunArgumentsParser.parse([], defaultSourceSpec: "image") == nil)
    #expect(RunArgumentsParser.parse(["--source", "webcam"], defaultSourceSpec: "image") == nil)
}

@Test func runParsesFlagsInAnyOrder() {
    #expect(RunArgumentsParser.parse(["--device", "U1", "--source", "video:/x.mov", "com.app"], defaultSourceSpec: "image")
        == RunArguments(bundleIdentifier: "com.app", deviceUDID: "U1", sourceSpec: "video:/x.mov"))
    #expect(RunArgumentsParser.parse(["com.app", "--source", "webcam"], defaultSourceSpec: "image")
        == RunArguments(bundleIdentifier: "com.app", deviceUDID: nil, sourceSpec: "webcam"))
    #expect(RunArgumentsParser.parse(["com.app"], defaultSourceSpec: "image")
        == RunArguments(bundleIdentifier: "com.app", deviceUDID: nil, sourceSpec: "image"))
}

@Test func runRejectsMissingFlagValueAndExtraPositionals() {
    #expect(RunArgumentsParser.parse(["com.app", "--source"], defaultSourceSpec: "image") == nil)
    #expect(RunArgumentsParser.parse(["com.app", "--device"], defaultSourceSpec: "image") == nil)
    #expect(RunArgumentsParser.parse(["com.app", "extra.bundle"], defaultSourceSpec: "image") == nil)
}
