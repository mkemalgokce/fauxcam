/// Pure (TEMPLATE-style) surgery on an lldbinit file's bracketed FauxCam block — fully unit-testable,
/// no filesystem. Idempotent insert; balanced-marker remove that won't corrupt a hand-edited file.
enum LldbInitBlock {
    static let begin = "# >>> FauxCam auto-inject (remove with FauxCam) >>>"
    static let end = "# <<< FauxCam auto-inject <<<"

    static func inserting(sourcePath: String, into content: String) -> String {
        guard !content.contains(begin) else { return content }   // idempotent
        let block = "\(begin)\ncommand source \"\(sourcePath)\"\n\(end)\n"
        if content.isEmpty { return block }
        return content + (content.hasSuffix("\n") ? "" : "\n") + block
    }

    static func removing(from content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard let b = lines.firstIndex(where: { $0.contains(begin) }),
              let e = lines.firstIndex(where: { $0.contains(end) }), b <= e else { return content }
        lines.removeSubrange(b...e)
        return lines.joined(separator: "\n")
    }
}
