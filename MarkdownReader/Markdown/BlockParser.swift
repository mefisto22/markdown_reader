import Foundation

enum MarkdownParser {
    /// Parses the block structure of a Markdown document (CommonMark + GFM
    /// tables and task lists). Inline content is parsed lazily by the renderer.
    static func parse(_ text: String) -> ParsedMarkdown {
        BlockParser().parse(text)
    }
}

/// CommonMark-style two-phase block parser: each line first continues the
/// chain of open container blocks, then may open new blocks, and finally its
/// remaining text is added to the innermost open block.
final class BlockParser {
    typealias Line = UnsafeBufferPointer<UInt8>
    fileprivate final class Node {
        enum Kind {
            case document
            case quote
            case list(ordered: Bool, marker: UInt8, start: Int)
            case item(contentIndent: Int)
            case paragraph
            case heading(level: Int)
            case fencedCode(char: UInt8, length: Int, indent: Int, info: String)
            case indentedCode
            case html(type: Int)
            case thematicBreak
            case table(alignments: [TableAlignment], header: [String])
            case mathBlock
            case footnote(label: String)
            case defList
            case defTerm
            case defItem(contentIndent: Int)
        }

        var kind: Kind
        var children: [Node] = []
        weak var parent: Node?
        var lines: [String] = []
        var rows: [[String]] = []
        var text = ""
        var isOpen = true
        var lastLineBlank = false
        /// Index of the first line added to a paragraph by lazy continuation.
        var lazyStart: Int?
        let startLine: Int

        init(_ kind: Kind, startLine: Int) {
            self.kind = kind
            self.startLine = startLine
        }

        var isParagraph: Bool { if case .paragraph = kind { return true }; return false }

        var acceptsLinesOnly: Bool {
            switch kind {
            case .fencedCode, .indentedCode, .html, .mathBlock: return true
            default: return false
            }
        }

        func canContain(_ child: Kind) -> Bool {
            switch kind {
            case .document, .quote, .item, .footnote, .defItem:
                switch child {
                case .item, .defTerm, .defItem: return false
                case .footnote: if case .footnote = kind { return false } else { return true }
                default: return true
                }
            case .list:
                if case .item = child { return true }
                return false
            case .defList:
                switch child {
                case .defTerm, .defItem: return true
                default: return false
                }
            default:
                return false
            }
        }
    }

    private let document = Node(.document, startLine: 0)
    private var references: [String: LinkReference] = [:]
    /// Footnote definitions in document order (label as written, blocks).
    private var footnoteDefinitions: [(label: String, blocks: [Block])] = []
    /// UTF-8 offset of the start of each line.
    private var lineOffsets: [Int] = []

    func parse(_ text: String) -> ParsedMarkdown {
        var text = text
        text.makeContiguousUTF8()
        return text.utf8.withContiguousStorageIfAvailable { buffer in
            parse(buffer)
        }!
    }

    private func parse(_ buffer: UnsafeBufferPointer<UInt8>) -> ParsedMarkdown {
        let lineCount = parseLines(buffer)
        finalize(document)

        var blocks: [Block] = []
        var starts: [Int] = []
        blocks.reserveCapacity(document.children.count)
        for child in document.children {
            if let block = convert(child) {
                blocks.append(block)
                starts.append(child.startLine)
            }
        }
        var ranges: [Range<Int>] = []
        var hashes: [Int] = []
        ranges.reserveCapacity(starts.count)
        hashes.reserveCapacity(starts.count)
        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] : max(lineCount, start + 1)
            let range = start..<max(end, start + 1)
            ranges.append(range)
            let from = start < lineOffsets.count ? lineOffsets[start] : buffer.count
            let to = range.upperBound < lineOffsets.count ? lineOffsets[range.upperBound] : buffer.count
            var hasher = Hasher()
            hasher.combine(bytes: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: buffer[from..<max(from, to)])))
            hashes.append(hasher.finalize())
        }
        DetailsGrouping.group(&blocks, ranges: &ranges, hashes: &hashes)

        // Footnotes: numbered in order of first reference; unreferenced
        // definitions are dropped (as on GitHub). The section is appended as
        // one synthetic block after the last source line.
        var footnoteNumbers: [String: Int] = [:]
        if !footnoteDefinitions.isEmpty {
            var defined: [String: [Block]] = [:]
            for def in footnoteDefinitions {
                let key = MarkdownScan.normalizeLabel(def.label)
                if defined[key] == nil { defined[key] = def.blocks }
            }
            var section: [FootnoteDefinition] = []
            for label in Self.footnoteReferenceOrder(buffer) {
                let key = MarkdownScan.normalizeLabel(label)
                guard footnoteNumbers[key] == nil, let blocks = defined[key] else { continue }
                footnoteNumbers[key] = section.count + 1
                section.append(FootnoteDefinition(label: key, number: section.count + 1, blocks: blocks))
            }
            if !section.isEmpty {
                let block = Block.footnotes(section)
                blocks.append(block)
                ranges.append(lineCount..<(lineCount + 1))
                var hasher = Hasher()
                hasher.combine(block)
                hashes.append(hasher.finalize())
            }
        }
        return ParsedMarkdown(blocks: blocks, lineRanges: ranges, blockHashes: hashes,
                              references: references, lineCount: lineCount, footnotes: footnoteNumbers)
    }

    /// Labels of `[^label]` footnote references in source order (excluding
    /// the definitions themselves).
    private static func footnoteReferenceOrder(_ s: UnsafeBufferPointer<UInt8>) -> [String] {
        var labels: [String] = []
        var i = 0
        let n = s.count
        while i + 3 < n {
            guard s[i] == Byte.lbracket, s[i + 1] == 0x5E /* ^ */ else { i += 1; continue }
            var j = i + 2
            while j < n, j - i < 1000, s[j] != Byte.rbracket, s[j] != Byte.lbracket, !Byte.isWhitespace(s[j]) { j += 1 }
            guard j < n, s[j] == Byte.rbracket, j > i + 2 else { i += 1; continue }
            let isDefinition = j + 1 < n && s[j + 1] == Byte.colon
            if !isDefinition { labels.append(MarkdownScan.string(s[(i + 2)..<j])) }
            i = j + 1
        }
        return labels
    }

    private func parseLines(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var lineStart = 0
        var i = 0
        var lineNo = 0
        let n = bytes.count
        lineOffsets.append(0)
        while i < n {
            let b = bytes[i]
            if b == Byte.lf || b == Byte.cr {
                processLine(UnsafeBufferPointer(rebasing: bytes[lineStart..<i]), lineNo)
                if b == Byte.cr, i + 1 < n, bytes[i + 1] == Byte.lf { i += 1 }
                i += 1
                lineStart = i
                lineNo += 1
                lineOffsets.append(i)
            } else {
                i += 1
            }
        }
        if lineStart < n {
            processLine(UnsafeBufferPointer(rebasing: bytes[lineStart..<n]), lineNo)
            lineNo += 1
        }
        return lineNo
    }

    // MARK: - Line processing

    /// Tabs of the current line that were expanded to spaces: start index in
    /// the expanded line and width. Tabs the block structure did not consume
    /// are restored in code and HTML content, as CommonMark requires.
    private var expandedTabs: [(start: Int, width: Int)] = []

    /// Expands tabs in the structural prefix of a line (indentation, `>`,
    /// list markers) to spaces with 4-column tab stops. Tabs inside content
    /// are preserved.
    private static func expandTabs(_ raw: UnsafeBufferPointer<UInt8>, _ expanded: inout [(start: Int, width: Int)]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(raw.count + 8)
        var i = 0
        var inPrefix = true
        while i < raw.count {
            let b = raw[i]
            if inPrefix {
                if b == Byte.tab {
                    let spaces = 4 - (out.count % 4)
                    expanded.append((out.count, spaces))
                    out.append(contentsOf: repeatElement(Byte.space, count: spaces))
                    i += 1
                    continue
                }
                if !(b == Byte.space || b == Byte.gt || b == Byte.dash || b == Byte.star || b == Byte.plus
                     || Byte.isDigit(b) || b == Byte.dot || b == Byte.rparen) {
                    inPrefix = false
                }
            }
            out.append(b)
            i += 1
        }
        return out
    }

    @inline(__always)
    private func firstNonSpace(_ line: Line, _ from: Int) -> Int {
        var i = from
        while i < line.count, line[i] == Byte.space { i += 1 }
        return i
    }

    private func deepestOpen() -> Node {
        var n = document
        while let last = n.children.last, last.isOpen { n = last }
        return n
    }

    private func processLine(_ raw: UnsafeBufferPointer<UInt8>, _ lineNo: Int) {
        var i = 0
        while i < raw.count {
            let b = raw[i]
            if b == Byte.tab {
                var tabs: [(start: Int, width: Int)] = []
                let expanded = Self.expandTabs(raw, &tabs)
                expandedTabs = tabs
                expanded.withUnsafeBufferPointer { processExpandedLine($0, lineNo) }
                expandedTabs = []
                return
            }
            if !(b == Byte.space || b == Byte.gt || b == Byte.dash || b == Byte.star || b == Byte.plus
                 || Byte.isDigit(b) || b == Byte.dot || b == Byte.rparen) { break }
            i += 1
        }
        processExpandedLine(raw, lineNo)
    }

    private func processExpandedLine(_ line: Line, _ lineNo: Int) {
        var offset = 0
        var container = document
        var allMatched = true

        // Phase 1: try to continue each open block.
        while let last = container.children.last, last.isOpen {
            let nns = firstNonSpace(line, offset)
            let indent = nns - offset
            let blank = nns >= line.count
            var matched = true
            switch last.kind {
            case .quote:
                if indent <= 3, !blank, line[nns] == Byte.gt {
                    offset = nns + 1
                    if offset < line.count, line[offset] == Byte.space { offset += 1 }
                } else {
                    matched = false
                }
            case .list, .defList:
                break
            case .item(let contentIndent), .defItem(let contentIndent):
                if blank {
                    if last.children.isEmpty { matched = false } else { offset = nns }
                } else if indent >= contentIndent {
                    offset += contentIndent
                } else {
                    matched = false
                }
            case .footnote:
                if blank {
                    if last.children.isEmpty { matched = false } else { offset = nns }
                } else if indent >= 4 {
                    offset += 4
                } else {
                    matched = false
                }
            case .mathBlock:
                let content = contentString(line, offset, stripLeading: false)
                let trimmed = content.trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix("$$") {
                    let before = String(trimmed.dropLast(2))
                    if !before.trimmingCharacters(in: .whitespaces).isEmpty { last.lines.append(before) }
                    finalize(last)
                } else {
                    last.lines.append(content)
                }
                return
            case .fencedCode(let ch, let length, let fenceIndent, _):
                if !blank, indent <= 3, isClosingFence(line, nns, ch, length) {
                    finalize(last)
                    return
                }
                offset += min(indent, fenceIndent)
            case .indentedCode:
                if indent >= 4 {
                    offset += 4
                } else if blank {
                    offset = nns
                } else {
                    matched = false
                }
            case .html(let type):
                if blank, type >= 6 { matched = false }
            case .paragraph, .table:
                if blank { matched = false }
            case .heading, .thematicBreak, .document, .defTerm:
                matched = false
            }
            if !matched {
                allMatched = false
                break
            }
            container = last
        }

        let lastMatched = container
        let maybeLazy = deepestOpen().isParagraph
        var addedNew = false
        var lineConsumed = false   // setext heading / table header conversion

        func prepareToAdd() {
            if !addedNew {
                if let open = lastMatched.children.last, open.isOpen { finalize(open) }
                addedNew = true
            }
        }

        // Phase 2: look for new block starts.
        while !container.acceptsLinesOnly {
            let nns = firstNonSpace(line, offset)
            let indent = nns - offset
            let blank = nns >= line.count
            if indent >= 4 {
                if !maybeLazy, !blank {
                    offset += 4
                    prepareToAdd()
                    container = addChild(.indentedCode, to: container, line: lineNo)
                }
                break
            }
            if blank { break }
            let ch = line[nns]

            if ch == Byte.gt {
                offset = nns + 1
                if offset < line.count, line[offset] == Byte.space { offset += 1 }
                prepareToAdd()
                container = addChild(.quote, to: container, line: lineNo)
                continue
            }
            if ch == Byte.hash, let (level, text) = atxHeading(line, nns) {
                prepareToAdd()
                container = addChild(.heading(level: level), to: container, line: lineNo)
                container.text = text
                offset = line.count
                break
            }
            if ch == Byte.backtick || ch == Byte.tilde, let (length, info) = openingFence(line, nns) {
                prepareToAdd()
                container = addChild(.fencedCode(char: ch, length: length, indent: indent, info: info),
                                     to: container, line: lineNo)
                offset = line.count
                lineConsumed = true
                break
            }
            if ch == 0x24 /* $ */, nns + 1 < line.count, line[nns + 1] == 0x24 {
                let rest = MarkdownScan.string(line[(nns + 2)...]).trimmingCharacters(in: .whitespaces)
                prepareToAdd()
                let math = addChild(.mathBlock, to: container, line: lineNo)
                if rest.hasSuffix("$$") {
                    let body = String(rest.dropLast(2)).trimmingCharacters(in: .whitespaces)
                    if !body.isEmpty { math.lines.append(body) }
                    finalize(math)
                } else if !rest.isEmpty {
                    math.lines.append(rest)
                }
                container = math
                offset = line.count
                lineConsumed = true
                break
            }
            if ch == Byte.lbracket, let (label, contentOffset) = footnoteStart(line, nns) {
                prepareToAdd()
                container = addChild(.footnote(label: label), to: container, line: lineNo)
                offset = contentOffset
                continue
            }
            if ch == Byte.colon, let marker = definitionMarker(line, nns, offset),
               let list = definitionListForMarker(&container, lineNo: lineNo) {
                container = addChild(.defItem(contentIndent: marker.contentIndent), to: list, line: lineNo)
                addedNew = true
                offset = marker.contentOffset
                continue
            }
            if ch == Byte.lt, let type = htmlBlockStart(line, nns, canInterruptParagraph: !container.isParagraph) {
                prepareToAdd()
                container = addChild(.html(type: type), to: container, line: lineNo)
                break
            }
            if container.isParagraph, ch == Byte.eq || ch == Byte.dash, let level = setextLevel(line, nns) {
                resolveReferences(container)
                if !container.lines.isEmpty {
                    container.text = paragraphText(container.lines)
                    container.kind = .heading(level: level)
                    offset = line.count
                    lineConsumed = true
                    break
                }
            }
            if container.isParagraph, let alignments = tableDelimiterRow(line, nns),
               let headerLine = container.lines.last {
                let header = splitTableRow(Array(headerLine.utf8))
                if header.count == alignments.count {
                    let paragraph = container
                    let parent = paragraph.parent!
                    paragraph.lines.removeLast()
                    finalize(paragraph)
                    let table = Node(.table(alignments: alignments, header: header), startLine: max(0, lineNo - 1))
                    table.parent = parent
                    parent.children.append(table)
                    container = table
                    offset = line.count
                    lineConsumed = true
                    break
                }
            }
            if isThematicBreak(line, nns) {
                prepareToAdd()
                container = addChild(.thematicBreak, to: container, line: lineNo)
                offset = line.count
                break
            }
            if let marker = listMarker(line, nns, offset) {
                if container.isParagraph, marker.blankAfter || (marker.ordered && marker.start != 1) { break }
                prepareToAdd()
                var compatible = false
                if case .list(let ordered, let m, _) = container.kind, ordered == marker.ordered, m == marker.char {
                    compatible = true
                }
                if !compatible {
                    container = addChild(.list(ordered: marker.ordered, marker: marker.char, start: marker.start),
                                         to: container, line: lineNo)
                }
                container = addChild(.item(contentIndent: marker.contentIndent), to: container, line: lineNo)
                offset = marker.contentOffset
                continue
            }
            break
        }

        let blank = firstNonSpace(line, offset) >= line.count

        // Lazy paragraph continuation.
        if !addedNew, !lineConsumed, !allMatched, !blank {
            let tip = deepestOpen()
            if tip.isParagraph {
                if tip.lazyStart == nil { tip.lazyStart = tip.lines.count }
                tip.lines.append(contentString(line, offset, stripLeading: true))
                return
            }
        }
        if !addedNew, !lineConsumed, let open = lastMatched.children.last, open.isOpen {
            finalize(open)
        }

        // Blank-line bookkeeping (used to decide list tightness).
        if blank, let lastChild = container.children.last { lastChild.lastLineBlank = true }
        var lastLineBlank = blank
        switch container.kind {
        case .quote, .heading, .thematicBreak, .fencedCode, .mathBlock:
            lastLineBlank = false
        case .item where container.children.isEmpty && container.startLine == lineNo:
            lastLineBlank = false
        default:
            break
        }
        container.lastLineBlank = lastLineBlank
        var t = container
        while let p = t.parent {
            p.lastLineBlank = false
            t = p
        }

        // Phase 3: add the line's content.
        switch container.kind {
        case .fencedCode, .indentedCode:
            if !lineConsumed { container.lines.append(contentString(line, offset, stripLeading: false)) }
        case .mathBlock:
            break
        case .html(let type):
            let content = contentString(line, offset, stripLeading: false)
            container.lines.append(content)
            if type <= 5, htmlBlockEnds(type, content) { finalize(container) }
        case .heading, .thematicBreak:
            finalize(container)
        case .paragraph:
            if !blank { container.lines.append(contentString(line, offset, stripLeading: true)) }
        case .table:
            if !lineConsumed, !blank {
                container.rows.append(splitTableRow(Array(line[offset...])))
            }
        default:
            if !blank {
                prepareToAdd()
                let p = addChild(.paragraph, to: container, line: lineNo)
                p.lines.append(contentString(line, offset, stripLeading: true))
            }
        }
    }

    private func contentString(_ line: Line, _ offset: Int, stripLeading: Bool) -> String {
        guard offset < line.count else { return "" }
        var start = offset
        if stripLeading {
            while start < line.count, Byte.isSpaceOrTab(line[start]) { start += 1 }
            return MarkdownScan.string(line[start...])
        }
        // Restore tabs that were expanded but not (even partly) consumed.
        let unconsumed = expandedTabs.filter { $0.start >= start }
        guard !unconsumed.isEmpty else { return MarkdownScan.string(line[start...]) }
        var bytes = [UInt8]()
        bytes.reserveCapacity(line.count - start)
        var i = start
        var k = 0
        while i < line.count {
            if k < unconsumed.count, unconsumed[k].start == i {
                bytes.append(Byte.tab)
                i += unconsumed[k].width
                k += 1
            } else {
                bytes.append(line[i])
                i += 1
            }
        }
        return MarkdownScan.string(bytes)
    }

    private func addChild(_ kind: Node.Kind, to parent: Node, line: Int) -> Node {
        var p = parent
        while !p.canContain(kind) {
            finalize(p)
            p = p.parent!
        }
        let node = Node(kind, startLine: line)
        node.parent = p
        p.children.append(node)
        return node
    }

    // MARK: - Finalization

    private func finalize(_ node: Node) {
        guard node.isOpen else { return }
        if let last = node.children.last, last.isOpen { finalize(last) }
        node.isOpen = false
        switch node.kind {
        case .paragraph:
            resolveReferences(node)
            if node.lines.isEmpty {
                if let parent = node.parent {
                    // The node is almost always the last child; avoid an O(n) scan.
                    if parent.children.last === node {
                        parent.children.removeLast()
                    } else {
                        parent.children.removeAll { $0 === node }
                    }
                }
            } else {
                node.text = paragraphText(node.lines)
            }
        case .indentedCode:
            while let last = node.lines.last, last.allSatisfy({ $0 == " " || $0 == "\t" }) {
                node.lines.removeLast()
            }
        default:
            break
        }
    }

    private func paragraphText(_ lines: [String]) -> String {
        var text = lines.joined(separator: "\n")
        while let last = text.last, last == " " || last == "\t" { text.removeLast() }
        return text
    }

    /// Extracts link reference definitions from the start of a paragraph.
    private func resolveReferences(_ node: Node) {
        guard let first = node.lines.first, first.hasPrefix("[") || first.hasPrefix(" [") || first.hasPrefix("  [")
                || first.hasPrefix("   [") else { return }
        let bytes = Array(node.lines.joined(separator: "\n").utf8)
        var pos = 0
        var found = false
        while pos < bytes.count, let (label, ref, end) = MarkdownScan.referenceDefinition(bytes, pos) {
            if references[label] == nil { references[label] = ref }
            pos = end
            found = true
        }
        guard found else { return }
        let rest = MarkdownScan.string(bytes[pos...])
        node.lines = rest.isEmpty ? [] : rest.components(separatedBy: "\n")
        if node.lines.allSatisfy({ $0.allSatisfy(\.isWhitespace) }) { node.lines = [] }
    }

    // MARK: - Block start recognizers

    private func atxHeading(_ line: Line, _ p0: Int) -> (Int, String)? {
        var p = p0
        var level = 0
        while p < line.count, line[p] == Byte.hash, level < 7 { level += 1; p += 1 }
        guard (1...6).contains(level), p == line.count || Byte.isSpaceOrTab(line[p]) else { return nil }
        var end = line.count
        while end > p, Byte.isSpaceOrTab(line[end - 1]) { end -= 1 }
        var e = end
        while e > p, line[e - 1] == Byte.hash { e -= 1 }
        if e < end, e == p || Byte.isSpaceOrTab(line[e - 1]) { end = e }
        while end > p, Byte.isSpaceOrTab(line[end - 1]) { end -= 1 }
        var start = p
        while start < end, Byte.isSpaceOrTab(line[start]) { start += 1 }
        return (level, MarkdownScan.string(line[start..<end]))
    }

    private func openingFence(_ line: Line, _ p: Int) -> (Int, String)? {
        let ch = line[p]
        var q = p
        while q < line.count, line[q] == ch { q += 1 }
        let length = q - p
        guard length >= 3 else { return nil }
        let info = MarkdownScan.trimmed(line[q...])
        if ch == Byte.backtick, info.contains(Byte.backtick) { return nil }
        return (length, MarkdownScan.unescape(info))
    }

    private func isClosingFence(_ line: Line, _ p: Int, _ ch: UInt8, _ length: Int) -> Bool {
        var q = p
        while q < line.count, line[q] == ch { q += 1 }
        guard q - p >= length else { return false }
        while q < line.count, Byte.isSpaceOrTab(line[q]) { q += 1 }
        return q == line.count
    }

    private func isThematicBreak(_ line: Line, _ p: Int) -> Bool {
        let ch = line[p]
        guard ch == Byte.star || ch == Byte.dash || ch == Byte.underscore else { return false }
        var count = 0
        for i in p..<line.count {
            let b = line[i]
            if b == ch { count += 1 } else if !Byte.isSpaceOrTab(b) { return false }
        }
        return count >= 3
    }

    private func setextLevel(_ line: Line, _ p: Int) -> Int? {
        let ch = line[p]
        var q = p
        while q < line.count, line[q] == ch { q += 1 }
        while q < line.count, Byte.isSpaceOrTab(line[q]) { q += 1 }
        guard q == line.count else { return nil }
        return ch == Byte.eq ? 1 : 2
    }

    private struct ListMarker {
        var ordered: Bool
        var char: UInt8
        var start: Int
        var contentIndent: Int
        var contentOffset: Int
        var blankAfter: Bool
    }

    private func listMarker(_ line: Line, _ nns: Int, _ offset: Int) -> ListMarker? {
        var p = nns
        let c = line[p]
        var ordered = false
        var start = 1
        let marker: UInt8
        if c == Byte.dash || c == Byte.plus || c == Byte.star {
            marker = c
            p += 1
        } else if Byte.isDigit(c) {
            var value = 0
            var digits = 0
            while p < line.count, Byte.isDigit(line[p]), digits < 9 {
                value = value * 10 + Int(line[p] - 0x30)
                p += 1
                digits += 1
            }
            guard p < line.count, line[p] == Byte.dot || line[p] == Byte.rparen else { return nil }
            marker = line[p]
            p += 1
            ordered = true
            start = value
        } else {
            return nil
        }
        if p < line.count, line[p] != Byte.space { return nil }
        var q = p
        while q < line.count, line[q] == Byte.space { q += 1 }
        let spaces = q - p
        let blankAfter = q >= line.count
        let markerWidth = p - nns
        let markerIndent = nns - offset
        let used: Int
        let contentOffset: Int
        if blankAfter {
            used = 1
            contentOffset = line.count
        } else if spaces >= 5 {
            used = 1
            contentOffset = p + 1
        } else {
            used = spaces
            contentOffset = q
        }
        return ListMarker(ordered: ordered, char: marker, start: start,
                          contentIndent: markerIndent + markerWidth + used,
                          contentOffset: contentOffset, blankAfter: blankAfter)
    }

    // MARK: - Footnote definitions and definition lists

    /// `[^label]:` at `p`. Returns the label and the offset of the content.
    private func footnoteStart(_ line: Line, _ p: Int) -> (String, Int)? {
        guard p + 1 < line.count, line[p + 1] == 0x5E /* ^ */ else { return nil }
        var q = p + 2
        while q < line.count, line[q] != Byte.rbracket, line[q] != Byte.lbracket, !Byte.isWhitespace(line[q]) { q += 1 }
        guard q > p + 2, q + 1 < line.count, line[q] == Byte.rbracket, line[q + 1] == Byte.colon else { return nil }
        let label = MarkdownScan.string(line[(p + 2)..<q])
        var content = q + 2
        while content < line.count, line[content] == Byte.space { content += 1 }
        return (label, content)
    }

    /// `:` followed by 1–4 spaces and content (PHP Markdown Extra definition).
    private func definitionMarker(_ line: Line, _ nns: Int, _ offset: Int) -> ListMarker? {
        var q = nns + 1
        while q < line.count, line[q] == Byte.space { q += 1 }
        let spaces = q - nns - 1
        guard spaces >= 1, q < line.count else { return nil }
        let used = spaces >= 5 ? 1 : spaces
        return ListMarker(ordered: false, char: Byte.colon, start: 0,
                          contentIndent: nns - offset + 1 + used,
                          contentOffset: spaces >= 5 ? nns + 2 : q, blankAfter: false)
    }

    /// Finds or creates the definition list for a `:` definition line,
    /// converting the preceding paragraph's lines into terms. Returns nil if
    /// there is no term, in which case the line is ordinary text.
    private func definitionListForMarker(_ container: inout Node, lineNo: Int) -> Node? {
        func addTerms(_ terms: [String], to list: Node, line: Int) {
            for text in terms {
                let term = Node(.defTerm, startLine: line)
                term.text = text.trimmingCharacters(in: .whitespaces)
                term.isOpen = false
                term.parent = list
                list.children.append(term)
            }
        }
        if case .defList = container.kind {
            let list = container
            // Lines lazily appended to the previous definition are new terms.
            let tip = deepestOpen()
            if tip.isParagraph, let lazy = tip.lazyStart, tip.parent?.parent === list {
                let terms = Array(tip.lines[lazy...])
                tip.lines.removeSubrange(lazy...)
                tip.lazyStart = nil
                if let open = list.children.last, open.isOpen { finalize(open) }
                addTerms(terms, to: list, line: max(0, lineNo - terms.count))
            } else if let open = list.children.last, open.isOpen {
                finalize(open)
            }
            return list
        }
        let paragraph: Node
        if container.isParagraph {
            paragraph = container
            resolveReferences(paragraph)
            paragraph.isOpen = false
        } else if let last = container.children.last, last.isParagraph, !last.isOpen {
            paragraph = last
        } else {
            return nil
        }
        guard !paragraph.lines.isEmpty, let parent = paragraph.parent, parent.children.last === paragraph else { return nil }
        parent.children.removeLast()
        let list: Node
        if let previous = parent.children.last, case .defList = previous.kind {
            list = previous
            list.isOpen = true
        } else {
            list = Node(.defList, startLine: paragraph.startLine)
            list.parent = parent
            parent.children.append(list)
        }
        addTerms(paragraph.lines, to: list, line: paragraph.startLine)
        container = list
        return list
    }

    // MARK: - Tables (GFM)

    private func tableDelimiterRow(_ line: Line, _ p: Int) -> [TableAlignment]? {
        let content = MarkdownScan.trimmed(line[p...])
        guard !content.isEmpty, content.contains(Byte.pipe) || content.first == Byte.colon else { return nil }
        guard content.allSatisfy({ $0 == Byte.pipe || $0 == Byte.dash || $0 == Byte.colon || Byte.isSpaceOrTab($0) })
        else { return nil }
        let cells = splitTableRow(Array(content))
        guard !cells.isEmpty else { return nil }
        var result: [TableAlignment] = []
        for cell in cells {
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (left, right) {
            case (true, true): result.append(.center)
            case (true, false): result.append(.left)
            case (false, true): result.append(.right)
            default: result.append(.none)
            }
        }
        return result
    }

    /// Splits a table row on unescaped pipes, dropping optional leading and
    /// trailing pipes. Escaped pipes (`\|`) are unescaped so they render as `|`.
    func splitTableRow(_ raw: [UInt8]) -> [String] {
        var s = Array(MarkdownScan.trimmed(raw[...]))
        if s.first == Byte.pipe { s.removeFirst() }
        if s.last == Byte.pipe, !(s.count >= 2 && s[s.count - 2] == Byte.backslash) { s.removeLast() }
        var cells: [String] = []
        var current: [UInt8] = []
        var i = 0
        while i < s.count {
            let b = s[i]
            if b == Byte.backslash, i + 1 < s.count, s[i + 1] == Byte.pipe {
                current.append(Byte.pipe)
                i += 2
                continue
            }
            if b == Byte.pipe {
                cells.append(MarkdownScan.string(MarkdownScan.trimmed(current[...])))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(b)
            }
            i += 1
        }
        cells.append(MarkdownScan.string(MarkdownScan.trimmed(current[...])))
        return cells
    }

    // MARK: - HTML blocks

    private static let blockTagNames: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center",
        "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption",
        "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head",
        "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav",
        "noframes", "ol", "optgroup", "option", "p", "param", "search", "section", "summary", "table",
        "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul",
    ]

    private func htmlBlockStart(_ line: Line, _ p: Int, canInterruptParagraph: Bool) -> Int? {
        let head = MarkdownScan.string(line[p..<min(line.count, p + 12)]).lowercased()
        for tag in ["script", "pre", "style", "textarea"] where head.hasPrefix("<" + tag) {
            let after = p + 1 + tag.count
            if after >= line.count || Byte.isSpaceOrTab(line[after]) || line[after] == Byte.gt { return 1 }
        }
        if head.hasPrefix("<!--") { return 2 }
        if head.hasPrefix("<?") { return 3 }
        if head.hasPrefix("<![cdata[") { return 5 }
        if head.hasPrefix("<!"), p + 2 < line.count, Byte.isAlpha(line[p + 2]) { return 4 }

        var q = p + 1
        if q < line.count, line[q] == Byte.slash { q += 1 }
        let nameStart = q
        while q < line.count, Byte.isAlnum(line[q]) { q += 1 }
        if q > nameStart {
            let name = MarkdownScan.string(line[nameStart..<q]).lowercased()
            if Self.blockTagNames.contains(name) {
                if q == line.count || Byte.isSpaceOrTab(line[q]) || line[q] == Byte.gt
                    || (line[q] == Byte.slash && q + 1 < line.count && line[q + 1] == Byte.gt) {
                    return 6
                }
            }
        }
        if canInterruptParagraph, let (end, kind) = HTMLScanner.scan(Array(line), p), kind != .other,
           MarkdownScan.isBlank(line[end...]) {
            return 7
        }
        return nil
    }

    private func htmlBlockEnds(_ type: Int, _ content: String) -> Bool {
        switch type {
        case 1:
            let lower = content.lowercased()
            return lower.contains("</script>") || lower.contains("</pre>") || lower.contains("</style>")
                || lower.contains("</textarea>")
        case 2: return content.contains("-->")
        case 3: return content.contains("?>")
        case 4: return content.contains(">")
        case 5: return content.contains("]]>")
        default: return false
        }
    }

    // MARK: - Conversion to the public AST

    private func convertChildren(_ node: Node) -> [Block] {
        var blocks = node.children.compactMap(convert)
        DetailsGrouping.group(&blocks)
        return blocks
    }

    private func convert(_ node: Node) -> Block? {
        switch node.kind {
        case .document, .item, .defTerm, .defItem:
            return nil
        case .quote:
            return .quote(convertChildren(node))
        case .list(let ordered, _, let start):
            let items = node.children.map { item -> ListItem in
                var blocks = convertChildren(item)
                var task: Bool?
                if case .paragraph(let text)? = blocks.first, let (checked, rest) = Self.taskMarker(text) {
                    task = checked
                    blocks[0] = .paragraph(text: rest)
                }
                return ListItem(task: task, blocks: blocks, line: item.startLine)
            }
            return .list(ListBlock(ordered: ordered, start: start, tight: isTight(node), items: items))
        case .footnote(let label):
            footnoteDefinitions.append((label, convertChildren(node)))
            return nil
        case .mathBlock:
            return .math(node.lines.joined(separator: "\n"))
        case .defList:
            var items: [DefinitionItem] = []
            var pendingTerms: [String] = []
            for child in node.children {
                switch child.kind {
                case .defTerm:
                    pendingTerms.append(child.text)
                case .defItem:
                    if !pendingTerms.isEmpty || items.isEmpty {
                        items.append(DefinitionItem(terms: pendingTerms, definitions: []))
                        pendingTerms = []
                    }
                    items[items.count - 1].definitions.append(convertChildren(child))
                default:
                    break
                }
            }
            if !pendingTerms.isEmpty { items.append(DefinitionItem(terms: pendingTerms, definitions: [])) }
            return .definitionList(items)
        case .paragraph:
            return .paragraph(text: node.text)
        case .heading(let level):
            return .heading(level: level, text: node.text)
        case .fencedCode(_, _, _, let info):
            return .code(info: info, content: node.lines.joined(separator: "\n"))
        case .indentedCode:
            return .code(info: "", content: node.lines.joined(separator: "\n"))
        case .html:
            return .html(node.lines.joined(separator: "\n"))
        case .thematicBreak:
            return .thematicBreak
        case .table(let alignments, let header):
            let columns = alignments.count
            let rows = node.rows.map { row -> [String] in
                if row.count >= columns { return Array(row.prefix(columns)) }
                return row + Array(repeating: "", count: columns - row.count)
            }
            return .table(TableBlock(alignments: alignments, header: header, rows: rows))
        }
    }

    static func taskMarker(_ text: String) -> (Bool, String)? {
        guard text.count >= 3, text.hasPrefix("[") else { return nil }
        let chars = Array(text.prefix(4))
        guard chars[2] == "]" else { return nil }
        let checked: Bool
        switch chars[1] {
        case " ": checked = false
        case "x", "X": checked = true
        default: return nil
        }
        if chars.count == 3 { return nil }
        guard chars[3] == " " || chars[3] == "\t" else { return nil }
        return (checked, String(text.dropFirst(4)))
    }

    private func endsWithBlankLine(_ node: Node) -> Bool {
        var n = node
        while true {
            if n.lastLineBlank { return true }
            switch n.kind {
            case .list, .item:
                guard let last = n.children.last else { return false }
                n = last
            default:
                return false
            }
        }
    }

    private func isTight(_ list: Node) -> Bool {
        let items = list.children
        for (i, item) in items.enumerated() {
            let hasNext = i < items.count - 1
            if item.lastLineBlank, hasNext { return false }
            for (j, sub) in item.children.enumerated() where endsWithBlankLine(sub) {
                if hasNext || j < item.children.count - 1 { return false }
            }
        }
        return true
    }
}
