import AppKit
import XCTest
@testable import MarkdownReader

final class ExtensionParsingTests: XCTestCase {
    private func parse(_ md: String) -> ParsedMarkdown { MarkdownParser.parse(md) }

    func testFootnotesAreNumberedByFirstReferenceAndCollected() {
        let parsed = parse("B[^b] and A[^a], B again[^b].\n\n[^a]: Note A.\n[^b]: Note **B**.\n[^unused]: Never shown.")
        XCTAssertEqual(parsed.footnotes, ["b": 1, "a": 2])
        guard case .footnotes(let defs)? = parsed.blocks.last else { return XCTFail("\(parsed.blocks)") }
        XCTAssertEqual(defs.map(\.label), ["b", "a"])
        XCTAssertEqual(defs[0].blocks, [.paragraph(text: "Note **B**.")])
        XCTAssertEqual(parsed.blocks.count, 2) // paragraph + footnotes section
        let inlines = InlineParser(references: [:], footnotes: parsed.footnotes).parse("x[^a] y[^missing]")
        XCTAssertEqual(inlines, [.text("x"), .footnoteReference(label: "a", number: 2), .text(" y[^missing]")])
    }

    func testMultiParagraphFootnote() {
        let parsed = parse("Text[^1]\n\n[^1]: First.\n\n    Second paragraph.\n\nAfter.")
        guard case .footnotes(let defs)? = parsed.blocks.last else { return XCTFail() }
        XCTAssertEqual(defs[0].blocks, [.paragraph(text: "First."), .paragraph(text: "Second paragraph.")])
        XCTAssertEqual(parsed.blocks.first, .paragraph(text: "Text[^1]"))
        XCTAssertEqual(parsed.blocks[1], .paragraph(text: "After."))
    }

    func testDefinitionLists() {
        let blocks = parse("Apple\n:   Fruit\n:   Company\n\nOrange\n: Citrus\nBanana\n: Yellow").blocks
        XCTAssertEqual(blocks, [.definitionList([
            DefinitionItem(terms: ["Apple"], definitions: [[.paragraph(text: "Fruit")], [.paragraph(text: "Company")]]),
            DefinitionItem(terms: ["Orange"], definitions: [[.paragraph(text: "Citrus")]]),
            DefinitionItem(terms: ["Banana"], definitions: [[.paragraph(text: "Yellow")]]),
        ])])
        // A colon line without a preceding term is plain text.
        XCTAssertEqual(parse(": not a definition").blocks, [.paragraph(text: ": not a definition")])
    }

    func testMathBlocksAndInlineMath() {
        XCTAssertEqual(parse("$$\nx^2\n$$").blocks, [.math("x^2")])
        XCTAssertEqual(parse("$$ a + b $$").blocks, [.math("a + b")])
        XCTAssertEqual(parse("text\n$$\n\\frac{1}{2}\n$$\nafter").blocks,
                       [.paragraph(text: "text"), .math("\\frac{1}{2}"), .paragraph(text: "after")])
        let p = InlineParser()
        XCTAssertEqual(p.parse("a $x^2$ b"), [.text("a "), .math("x^2", display: false), .text(" b")])
        XCTAssertEqual(p.parse("$`\\sqrt{2}`$"), [.math("\\sqrt{2}", display: false)])
        XCTAssertEqual(p.parse("costs $5 and $10"), [.text("costs $5 and $10")])
        XCTAssertEqual(p.parse("\\$x$"), [.text("$x$")])
        XCTAssertEqual(p.parse("inline $$\\sum$$ display"), [.text("inline "), .math("\\sum", display: true), .text(" display")])
    }

    func testEmojiShortcodes() {
        let p = InlineParser()
        XCTAssertEqual(p.parse(":tada: :+1: :rocket: :hungary: :sunflower:").plainText, "🎉 👍 🚀 🇭🇺 🌻")
        XCTAssertEqual(p.parse("10:30:45 and :not_an_emoji_name:").plainText, "10:30:45 and :not_an_emoji_name:")
        XCTAssertEqual(p.parse("`:tada:`"), [.code(":tada:")])
    }

    func testDetailsSpanningMarkdownBlocks() {
        let parsed = parse("<details open>\n<summary>More *info*</summary>\n\n- a\n- b\n\n</details>\n\nafter")
        XCTAssertEqual(parsed.blocks.count, 2)
        guard case .details(let summary, let open, let children) = parsed.blocks[0] else { return XCTFail("\(parsed.blocks)") }
        XCTAssertEqual(summary, "More *info*")
        XCTAssertTrue(open)
        guard case .list = children.first else { return XCTFail("\(children)") }
        XCTAssertEqual(parsed.lineRanges[0], 0..<8)
        // Single-block details.
        guard case .details(let s2, let o2, let c2)? = parse("<details><summary>S</summary>body</details>").blocks.first
        else { return XCTFail() }
        XCTAssertEqual(s2, "S")
        XCTAssertFalse(o2)
        XCTAssertEqual(c2, [.html("body")])
    }

    func testTaskItemsRecordTheirSourceLine() {
        guard case .list(let list)? = parse("intro\n\n- [ ] one\n- [x] two").blocks.last else { return XCTFail() }
        XCTAssertEqual(list.items.map(\.line), [2, 3])
    }
}

final class ExtensionRenderingTests: XCTestCase {
    private func render(_ md: String, options: RenderOptions = RenderOptions()) -> NSAttributedString {
        let parsed = MarkdownParser.parse(md)
        return MarkdownRenderer(style: RenderStyle(fontSize: 16), baseURL: nil, references: parsed.references,
                                footnotes: parsed.footnotes, options: options).render(parsed)
    }

    private func attachmentCells(_ s: NSAttributedString) -> [NSTextAttachmentCellProtocol] {
        var cells: [NSTextAttachmentCellProtocol] = []
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            if let cell = (value as? NSTextAttachment)?.attachmentCell { cells.append(cell) }
        }
        return cells
    }

    func testMathRendersAsVectorAttachments() {
        let s = render("Inline $a^2+b^2=c^2$ and\n\n$$\\int_0^1 \\frac{x}{\\sqrt{2}}\\,dx$$")
        let math = attachmentCells(s).compactMap { $0 as? MathAttachmentCell }
        XCTAssertEqual(math.count, 2)
        XCTAssertTrue(math.allSatisfy { $0.box.width > 10 && $0.box.height > 5 })
    }

    func testMathLayoutHandlesEnvironmentsAndReportsUnknownCommands() {
        let box = MathRenderer.layout("\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix} \\left( \\frac{a}{b} \\right) \\sum_{i=1}^n i",
                                      display: true, fontSize: 16)
        XCTAssertGreaterThan(box.width, 100)
        XCTAssertGreaterThan(box.height, 30)
        var parser = MathParser("\\notacommand x")
        guard case .error(let name)? = parser.parseAll().first else { return XCTFail() }
        XCTAssertEqual(name, "\\notacommand")
    }

    func testMermaidDiagramsAndUnsupportedFallback() {
        let flow = MermaidRenderer.diagram("graph TD\n  A[Start] --> B{Ok?}\n  B -->|yes| C((End))\n  B -.-> A", fontSize: 14)
        XCTAssertNotNil(flow)
        XCTAssertGreaterThan(flow!.size.height, 150)
        let chart = Flowchart.parse(["A[Start] --> B{Ok?}", "B -->|yes| C((End)) & D", "B -.-> A"], direction: "TD")
        XCTAssertEqual(chart.order, ["A", "B", "C", "D"])
        XCTAssertEqual(chart.edges.count, 4)
        XCTAssertEqual(chart.edges[1].label, "yes")
        XCTAssertTrue(chart.edges[3].dotted)
        XCTAssertEqual(chart.nodes["C"]?.shape, .circle)
        XCTAssertNotNil(MermaidRenderer.diagram("sequenceDiagram\nAlice->>Bob: Hi\nBob-->>Alice: Hello", fontSize: 14))
        XCTAssertNotNil(MermaidRenderer.diagram("pie title Pets\n\"Dogs\" : 3\n\"Cats\" : 2", fontSize: 14))
        XCTAssertNil(MermaidRenderer.diagram("gantt\n title X", fontSize: 14))
        let s = render("```mermaid\ngantt\n  title X\n```")
        XCTAssertTrue(s.string.contains("gantt"))
        XCTAssertTrue(attachmentCells(render("```mermaid\ngraph LR\nA-->B\n```")).first is MermaidAttachmentCell)
    }

    func testCodeHighlighting() throws {
        let tokens = try XCTUnwrap(CodeHighlighter.highlight("let x = \"hi\" // note\nfunc f() {}", language: "swift"))
        let code = "let x = \"hi\" // note\nfunc f() {}" as NSString
        func token(_ text: String) -> CodeHighlighter.Token? {
            let range = code.range(of: text)
            return tokens.first { NSIntersectionRange($0.0, range).length == range.length }?.1
        }
        XCTAssertEqual(token("let").map { "\($0)" }, "keyword")
        XCTAssertEqual(token("\"hi\"").map { "\($0)" }, "string")
        XCTAssertEqual(token("// note").map { "\($0)" }, "comment")
        XCTAssertEqual(token("f").map { "\($0)" }, "keyword") // inside "func"
        XCTAssertNil(CodeHighlighter.highlight("x", language: "no-such-language"))
        XCTAssertNotNil(CodeHighlighter.highlight("<a href=\"x\">", language: "html"))
        XCTAssertNotNil(CodeHighlighter.highlight("+ added", language: "diff"))
        // The reader colors code blocks.
        let s = render("```python\ndef f():\n    return 1\n```")
        let color = s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, CodeHighlighter.Colors.keyword)
    }

    func testFootnoteRendering() {
        let s = render("Text[^n].\n\n[^n]: The note.")
        XCTAssertTrue(s.string.contains("Text1."))
        XCTAssertTrue(s.string.contains("The note. ↩︎"))
        var anchors: [String] = []
        s.enumerateAttribute(.mdrAnchor, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if let v = v as? String { anchors.append(v) }
        }
        XCTAssertEqual(Set(anchors), ["fnref-n", "fn-n"])
    }

    func testDetailsCollapseAndExpand() {
        let md = "<details>\n<summary>Hidden</summary>\n\nSecret text\n\n</details>"
        let collapsed = render(md)
        XCTAssertTrue(collapsed.string.contains("Hidden"))
        XCTAssertFalse(collapsed.string.contains("Secret"))
        var options = RenderOptions()
        options.expandAllDetails = true
        XCTAssertTrue(render(md, options: options).string.contains("Secret text"))
    }

    func testInlineCSSAndHTMLTables() {
        let s = render("<span style=\"color: #ff0000; font-weight: bold\">red</span> <font color=\"blue\">blue</font>")
        let ns = s.string as NSString
        let red = s.attribute(.foregroundColor, at: ns.range(of: "red").location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(red?.usingColorSpace(.sRGB)?.redComponent ?? 0, 1, accuracy: 0.01)
        let font = s.attribute(.font, at: ns.range(of: "red").location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let table = render("<table><tr><th>A</th><th>B</th></tr><tr><td colspan=\"2\">wide</td></tr></table>")
        var cells = 0
        table.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: table.length)) { value, _, _ in
            if (value as? NSParagraphStyle)?.textBlocks.last is NSTextTableBlock { cells += 1 }
        }
        XCTAssertEqual(cells, 3)
        XCTAssertFalse(render("<p style=\"display:none\">hidden</p>visible").string.contains("hidden"))
    }

    func testDefinitionListAndEmojiRendering() {
        let s = render("Term\n: Definition :smile:")
        XCTAssertTrue(s.string.contains("Term\n"))
        XCTAssertTrue(s.string.contains("Definition 😄"))
    }

    func testWideCodeAndTablesScrollOnlyWhenTheyOverflow() {
        var options = RenderOptions()
        options.availableWidth = 300
        let long = "```\n" + String(repeating: "x", count: 200) + "\n```"
        let renderer = MarkdownRenderer(style: RenderStyle(fontSize: 16), baseURL: nil, references: [:], options: options)
        let wide = renderer.render(MarkdownParser.parse(long).blocks[0])
        XCTAssertTrue(attachmentCells(wide).first is ScrollableBlockCell)
        XCTAssertEqual(renderer.lastInfo.widthThresholds.count, 1)
        let narrow = renderer.render(MarkdownParser.parse("```\nshort\n```").blocks[0])
        XCTAssertTrue(attachmentCells(narrow).isEmpty)
        let table = "| " + (1...12).map { "column\($0)" }.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 12)
        XCTAssertTrue(attachmentCells(renderer.render(MarkdownParser.parse(table).blocks[0])).first is ScrollableBlockCell)
    }

    func testTaskMarkersAreClickable() {
        let s = render("intro\n\n- [ ] one\n- [x] two")
        var lines: [Int] = []
        s.enumerateAttribute(.mdrTaskLine, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if let v = v as? Int { lines.append(v) }
        }
        // Relative to the list block, which starts on line 2.
        XCTAssertEqual(lines, [0, 1])
    }

    func testSharedBlocksDoNotMergeNeighbours() {
        // Two adjacent code blocks must stay two blocks.
        let s = render("```\na\n```\n```\nb\n```")
        var blocks: [ObjectIdentifier] = []
        s.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if let b = (v as? NSParagraphStyle)?.textBlocks.first { blocks.append(ObjectIdentifier(b)) }
        }
        XCTAssertEqual(blocks.count, 2)
        XCTAssertNotEqual(blocks[0], blocks[1])
    }
}

final class ReaderInteractionTests: XCTestCase {
    func testClickingATaskToggleEditsTheSourceUndoably() {
        let doc = MarkdownDocument()
        doc.replaceText("# Tasks\n\n- [ ] one\n- [x] two\n")
        let undo = UndoManager()
        undo.groupsByEvent = false
        doc.undoManager = undo
        let preview = PreviewController(document: doc)
        preview.isActive = true
        let storage = preview.textView.textStorage!
        var found: (Int, Int)?
        storage.enumerateAttribute(.mdrTaskLine, in: NSRange(location: 0, length: storage.length)) { v, range, stop in
            if let line = v as? Int { found = (line, range.location); stop.pointee = true }
        }
        guard let (line, index) = found else { return XCTFail("no task marker") }
        undo.beginUndoGrouping()
        preview.textView.onTaskToggle?(line, index)
        undo.endUndoGrouping()
        XCTAssertEqual(doc.text, "# Tasks\n\n- [x] one\n- [x] two\n")
        undo.undo()
        XCTAssertEqual(doc.text, "# Tasks\n\n- [ ] one\n- [x] two\n")
    }

    func testClickingASummaryTogglesDetails() {
        let doc = MarkdownDocument()
        doc.replaceText("<details>\n<summary>More</summary>\n\nInside\n\n</details>\n")
        let preview = PreviewController(document: doc)
        preview.isActive = true
        let storage = preview.textView.textStorage!
        XCTAssertFalse(storage.string.contains("Inside"))
        var toggle: (String, Int)?
        storage.enumerateAttribute(.mdrDetailsToggle, in: NSRange(location: 0, length: storage.length)) { v, range, stop in
            if let id = v as? String { toggle = (id, range.location); stop.pointee = true }
        }
        guard let (id, index) = toggle else { return XCTFail("no summary") }
        preview.textView.onDetailsToggle?(id, index)
        XCTAssertTrue(storage.string.contains("Inside"))
    }
}

final class EncodingSaveTests: XCTestCase {
    func testUnencodableCharacterDetection() {
        XCTAssertNil(TextDecoding.firstUnencodableCharacter(in: "Árvíztűrő", encoding: .windowsCP1250))
        XCTAssertEqual(TextDecoding.firstUnencodableCharacter(in: "Árvíz 😀 tűrő", encoding: .windowsCP1250), "😀")
        XCTAssertNil(TextDecoding.firstUnencodableCharacter(in: "😀", encoding: .utf8))
    }

    func testDraftsDoNotChangeTheEncoding() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("enc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("legacy.md")
        try "Tükör\n".data(using: .windowsCP1250)!.write(to: url)
        let doc = try MarkdownDocument(contentsOf: url, ofType: "net.daringfireball.markdown")
        let legacy = doc.encoding
        XCTAssertNotEqual(legacy, .utf8)
        doc.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "😀 ")
        let saved = expectation(description: "draft")
        doc.save(to: dir.appendingPathComponent("draft.md"), ofType: "net.daringfireball.markdown",
                 for: .autosaveElsewhereOperation) { error in
            XCTAssertNil(error)
            saved.fulfill()
        }
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(doc.encoding, legacy)
    }
}

final class HighlighterBlockTests: XCTestCase {
    private func highlighted(_ text: String) -> (NSTextStorage, EditorController, MarkdownDocument) {
        let doc = MarkdownDocument()
        doc.replaceText(text)
        let editor = EditorController(document: doc)
        editor.highlighter.rehighlightAll()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return (doc.textStorage, editor, doc)
    }

    func testEmphasisSpanningLinesIsColored() {
        let (storage, editor, doc) = highlighted("Some *emphasis\nacross lines* here.\n\nNext *para")
        let ns = doc.text as NSString
        let font = storage.attribute(.font, at: ns.range(of: "across").location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        // Emphasis never crosses a blank line.
        let next = storage.attribute(.font, at: ns.range(of: "para").location, effectiveRange: nil) as? NSFont
        XCTAssertFalse(next?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        editor.detach()
    }

    func testIndentedCodeBlocksAreColoredButLazyLinesAreNot() {
        let (storage, editor, doc) = highlighted("Para\n\n    code line\n\nPara\n    lazy continuation\n\n- item\n\n    item paragraph")
        let ns = doc.text as NSString
        func isCode(_ text: String) -> Bool {
            let state = storage.attribute(.markdownFenceState, at: ns.range(of: text).location, effectiveRange: nil) as? Int ?? 0
            return state & SyntaxHighlighter.State.indentedCode != 0
        }
        XCTAssertTrue(isCode("code line"))
        XCTAssertFalse(isCode("lazy continuation"))
        XCTAssertFalse(isCode("item paragraph"))
        editor.detach()
    }

    func testIncrementalEditExtendsEmphasisAcrossLines() {
        let (storage, editor, doc) = highlighted("start *one\ntwo three\n")
        let ns = doc.text as NSString
        storage.replaceCharacters(in: NSRange(location: ns.range(of: "three").location + 5, length: 0), with: "*")
        let font = storage.attribute(.font, at: (doc.text as NSString).range(of: "two").location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        editor.detach()
    }
}
