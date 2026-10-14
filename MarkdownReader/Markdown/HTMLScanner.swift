import Foundation

/// Recognizes raw HTML constructs as defined by CommonMark (open/closing
/// tags, comments, processing instructions, declarations, CDATA). Raw HTML is
/// never executed or loaded; the renderer only extracts a safe subset.
enum HTMLScanner {
    enum TagKind { case open, close, other }

    /// Returns the index after a complete HTML construct starting at `i`
    /// (which must be `<`), or nil.
    static func scan(_ s: [UInt8], _ i: Int) -> (end: Int, kind: TagKind)? {
        guard i + 1 < s.count, s[i] == Byte.lt else { return nil }
        let c = s[i + 1]
        if Byte.isAlpha(c) {
            return scanOpenTag(s, i).map { ($0, .open) }
        }
        if c == Byte.slash {
            var j = i + 2
            guard j < s.count, Byte.isAlpha(s[j]) else { return nil }
            while j < s.count, Byte.isAlnum(s[j]) || s[j] == Byte.dash { j += 1 }
            while j < s.count, Byte.isWhitespace(s[j]) { j += 1 }
            guard j < s.count, s[j] == Byte.gt else { return nil }
            return (j + 1, .close)
        }
        if c == Byte.bang {
            if hasPrefix(s, i, "<!--") {
                // Comment: `<!-->` and `<!--->` are complete comments too.
                if hasPrefix(s, i, "<!-->") { return (i + 5, .other) }
                if hasPrefix(s, i, "<!--->") { return (i + 6, .other) }
                if let end = find(s, from: i + 4, "-->") { return (end + 3, .other) }
                return nil
            }
            if hasPrefix(s, i, "<![CDATA[") {
                if let end = find(s, from: i + 9, "]]>") { return (end + 3, .other) }
                return nil
            }
            if i + 2 < s.count, Byte.isAlpha(s[i + 2]) {
                if let end = s[(i + 2)...].firstIndex(of: Byte.gt) { return (end + 1, .other) }
                return nil
            }
            return nil
        }
        if c == Byte.question {
            if let end = find(s, from: i + 2, "?>") { return (end + 2, .other) }
        }
        return nil
    }

    private static func scanOpenTag(_ s: [UInt8], _ i: Int) -> Int? {
        var j = i + 1
        while j < s.count, Byte.isAlnum(s[j]) || s[j] == Byte.dash { j += 1 }
        while true {
            let wsStart = j
            while j < s.count, Byte.isWhitespace(s[j]) { j += 1 }
            guard j < s.count else { return nil }
            if s[j] == Byte.gt { return j + 1 }
            if s[j] == Byte.slash {
                return (j + 1 < s.count && s[j + 1] == Byte.gt) ? j + 2 : nil
            }
            // Attribute must be preceded by whitespace.
            guard j > wsStart else { return nil }
            let a = s[j]
            guard Byte.isAlpha(a) || a == Byte.underscore || a == Byte.colon else { return nil }
            j += 1
            while j < s.count, Byte.isAlnum(s[j]) || s[j] == Byte.underscore || s[j] == Byte.colon
                    || s[j] == Byte.dot || s[j] == Byte.dash { j += 1 }
            // Optional value.
            var k = j
            while k < s.count, Byte.isWhitespace(s[k]) { k += 1 }
            if k < s.count, s[k] == Byte.eq {
                k += 1
                while k < s.count, Byte.isWhitespace(s[k]) { k += 1 }
                guard k < s.count else { return nil }
                let q = s[k]
                if q == Byte.quote || q == Byte.apos {
                    guard let close = s[(k + 1)...].firstIndex(of: q) else { return nil }
                    j = close + 1
                } else {
                    let start = k
                    while k < s.count {
                        let b = s[k]
                        if Byte.isWhitespace(b) || b == Byte.quote || b == Byte.apos || b == Byte.eq
                            || b == Byte.lt || b == Byte.gt || b == Byte.backtick { break }
                        k += 1
                    }
                    guard k > start else { return nil }
                    j = k
                }
            }
        }
    }

    static func hasPrefix(_ s: [UInt8], _ i: Int, _ prefix: StaticString) -> Bool {
        let p = UnsafeBufferPointer(start: prefix.utf8Start, count: prefix.utf8CodeUnitCount)
        guard i + p.count <= s.count else { return false }
        for k in 0..<p.count where s[i + k] != p[k] { return false }
        return true
    }

    static func find(_ s: [UInt8], from: Int, _ needle: StaticString) -> Int? {
        let p = UnsafeBufferPointer(start: needle.utf8Start, count: needle.utf8CodeUnitCount)
        guard p.count > 0, from <= s.count - p.count else { return nil }
        var i = from
        while i <= s.count - p.count {
            if s[i] == p[0] {
                var match = true
                for k in 1..<p.count where s[i + k] != p[k] { match = false; break }
                if match { return i }
            }
            i += 1
        }
        return nil
    }

    /// Extracts the tag name (lowercased) of an open or closing tag.
    static func tagName(_ tag: String) -> String {
        var name = ""
        for ch in tag.dropFirst().drop(while: { $0 == "/" }) {
            if ch.isLetter || ch.isNumber || ch == "-" { name.append(ch) } else { break }
        }
        return name.lowercased()
    }

    /// Extracts an attribute value from a tag (e.g. `src` from `<img src="a.png">`).
    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "(?i)[\\s/]" + NSRegularExpression.escapedPattern(for: name)
            + "\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'=<>`]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for g in 1...3 {
            let r = m.range(at: g)
            if r.location != NSNotFound, let range = Range(r, in: tag) {
                return MarkdownScan.unescape(Array(tag[range].utf8))
            }
        }
        return nil
    }
}
