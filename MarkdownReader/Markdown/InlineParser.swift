import Foundation

/// CommonMark inline parser with the GFM strikethrough, autolink and
/// footnote extensions, `$…$` / `$$…$$` math and `:emoji:` shortcodes.
/// Implements the delimiter-stack algorithm from the CommonMark
/// specification for emphasis, links and images.
struct InlineParser {
    let references: [String: LinkReference]
    let footnotes: [String: Int]

    init(references: [String: LinkReference] = [:], footnotes: [String: Int] = [:]) {
        self.references = references
        self.footnotes = footnotes
    }

    func parse(_ text: String) -> [Inline] {
        guard !text.isEmpty else { return [] }
        let state = InlineState(bytes: Array(text.utf8), references: references, footnotes: footnotes)
        return state.run()
    }
}

private final class Piece {
    enum Kind { case text, delimiter, bracket, node }
    var kind: Kind
    var text: String
    var node: Inline?
    var next: Piece?
    weak var prev: Piece?

    init(kind: Kind, text: String = "", node: Inline? = nil) {
        self.kind = kind
        self.text = text
        self.node = node
    }
}

private final class Delimiter {
    let piece: Piece
    let char: UInt8
    var count: Int
    let originalCount: Int
    let canOpen: Bool
    let canClose: Bool

    init(piece: Piece, char: UInt8, count: Int, canOpen: Bool, canClose: Bool) {
        self.piece = piece
        self.char = char
        self.count = count
        self.originalCount = count
        self.canOpen = canOpen
        self.canClose = canClose
    }
}

private struct Bracket {
    let piece: Piece
    let isImage: Bool
    var active: Bool
    let delimiterBottom: Int
    let contentStart: Int
}

private let specialBytes: [Bool] = {
    var table = [Bool](repeating: false, count: 256)
    for c in "\n\\`*_~![]<&hHwW$:" { table[Int(c.asciiValue!)] = true }
    return table
}()

private final class InlineState {
    let s: [UInt8]
    let n: Int
    let references: [String: LinkReference]
    let footnotes: [String: Int]
    var head: Piece?
    var tail: Piece?
    var delimiters: [Delimiter] = []
    var brackets: [Bracket] = []
    var pending: [UInt8] = []

    init(bytes: [UInt8], references: [String: LinkReference], footnotes: [String: Int]) {
        self.s = bytes
        self.n = bytes.count
        self.references = references
        self.footnotes = footnotes
    }

    func run() -> [Inline] {
        var i = 0
        while i < n {
            let c = s[i]
            if !specialBytes[Int(c)] {
                var j = i + 1
                while j < n, !specialBytes[Int(s[j])] { j += 1 }
                pending.append(contentsOf: s[i..<j])
                i = j
                continue
            }
            switch c {
            case Byte.lf:
                var spaces = 0
                while pending.last == Byte.space { pending.removeLast(); spaces += 1 }
                flush()
                appendNode(spaces >= 2 ? .lineBreak : .softBreak)
                i = skipSpaces(i + 1)
            case Byte.backslash:
                if i + 1 < n, s[i + 1] == Byte.lf {
                    flush()
                    appendNode(.lineBreak)
                    i = skipSpaces(i + 2)
                } else if i + 1 < n, Byte.isPunctuation(s[i + 1]) {
                    pending.append(s[i + 1])
                    i += 2
                } else {
                    pending.append(c)
                    i += 1
                }
            case Byte.backtick:
                i = codeSpan(i)
            case Byte.star, Byte.underscore, Byte.tilde:
                i = delimiterRun(i)
            case Byte.bang:
                if i + 1 < n, s[i + 1] == Byte.lbracket {
                    flush()
                    let piece = Piece(kind: .bracket, text: "![")
                    append(piece)
                    brackets.append(Bracket(piece: piece, isImage: true, active: true,
                                            delimiterBottom: delimiters.count, contentStart: i + 2))
                    i += 2
                } else {
                    pending.append(c)
                    i += 1
                }
            case Byte.lbracket:
                if i + 1 < n, s[i + 1] == 0x5E /* ^ */, let (label, number, end) = footnoteReference(i) {
                    flush()
                    appendNode(.footnoteReference(label: label, number: number))
                    i = end
                    continue
                }
                flush()
                let piece = Piece(kind: .bracket, text: "[")
                append(piece)
                brackets.append(Bracket(piece: piece, isImage: false, active: true,
                                        delimiterBottom: delimiters.count, contentStart: i + 1))
                i += 1
            case Byte.rbracket:
                i = closeBracket(i)
            case Byte.lt:
                if let (destination, display, end) = autolink(i) {
                    flush()
                    appendNode(.link(destination: destination, title: nil, children: [.text(display)]))
                    i = end
                } else if let (end, _) = HTMLScanner.scan(s, i) {
                    flush()
                    appendNode(.html(MarkdownScan.string(s[i..<end])))
                    i = end
                } else {
                    pending.append(c)
                    i += 1
                }
            case 0x24: // $
                if let (tex, display, end) = math(i) {
                    flush()
                    appendNode(.math(tex, display: display))
                    i = end
                } else {
                    pending.append(c)
                    i += 1
                }
            case Byte.colon:
                if let (emoji, end) = emojiShortcode(i) {
                    pending.append(contentsOf: emoji.utf8)
                    i = end
                } else {
                    pending.append(c)
                    i += 1
                }
            case Byte.amp:
                if let (decoded, end) = HTMLEntities.decode(s, at: i) {
                    pending.append(contentsOf: decoded.utf8)
                    i = end
                } else {
                    pending.append(c)
                    i += 1
                }
            default: // h, H, w, W: possible extended autolink
                if atWordBoundary(i), let (destination, display, end) = extendedAutolink(i) {
                    flush()
                    appendNode(.link(destination: destination, title: nil, children: [.text(display)]))
                    i = end
                } else {
                    pending.append(c)
                    i += 1
                }
            }
        }
        flush()
        processEmphasis(bottom: 0)
        return collect(from: head, until: nil)
    }

    // MARK: Linked list helpers

    func append(_ p: Piece) {
        p.prev = tail
        tail?.next = p
        tail = p
        if head == nil { head = p }
    }

    func appendNode(_ node: Inline) {
        append(Piece(kind: .node, node: node))
    }

    func insert(_ p: Piece, after a: Piece) {
        p.next = a.next
        p.prev = a
        a.next?.prev = p
        a.next = p
        if tail === a { tail = p }
    }

    func remove(_ p: Piece) {
        p.prev?.next = p.next
        p.next?.prev = p.prev
        if head === p { head = p.next }
        if tail === p { tail = p.prev }
        p.next = nil
        p.prev = nil
    }

    func flush() {
        guard !pending.isEmpty else { return }
        append(Piece(kind: .text, text: MarkdownScan.string(pending)))
        pending.removeAll(keepingCapacity: true)
    }

    /// Removes the pieces in `[start, end)` from the list and converts them to inlines.
    func collect(from start: Piece?, until end: Piece?) -> [Inline] {
        var result: [Inline] = []
        var textBuffer = ""
        var p = start
        while let piece = p, piece !== end {
            let next = piece.next
            switch piece.kind {
            case .text, .delimiter, .bracket:
                textBuffer += piece.text
            case .node:
                if !textBuffer.isEmpty { result.append(.text(textBuffer)); textBuffer = "" }
                if let node = piece.node { result.append(node) }
            }
            remove(piece)
            p = next
        }
        if !textBuffer.isEmpty { result.append(.text(textBuffer)) }
        return result
    }

    func skipSpaces(_ i: Int) -> Int {
        var j = i
        while j < n, s[j] == Byte.space || s[j] == Byte.tab { j += 1 }
        return j
    }

    // MARK: Code spans

    func codeSpan(_ i: Int) -> Int {
        var j = i
        while j < n, s[j] == Byte.backtick { j += 1 }
        let length = j - i
        var k = j
        while k < n {
            if s[k] == Byte.backtick {
                var e = k
                while e < n, s[e] == Byte.backtick { e += 1 }
                if e - k == length {
                    var content = Array(s[j..<k]).map { $0 == Byte.lf ? Byte.space : $0 }
                    if content.count >= 2, content.first == Byte.space, content.last == Byte.space,
                       !content.allSatisfy({ $0 == Byte.space }) {
                        content.removeFirst()
                        content.removeLast()
                    }
                    flush()
                    appendNode(.code(MarkdownScan.string(content)))
                    return e
                }
                k = e
            } else {
                k += 1
            }
        }
        pending.append(contentsOf: s[i..<j])
        return j
    }

    // MARK: Emphasis

    private enum CharClass { case whitespace, punctuation, other }

    private func classify(_ scalar: Unicode.Scalar?) -> CharClass {
        guard let scalar else { return .whitespace }
        if scalar.isASCII {
            let b = UInt8(scalar.value)
            if Byte.isWhitespace(b) { return .whitespace }
            if Byte.isPunctuation(b) { return .punctuation }
            return .other
        }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return .whitespace
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return .punctuation
        default:
            return .other
        }
    }

    private func scalarBefore(_ i: Int) -> Unicode.Scalar? {
        guard i > 0 else { return nil }
        var start = i - 1
        while start > 0, s[start] & 0xC0 == 0x80 { start -= 1 }
        return decodeScalar(start)
    }

    private func decodeScalar(_ i: Int) -> Unicode.Scalar? {
        guard i < n else { return nil }
        var iterator = s[i...].makeIterator()
        var decoder = UTF8()
        if case .scalarValue(let v) = decoder.decode(&iterator) { return v }
        return nil
    }

    func delimiterRun(_ i: Int) -> Int {
        let c = s[i]
        var j = i
        while j < n, s[j] == c { j += 1 }
        let count = j - i
        let runText = MarkdownScan.string(s[i..<j])
        if c == Byte.tilde, count > 2 {
            pending.append(contentsOf: s[i..<j])
            return j
        }
        let before = classify(scalarBefore(i))
        let after = classify(decodeScalar(j))
        let leftFlanking = after != .whitespace
            && (after != .punctuation || before == .whitespace || before == .punctuation)
        let rightFlanking = before != .whitespace
            && (before != .punctuation || after == .whitespace || after == .punctuation)
        let canOpen: Bool
        let canClose: Bool
        if c == Byte.underscore {
            canOpen = leftFlanking && (!rightFlanking || before == .punctuation)
            canClose = rightFlanking && (!leftFlanking || after == .punctuation)
        } else {
            canOpen = leftFlanking
            canClose = rightFlanking
        }
        flush()
        let piece = Piece(kind: .delimiter, text: runText)
        append(piece)
        if canOpen || canClose {
            delimiters.append(Delimiter(piece: piece, char: c, count: count, canOpen: canOpen, canClose: canClose))
        }
        return j
    }

    func processEmphasis(bottom: Int) {
        var ci = bottom
        while ci < delimiters.count {
            let closer = delimiters[ci]
            guard closer.canClose else { ci += 1; continue }
            var oi = ci - 1
            var opener: Delimiter?
            while oi >= bottom {
                let o = delimiters[oi]
                if o.char == closer.char, o.canOpen {
                    if o.char == Byte.tilde {
                        if o.count == closer.count { opener = o; break }
                    } else {
                        let oddMatch = (o.canClose || closer.canOpen)
                            && (o.originalCount + closer.originalCount) % 3 == 0
                            && !(o.originalCount % 3 == 0 && closer.originalCount % 3 == 0)
                        if !oddMatch { opener = o; break }
                    }
                }
                oi -= 1
            }
            guard let opener else {
                if !closer.canOpen { delimiters.remove(at: ci) } else { ci += 1 }
                continue
            }
            let use: Int
            if closer.char == Byte.tilde {
                use = closer.count
            } else {
                use = (closer.count >= 2 && opener.count >= 2) ? 2 : 1
            }
            let children = collect(from: opener.piece.next, until: closer.piece)
            let node: Inline
            if closer.char == Byte.tilde {
                node = .strikethrough(children)
            } else {
                node = use == 2 ? .strong(children) : .emphasis(children)
            }
            insert(Piece(kind: .node, node: node), after: opener.piece)
            if oi + 1 < ci { delimiters.removeSubrange((oi + 1)..<ci) }
            ci = oi + 1
            opener.count -= use
            closer.count -= use
            opener.piece.text = String(opener.piece.text.prefix(opener.count))
            closer.piece.text = String(closer.piece.text.prefix(closer.count))
            if opener.count == 0 {
                remove(opener.piece)
                delimiters.remove(at: oi)
                ci -= 1
            }
            if closer.count == 0 {
                remove(closer.piece)
                delimiters.remove(at: ci)
            }
        }
        if bottom < delimiters.count { delimiters.removeSubrange(bottom...) }
    }

    // MARK: Links and images

    func skipWhitespace(_ i: Int) -> Int {
        var j = i
        while j < n, Byte.isWhitespace(s[j]) { j += 1 }
        return j
    }

    func closeBracket(_ i: Int) -> Int {
        guard let opener = brackets.last else {
            pending.append(Byte.rbracket)
            return i + 1
        }
        if !opener.active {
            brackets.removeLast()
            pending.append(Byte.rbracket)
            return i + 1
        }
        var destination: String?
        var title: String?
        var end = i + 1
        let j = i + 1

        // Inline link: [text](destination "title")
        if j < n, s[j] == Byte.lparen {
            let k = skipWhitespace(j + 1)
            if k < n, s[k] == Byte.rparen {
                destination = ""
                end = k + 1
            } else {
                var parsed: (String, Int)?
                if k + 1 < n, s[k] == Byte.lt, s[k + 1] == Byte.gt {
                    parsed = ("", k + 2)
                } else {
                    parsed = MarkdownScan.linkDestination(s, k)
                }
                if let (d, afterDestination) = parsed {
                    var m = skipWhitespace(afterDestination)
                    var t: String?
                    if m > afterDestination, let (parsedTitle, afterTitle) = MarkdownScan.linkTitle(s, m) {
                        t = parsedTitle
                        m = skipWhitespace(afterTitle)
                    }
                    if m < n, s[m] == Byte.rparen {
                        destination = d
                        title = t
                        end = m + 1
                    }
                }
            }
        }

        // Reference link: [text][label], [text][], [text]
        if destination == nil {
            var label: String?
            var afterReference = i + 1
            var explicitLabel = false
            if j < n, s[j] == Byte.lbracket {
                if let (l, after) = MarkdownScan.linkLabel(s, j) {
                    label = l
                    afterReference = after
                    explicitLabel = true
                } else if j + 1 < n, s[j + 1] == Byte.rbracket {
                    afterReference = j + 2
                    explicitLabel = true
                }
            }
            let key = label ?? MarkdownScan.string(s[opener.contentStart..<i])
            if let ref = references[MarkdownScan.normalizeLabel(key)] {
                destination = ref.destination
                title = ref.title
                end = explicitLabel ? afterReference : i + 1
            }
        }

        guard let destination else {
            brackets.removeLast()
            pending.append(Byte.rbracket)
            return i + 1
        }

        flush()
        processEmphasis(bottom: opener.delimiterBottom)
        let children = collect(from: opener.piece.next, until: nil)
        let node: Inline = opener.isImage
            ? .image(source: destination, title: title, alt: children)
            : .link(destination: destination, title: title, children: children)
        let nodePiece = Piece(kind: .node, node: node)
        insert(nodePiece, after: opener.piece)
        remove(opener.piece)
        brackets.removeLast()
        if !opener.isImage {
            for k in brackets.indices where !brackets[k].isImage { brackets[k].active = false }
        }
        return end
    }

    // MARK: Footnotes, math and emoji

    /// `[^label]` referring to a defined footnote.
    func footnoteReference(_ i: Int) -> (String, Int, Int)? {
        guard !footnotes.isEmpty else { return nil }
        var j = i + 2
        while j < n, j - i < 1000, s[j] != Byte.rbracket, s[j] != Byte.lbracket, !Byte.isWhitespace(s[j]) { j += 1 }
        guard j < n, s[j] == Byte.rbracket, j > i + 2 else { return nil }
        let label = MarkdownScan.normalizeLabel(MarkdownScan.string(s[(i + 2)..<j]))
        guard let number = footnotes[label] else { return nil }
        return (label, number, j + 1)
    }

    /// Math in GitHub syntax: `$$…$$` (display), `$`…`$` and `$…$` (inline).
    /// An inline opening `$` must be followed by a non-space; the closing `$`
    /// must follow a non-space and not be followed by a digit, so prices
    /// like "$5 and $10" stay text.
    func math(_ i: Int) -> (String, Bool, Int)? {
        if i + 1 < n, s[i + 1] == 0x24 {
            var j = i + 2
            while j + 1 < n {
                if s[j] == Byte.backslash { j += 2; continue }
                if s[j] == 0x24, s[j + 1] == 0x24 {
                    let tex = MarkdownScan.string(MarkdownScan.trimmed(s[(i + 2)..<j]))
                    return tex.isEmpty ? nil : (tex, true, j + 2)
                }
                j += 1
            }
            return nil
        }
        if i + 1 < n, s[i + 1] == Byte.backtick {
            var j = i + 2
            while j + 1 < n {
                if s[j] == Byte.backtick, s[j + 1] == 0x24 {
                    let tex = MarkdownScan.string(s[(i + 2)..<j])
                    return tex.isEmpty ? nil : (tex, false, j + 2)
                }
                j += 1
            }
            return nil
        }
        guard i + 1 < n, !Byte.isWhitespace(s[i + 1]) else { return nil }
        if i > 0, Byte.isAlnum(s[i - 1]) { return nil }
        var j = i + 1
        while j < n {
            let b = s[j]
            if b == Byte.backslash { j += 2; continue }
            if b == Byte.lf, j + 1 < n, s[j + 1] == Byte.lf { return nil }
            if b == 0x24 {
                let closesHere = !Byte.isWhitespace(s[j - 1]) && !(j + 1 < n && Byte.isDigit(s[j + 1]))
                if closesHere, j > i + 1 {
                    return (MarkdownScan.string(s[(i + 1)..<j]), false, j + 1)
                }
                return nil
            }
            j += 1
        }
        return nil
    }

    /// `:shortcode:` emoji (GitHub names).
    func emojiShortcode(_ i: Int) -> (String, Int)? {
        if i > 0, Byte.isAlnum(s[i - 1]) { return nil }
        var j = i + 1
        while j < n, j - i <= 48 {
            let b = s[j]
            if (b >= 0x61 && b <= 0x7A) || Byte.isDigit(b) || b == Byte.underscore || b == Byte.plus || b == Byte.dash {
                j += 1
            } else {
                break
            }
        }
        guard j < n, s[j] == Byte.colon, j > i + 1 else { return nil }
        guard let emoji = EmojiShortcodes.emoji(for: MarkdownScan.string(s[(i + 1)..<j])) else { return nil }
        return (emoji, j + 1)
    }

    // MARK: Autolinks

    /// `<scheme:…>` and `<user@example.com>`.
    func autolink(_ i: Int) -> (String, String, Int)? {
        var j = i + 1
        // URI autolink
        if j < n, Byte.isAlpha(s[j]) {
            var k = j + 1
            while k < n, Byte.isAlnum(s[k]) || s[k] == Byte.plus || s[k] == Byte.dot || s[k] == Byte.dash { k += 1 }
            let schemeLength = k - j
            if schemeLength >= 2, schemeLength <= 32, k < n, s[k] == Byte.colon {
                var e = k + 1
                while e < n, s[e] != Byte.gt, s[e] != Byte.lt, s[e] > Byte.space { e += 1 }
                if e < n, s[e] == Byte.gt {
                    let uri = MarkdownScan.string(s[j..<e])
                    return (uri, uri, e + 1)
                }
            }
        }
        // Email autolink
        var at = -1
        while j < n {
            let b = s[j]
            if b == Byte.gt { break }
            if b == 0x40 { // @
                if at >= 0 { return nil }
                at = j
            } else if !(Byte.isAlnum(b) || b == Byte.dot || b == Byte.dash || b == Byte.underscore || b == Byte.plus) {
                return nil
            }
            j += 1
        }
        guard j < n, s[j] == Byte.gt, at > i + 1, at < j - 1 else { return nil }
        let domain = s[(at + 1)..<j]
        guard domain.contains(Byte.dot), domain.last != Byte.dot, domain.first != Byte.dot else { return nil }
        let email = MarkdownScan.string(s[(i + 1)..<j])
        return ("mailto:" + email, email, j + 1)
    }

    func atWordBoundary(_ i: Int) -> Bool {
        guard i > 0 else { return true }
        let p = s[i - 1]
        return Byte.isWhitespace(p) || p == Byte.star || p == Byte.underscore || p == Byte.tilde || p == Byte.lparen
    }

    /// GFM extended autolinks: `https://…`, `http://…`, `www.…`.
    func extendedAutolink(_ i: Int) -> (String, String, Int)? {
        let prefix: Int
        var addScheme = false
        if HTMLScanner.hasPrefix(s, i, "https://") {
            prefix = 8
        } else if HTMLScanner.hasPrefix(s, i, "http://") {
            prefix = 7
        } else if HTMLScanner.hasPrefix(s, i, "www.") {
            prefix = 4
            addScheme = true
        } else {
            return nil
        }
        var e = i + prefix
        while e < n, s[e] > Byte.space, s[e] != Byte.lt { e += 1 }
        // Trim trailing punctuation.
        while e > i + prefix {
            let last = s[e - 1]
            if last == Byte.question || last == Byte.bang || last == Byte.dot || last == 0x2C /* , */
                || last == Byte.colon || last == Byte.star || last == Byte.underscore || last == Byte.tilde
                || last == Byte.quote || last == Byte.apos {
                e -= 1
            } else if last == Byte.rparen {
                let slice = s[i..<e]
                let opens = slice.filter { $0 == Byte.lparen }.count
                let closes = slice.filter { $0 == Byte.rparen }.count
                if closes > opens { e -= 1 } else { break }
            } else if last == Byte.semicolon {
                var k = e - 2
                while k > i, Byte.isAlnum(s[k]) { k -= 1 }
                if k > i, s[k] == Byte.amp, k < e - 2 { e = k } else { break }
            } else {
                break
            }
        }
        guard e > i + prefix else { return nil }
        // Domain must contain at least one dot after the scheme (or be www.x).
        let domainEnd = s[(i + prefix)..<e].firstIndex(where: { $0 == Byte.slash || $0 == Byte.question || $0 == Byte.hash }) ?? e
        if !addScheme, !s[(i + prefix)..<domainEnd].contains(Byte.dot) {
            if !(HTMLScanner.hasPrefix(s, i + prefix, "localhost")) { return nil }
        }
        if addScheme, domainEnd <= i + prefix { return nil }
        let text = MarkdownScan.string(s[i..<e])
        return (addScheme ? "http://" + text : text, text, e)
    }
}
