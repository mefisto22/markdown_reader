import Foundation

/// Pure logic for Markdown-aware Return/Tab handling in the editor.
enum ListContinuation {
    enum Action: Equatable {
        /// Insert this text (starting with a newline) at the cursor.
        case insert(String)
        /// Replace the current line's text before the cursor (ends an empty list item / quote).
        case replaceLine(String)
    }

    struct Marker: Equatable {
        var quotePrefix: String
        var indent: String
        var marker: String      // "-", "*", "+", "3." or "3)"
        var spacing: String
        var task: Bool
        var content: String
    }

    private static let listRegex = try! NSRegularExpression(
        pattern: "^((?:[ \\t]*>[ \\t]?)*)([ \\t]*)([-*+]|\\d{1,9}[.)])([ \\t]+)(\\[[ xX]\\][ \\t]+)?(.*)$")
    private static let quoteRegex = try! NSRegularExpression(pattern: "^((?:[ \\t]*>[ \\t]?)+)(.*)$")

    static func parse(_ line: String) -> Marker? {
        let ns = line as NSString
        guard let m = listRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String {
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
        return Marker(quotePrefix: group(1), indent: group(2), marker: group(3), spacing: group(4),
                      task: m.range(at: 5).location != NSNotFound, content: group(6))
    }

    static func nextMarker(after marker: String) -> String {
        guard let last = marker.last, last == "." || last == ")", let n = Int(marker.dropLast()) else { return marker }
        return "\(n + 1)\(last)"
    }

    /// Decides what Return should do given the line text before the cursor.
    /// Returns nil for the default behavior.
    static func action(forLineBeforeCursor line: String) -> Action? {
        if let m = parse(line) {
            if m.content.trimmingCharacters(in: .whitespaces).isEmpty {
                return .replaceLine(m.quotePrefix)
            }
            let task = m.task ? "[ ] " : ""
            return .insert("\n" + m.quotePrefix + m.indent + nextMarker(after: m.marker) + m.spacing + task)
        }
        let ns = line as NSString
        if let q = quoteRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            let prefix = ns.substring(with: q.range(at: 1))
            let rest = ns.substring(with: q.range(at: 2))
            if rest.trimmingCharacters(in: .whitespaces).isEmpty { return .replaceLine("") }
            return .insert("\n" + prefix)
        }
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        if !indent.isEmpty, indent.count < line.count { return .insert("\n" + indent) }
        return nil
    }

    /// Indentation width for nesting a list item one level (marker + spacing).
    static func indentWidth(for marker: Marker) -> Int {
        marker.marker.count + max(marker.spacing.count, 1)
    }
}
