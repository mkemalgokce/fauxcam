import Testing
@testable import CLICore

struct OptionScannerTests {
    @Test func splitsPositionalsAndFlagValues() {
        let scan = OptionScanner.scan(["--device", "ABC", "com.example.app"], flags: ["--device", "--source"])
        #expect(scan?.positionals == ["com.example.app"])
        #expect(scan?.flagValues == ["--device": "ABC"])
    }

    @Test func returnsNilWhenFlagHasNoValue() {
        #expect(OptionScanner.scan(["com.example.app", "--source"], flags: ["--source"]) == nil)
    }

    @Test func treatsUnknownDashedTokenAsPositional() {
        let scan = OptionScanner.scan(["--unknown"], flags: ["--source"])
        #expect(scan?.positionals == ["--unknown"])
    }
}

struct RunArgumentsParserTests {
    @Test func parsesBundleDeviceAndSource() {
        let parsed = RunArgumentsParser.parse(["--device", "ABC", "--source", "webcam", "com.example.app"], defaultSourceSpec: "image")
        #expect(parsed == RunArguments(bundleIdentifier: "com.example.app", deviceUDID: "ABC", sourceSpec: "webcam"))
    }

    @Test func appliesDefaultSourceWhenAbsent() {
        let parsed = RunArgumentsParser.parse(["com.example.app"], defaultSourceSpec: "image")
        #expect(parsed == RunArguments(bundleIdentifier: "com.example.app", deviceUDID: nil, sourceSpec: "image"))
    }

    @Test func returnsNilWithoutBundleIdentifier() {
        #expect(RunArgumentsParser.parse(["--device", "ABC"], defaultSourceSpec: "image") == nil)
    }

    @Test func returnsNilWithExtraPositional() {
        #expect(RunArgumentsParser.parse(["one", "two"], defaultSourceSpec: "image") == nil)
    }

    @Test func returnsNilWhenFlagMissingValue() {
        #expect(RunArgumentsParser.parse(["com.example.app", "--source"], defaultSourceSpec: "image") == nil)
    }
}

struct AppsArgumentsParserTests {
    @Test func parsesDevice() {
        #expect(AppsArgumentsParser.parse(["--device", "ABC"]) == AppsArguments(deviceUDID: "ABC"))
    }

    @Test func defaultsToNoDevice() {
        #expect(AppsArgumentsParser.parse([]) == AppsArguments(deviceUDID: nil))
    }

    @Test func returnsNilWithUnexpectedPositional() {
        #expect(AppsArgumentsParser.parse(["extra"]) == nil)
    }

    @Test func returnsNilWhenDeviceMissingValue() {
        #expect(AppsArgumentsParser.parse(["--device"]) == nil)
    }
}

struct ServeArgumentsParserTests {
    @Test func appliesDefaults() {
        let parsed = ServeArgumentsParser.parse([], defaultSocketPath: "/tmp/faux.sock", defaultSourceSpec: "image")
        #expect(parsed == ServeArguments(socketPath: "/tmp/faux.sock", sourceSpec: "image"))
    }

    @Test func parsesSocketAndSource() {
        let parsed = ServeArgumentsParser.parse(["/tmp/custom.sock", "--source", "qr:hello"], defaultSocketPath: "/tmp/faux.sock", defaultSourceSpec: "image")
        #expect(parsed == ServeArguments(socketPath: "/tmp/custom.sock", sourceSpec: "qr:hello"))
    }

    @Test func returnsNilWithExtraPositional() {
        #expect(ServeArgumentsParser.parse(["a", "b"], defaultSocketPath: "/tmp/faux.sock", defaultSourceSpec: "image") == nil)
    }

    @Test func returnsNilWhenSourceMissingValue() {
        #expect(ServeArgumentsParser.parse(["--source"], defaultSocketPath: "/tmp/faux.sock", defaultSourceSpec: "image") == nil)
    }
}
