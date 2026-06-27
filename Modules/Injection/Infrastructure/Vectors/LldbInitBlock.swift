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
        while let blockStart = lines.firstIndex(where: { $0.contains(begin) }) {
            guard let blockEnd = lines[blockStart...].firstIndex(where: { $0.contains(end) }) else {
                lines.removeSubrange(blockStart...)   // orphan begin (no matching end): strip to EOF
                break
            }
            lines.removeSubrange(blockStart...blockEnd)
        }
        return lines.joined(separator: "\n")
    }
}
