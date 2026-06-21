import Testing
import FauxAdapters

private let socketDefault = "/private/tmp/com.fauxcam/faux.sock"

@Test func serveDefaultsToImageSourceAndDefaultSocket() {
    #expect(ServeArgumentsParser.parse([], defaultSocketPath: socketDefault, defaultSourceSpec: "image")
        == ServeArguments(socketPath: socketDefault, sourceSpec: "image"))
}

@Test func serveTakesSocketPositionalThenSourceFlag() {
    #expect(ServeArgumentsParser.parse(["s.sock", "--source", "webcam"], defaultSocketPath: socketDefault, defaultSourceSpec: "image")
        == ServeArguments(socketPath: "s.sock", sourceSpec: "webcam"))
}

@Test func serveAcceptsSourceFlagBeforePositional() {
    #expect(ServeArgumentsParser.parse(["--source", "video:/clip.mov", "s.sock"], defaultSocketPath: socketDefault, defaultSourceSpec: "image")
        == ServeArguments(socketPath: "s.sock", sourceSpec: "video:/clip.mov"))
}

@Test func serveRejectsSourceFlagWithNoValue() {
    #expect(ServeArgumentsParser.parse(["--source"], defaultSocketPath: socketDefault, defaultSourceSpec: "image") == nil)
    #expect(ServeArgumentsParser.parse(["s.sock", "--source"], defaultSocketPath: socketDefault, defaultSourceSpec: "image") == nil)
}

@Test func serveRejectsMoreThanOnePositional() {
    #expect(ServeArgumentsParser.parse(["a.sock", "b.sock"], defaultSocketPath: socketDefault, defaultSourceSpec: "image") == nil)
}
