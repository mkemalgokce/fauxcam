import Testing
@testable import Injection

struct LldbInitBlockTests {
    @Test func insertIsIdempotent() {
        let once = LldbInitBlock.inserting(sourcePath: "/p", into: "existing\n")
        let twice = LldbInitBlock.inserting(sourcePath: "/p", into: once)
        #expect(once == twice)
        #expect(once.contains(LldbInitBlock.begin))
        #expect(once.contains("command source \"/p\""))
    }

    @Test func removeStripsBlockKeepingRest() {
        let inserted = LldbInitBlock.inserting(sourcePath: "/p", into: "keep me\n")
        let removed = LldbInitBlock.removing(from: inserted)
        #expect(!removed.contains(LldbInitBlock.begin))
        #expect(!removed.contains(LldbInitBlock.end))
        #expect(removed.contains("keep me"))
    }

    @Test func removeNoopWhenAbsent() {
        #expect(LldbInitBlock.removing(from: "nothing here") == "nothing here")
    }
}
