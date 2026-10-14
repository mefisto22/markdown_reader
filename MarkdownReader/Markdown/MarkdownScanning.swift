import Foundation

/// Byte constants used by the parsers. All Markdown syntax characters are
/// ASCII, so parsing works on UTF-8 bytes; multi-byte sequences (accented
/// letters, emoji, …) never contain ASCII bytes and pass through untouched.
enum Byte {
    static let tab: UInt8 = 0x09
    static let lf: UInt8 = 0x0A
    static let cr: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let bang: UInt8 = 0x21       // !
    static let quote: UInt8 = 0x22      // "
    static let hash: UInt8 = 0x23       // #
    static let amp: UInt8 = 0x26        // &
    static let apos: UInt8 = 0x27       // '
    static let lparen: UInt8 = 0x28     // (
    static let rparen: UInt8 = 0x29     // )
    static let star: UInt8 = 0x2A       // *
    static let plus: UInt8 = 0x2B       // +
    static let dash: UInt8 = 0x2D       // -
    static let dot: UInt8 = 0x2E        // .
    static let slash: UInt8 = 0x2F      // /
    static let colon: UInt8 = 0x3A      // :
    static let semicolon: UInt8 = 0x3B  // ;
    static let lt: UInt8 = 0x3C         // <
    static let eq: UInt8 = 0x3D         // =
    static let gt: UInt8 = 0x3E         // >
    static let question: UInt8 = 0x3F   // ?
    static let lbracket: UInt8 = 0x5B   // [
    static let backslash: UInt8 = 0x5C  // \
    static let rbracket: UInt8 = 0x5D   // ]
    static let underscore: UInt8 = 0x5F // _
    static let backtick: UInt8 = 0x60   // `
    static let pipe: UInt8 = 0x7C       // |
    static let tilde: UInt8 = 0x7E      // ~

    @inline(__always) static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    @inline(__always) static func isAlpha(_ b: UInt8) -> Bool { (b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A }
    @inline(__always) static func isAlnum(_ b: UInt8) -> Bool { isAlpha(b) || isDigit(b) }
    @inline(__always) static func isSpaceOrTab(_ b: UInt8) -> Bool { b == space || b == tab }
    @inline(__always) static func isWhitespace(_ b: UInt8) -> Bool {
        b == space || b == tab || b == lf || b == cr || b == 0x0B || b == 0x0C
    }
    /// ASCII punctuation as defined by CommonMark.
    @inline(__always) static func isPunctuation(_ b: UInt8) -> Bool {
        (b >= 0x21 && b <= 0x2F) || (b >= 0x3A && b <= 0x40) || (b >= 0x5B && b <= 0x60) || (b >= 0x7B && b <= 0x7E)
    }
}

enum MarkdownScan {
    static func string<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        String(decoding: bytes, as: UTF8.self)
    }

    static func trimmed<C: BidirectionalCollection>(_ s: C) -> C.SubSequence where C.Element == UInt8 {
        var lo = s.startIndex, hi = s.endIndex
        while lo < hi, Byte.isWhitespace(s[lo]) { lo = s.index(after: lo) }
        while hi > lo, Byte.isWhitespace(s[s.index(before: hi)]) { hi = s.index(before: hi) }
        return s[lo..<hi]
    }

    static func isBlank<C: Collection>(_ s: C) -> Bool where C.Element == UInt8 {
        s.allSatisfy(Byte.isWhitespace)
    }

    /// Processes backslash escapes and HTML entity references.
    static func unescape<C: Collection>(_ bytes: C) -> String where C.Element == UInt8, C.Index == Int {
        guard bytes.contains(Byte.backslash) || bytes.contains(Byte.amp) else { return string(bytes) }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let b = bytes[i]
            if b == Byte.backslash, i + 1 < bytes.endIndex, Byte.isPunctuation(bytes[i + 1]) {
                out.append(bytes[i + 1])
                i += 2
            } else if b == Byte.amp, let (decoded, next) = HTMLEntities.decode(bytes, at: i) {
                out.append(contentsOf: decoded.utf8)
                i = next
            } else {
                out.append(b)
                i += 1
            }
        }
        return string(out)
    }

    /// Normalizes a link label for reference matching: trims, collapses
    /// internal whitespace, and case-folds.
    static func normalizeLabel(_ label: String) -> String {
        label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    // MARK: Link components (shared by reference definitions and inline links)

    /// Scans `[label]` starting at `i` (which must be `[`). Returns the raw
    /// label text and the index after `]`.
    static func linkLabel(_ s: [UInt8], _ i: Int) -> (String, Int)? {
        guard i < s.count, s[i] == Byte.lbracket else { return nil }
        var j = i + 1
        while j < s.count {
            let c = s[j]
            if c == Byte.backslash, j + 1 < s.count, Byte.isPunctuation(s[j + 1]) {
                j += 2
                continue
            }
            if c == Byte.lbracket { return nil }
            if c == Byte.rbracket {
                let content = s[(i + 1)..<j]
                guard content.count <= 999, !isBlank(content) else { return nil }
                return (string(content), j + 1)
            }
            j += 1
        }
        return nil
    }

    /// Scans a link destination at `i`. Returns the unescaped destination and
    /// the index after it.
    static func linkDestination(_ s: [UInt8], _ i: Int) -> (String, Int)? {
        guard i < s.count else { return nil }
        if s[i] == Byte.lt {
            var j = i + 1
            while j < s.count {
                let c = s[j]
                if c == Byte.backslash, j + 1 < s.count, Byte.isPunctuation(s[j + 1]) { j += 2; continue }
                if c == Byte.lf || c == Byte.lt { return nil }
                if c == Byte.gt { return (unescape(s[(i + 1)..<j]), j + 1) }
                j += 1
            }
            return nil
        }
        var depth = 0
        var j = i
        while j < s.count {
            let c = s[j]
            if c == Byte.backslash, j + 1 < s.count, Byte.isPunctuation(s[j + 1]) { j += 2; continue }
            if c == Byte.lparen {
                depth += 1
                if depth > 32 { return nil }
            } else if c == Byte.rparen {
                if depth == 0 { break }
                depth -= 1
            } else if c <= Byte.space || c == 0x7F {
                break
            }
            j += 1
        }
        guard j > i, depth == 0 else { return nil }
        return (unescape(s[i..<j]), j)
    }

    /// Scans a link title (`"…"`, `'…'` or `(…)`) at `i`.
    static func linkTitle(_ s: [UInt8], _ i: Int) -> (String, Int)? {
        guard i < s.count else { return nil }
        let closer: UInt8
        switch s[i] {
        case Byte.quote: closer = Byte.quote
        case Byte.apos: closer = Byte.apos
        case Byte.lparen: closer = Byte.rparen
        default: return nil
        }
        var j = i + 1
        while j < s.count {
            let c = s[j]
            if c == Byte.backslash, j + 1 < s.count, Byte.isPunctuation(s[j + 1]) { j += 2; continue }
            if c == closer { return (unescape(s[(i + 1)..<j]), j + 1) }
            if closer == Byte.rparen, c == Byte.lparen { return nil }
            j += 1
        }
        return nil
    }

    /// Skips spaces/tabs and at most one line ending.
    static func skipSpacesAndOneNewline(_ s: [UInt8], _ i: Int) -> Int {
        var j = i
        while j < s.count, Byte.isSpaceOrTab(s[j]) { j += 1 }
        if j < s.count, s[j] == Byte.lf {
            j += 1
            while j < s.count, Byte.isSpaceOrTab(s[j]) { j += 1 }
        }
        return j
    }

    /// Parses a link reference definition at `start`. Returns the normalized
    /// label, the reference and the index after the definition's line ending.
    static func referenceDefinition(_ s: [UInt8], _ start: Int) -> (String, LinkReference, Int)? {
        var i = start
        var indent = 0
        while i < s.count, s[i] == Byte.space, indent < 3 { i += 1; indent += 1 }
        guard let (label, afterLabel) = linkLabel(s, i),
              afterLabel < s.count, s[afterLabel] == Byte.colon else { return nil }
        i = skipSpacesAndOneNewline(s, afterLabel + 1)
        let destination: String
        let afterDest: Int
        if i + 1 < s.count, s[i] == Byte.lt, s[i + 1] == Byte.gt {
            destination = ""
            afterDest = i + 2
        } else if let (d, a) = linkDestination(s, i) {
            destination = d
            afterDest = a
        } else {
            return nil
        }

        func endOfLineIfBlank(_ k: Int) -> Int? {
            var j = k
            while j < s.count, Byte.isSpaceOrTab(s[j]) { j += 1 }
            if j == s.count { return j }
            if s[j] == Byte.lf { return j + 1 }
            return nil
        }

        let titleStart = skipSpacesAndOneNewline(s, afterDest)
        if titleStart > afterDest, let (title, afterTitle) = linkTitle(s, titleStart),
           let end = endOfLineIfBlank(afterTitle) {
            return (normalizeLabel(label), LinkReference(destination: destination, title: title), end)
        }
        guard let end = endOfLineIfBlank(afterDest) else { return nil }
        return (normalizeLabel(label), LinkReference(destination: destination, title: nil), end)
    }
}
