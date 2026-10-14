import XCTest
@testable import MarkdownReader

final class BlockParserTests: XCTestCase {
    private func blocks(_ md: String) -> [Block] { MarkdownParser.parse(md).blocks }

    func testATXAndSetextHeadings() {
        XCTAssertEqual(blocks("# Title"), [.heading(level: 1, text: "Title")])
        XCTAssertEqual(blocks("###   Spaced ###  "), [.heading(level: 3, text: "Spaced")])
        XCTAssertEqual(blocks("#hashtag"), [.paragraph(text: "#hashtag")])
        XCTAssertEqual(blocks("####### seven"), [.paragraph(text: "####### seven")])
        XCTAssertEqual(blocks("Title\n=====\n\nSub\n---"),
                       [.heading(level: 1, text: "Title"), .heading(level: 2, text: "Sub")])
    }

    func testParagraphsJoinLinesAndKeepHardBreakSpaces() {
        XCTAssertEqual(blocks("one\ntwo  \nthree\n\nnext"),
                       [.paragraph(text: "one\ntwo  \nthree"), .paragraph(text: "next")])
    }

    func testThematicBreakVersusSetextAndList() {
        XCTAssertEqual(blocks("***"), [.thematicBreak])
        XCTAssertEqual(blocks("- - -"), [.thematicBreak])
        XCTAssertEqual(blocks("text\n\n---"), [.paragraph(text: "text"), .thematicBreak])
    }

    func testFencedCodeBlocks() {
        XCTAssertEqual(blocks("```swift\nlet a = 1\n\nlet b = 2\n```"),
                       [.code(info: "swift", content: "let a = 1\n\nlet b = 2")])
        XCTAssertEqual(blocks("~~~\n# not a heading\n~~~"), [.code(info: "", content: "# not a heading")])
        // Unclosed fence runs to the end of the document.
        XCTAssertEqual(blocks("```\nopen"), [.code(info: "", content: "open")])
        // A shorter closing fence does not close.
        XCTAssertEqual(blocks("````\na\n```\nb\n````"), [.code(info: "", content: "a\n```\nb")])
        // Indentation of the opening fence is removed from content lines.
        XCTAssertEqual(blocks("  ```\n  x\n    y\n  ```"), [.code(info: "", content: "x\n  y")])
    }

    func testIndentedCodeBlock() {
        XCTAssertEqual(blocks("    code\n      more\n\npara"),
                       [.code(info: "", content: "code\n  more"), .paragraph(text: "para")])
        // Indented code cannot interrupt a paragraph.
        XCTAssertEqual(blocks("para\n    lazy"), [.paragraph(text: "para\nlazy")])
    }

    func testBlockQuotesNestedAndLazy() {
        XCTAssertEqual(blocks("> a\nlazy\n> > b"),
                       [.quote([.paragraph(text: "a\nlazy"), .quote([.paragraph(text: "b")])])])
    }

    func testTightAndLooseLists() {
        guard case .list(let tight)? = blocks("- a\n- b").first else { return XCTFail() }
        XCTAssertTrue(tight.tight)
        XCTAssertFalse(tight.ordered)
        XCTAssertEqual(tight.items.count, 2)

        guard case .list(let loose)? = blocks("- a\n\n- b").first else { return XCTFail() }
        XCTAssertFalse(loose.tight)
    }

    func testOrderedListStartAndNesting() {
        guard case .list(let list)? = blocks("3. three\n4. four\n   - nested\n     - deeper").first else { return XCTFail() }
        XCTAssertTrue(list.ordered)
        XCTAssertEqual(list.start, 3)
        XCTAssertEqual(list.items.count, 2)
        guard case .list(let nested)? = list.items[1].blocks.last else { return XCTFail("missing nested list") }
        guard case .list(let deeper)? = nested.items[0].blocks.last else { return XCTFail("missing deeper list") }
        XCTAssertEqual(deeper.items[0].blocks, [.paragraph(text: "deeper")])
    }

    func testDifferentBulletStartsNewList() {
        let result = blocks("- a\n+ b")
        XCTAssertEqual(result.count, 2)
    }

    func testOrderedListOnlyInterruptsParagraphWhenStartingAtOne() {
        XCTAssertEqual(blocks("The year\n2024. was good"), [.paragraph(text: "The year\n2024. was good")])
        XCTAssertEqual(blocks("Steps:\n1. first").count, 2)
    }

    func testTaskListItems() {
        guard case .list(let list)? = blocks("- [ ] todo\n- [x] done\n- [X] Done\n- [y] no\n- [ ]").first else {
            return XCTFail()
        }
        XCTAssertEqual(list.items.map(\.task), [false, true, true, nil, nil])
        XCTAssertEqual(list.items[0].blocks, [.paragraph(text: "todo")])
        XCTAssertEqual(list.items[3].blocks, [.paragraph(text: "[y] no")])
    }

    func testTables() {
        let md = """
        | Név | Érték | Közép |
        |:----|------:|:-----:|
        | ő   | 1 \\| 2 | x |
        | ű |
        """
        guard case .table(let table)? = blocks(md).first else { return XCTFail() }
        XCTAssertEqual(table.alignments, [.left, .right, .center])
        XCTAssertEqual(table.header, ["Név", "Érték", "Közép"])
        XCTAssertEqual(table.rows, [["ő", "1 | 2", "x"], ["ű", "", ""]])
    }

    func testTableNeedsMatchingHeaderAndEndsAtBlankLine() {
        XCTAssertEqual(blocks("a | b\n--|--|--"), [.paragraph(text: "a | b\n--|--|--")])
        let result = blocks("intro\na | b\n--|--\n1 | 2\n\nafter")
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.first, .paragraph(text: "intro"))
        XCTAssertEqual(result.last, .paragraph(text: "after"))
    }

    func testHTMLBlocks() {
        XCTAssertEqual(blocks("<div align=\"center\">\n*x*\n</div>\n\npara"),
                       [.html("<div align=\"center\">\n*x*\n</div>"), .paragraph(text: "para")])
        XCTAssertEqual(blocks("<!-- comment -->\ntext"), [.html("<!-- comment -->"), .paragraph(text: "text")])
        // Type 7 (inline tag on its own line) cannot interrupt a paragraph.
        XCTAssertEqual(blocks("para\n<span>x</span>"), [.paragraph(text: "para\n<span>x</span>")])
    }

    func testReferenceDefinitionsAreExtracted() {
        let parsed = MarkdownParser.parse("[Foo Bar]: https://example.com \"Title\"\n[x]: <a b.md>\n\ntext")
        XCTAssertEqual(parsed.blocks, [.paragraph(text: "text")])
        XCTAssertEqual(parsed.references["foo bar"], LinkReference(destination: "https://example.com", title: "Title"))
        XCTAssertEqual(parsed.references["x"]?.destination, "a b.md")
    }

    func testLineRangesAndHashes() {
        let parsed = MarkdownParser.parse("# A\n\npara\nmore\n\n- x\n")
        XCTAssertEqual(parsed.lineRanges, [0..<2, 2..<5, 5..<6])
        XCTAssertEqual(parsed.lineCount, 6)
        let edited = MarkdownParser.parse("# A\n\npara\nCHANGED\n\n- x\n")
        XCTAssertEqual(parsed.blockHashes[0], edited.blockHashes[0])
        XCTAssertNotEqual(parsed.blockHashes[1], edited.blockHashes[1])
        XCTAssertEqual(parsed.blockHashes[2], edited.blockHashes[2])
    }

    func testCRLFAndCRLineEndings() {
        XCTAssertEqual(blocks("# A\r\n\r\ntext\r\nmore"), [.heading(level: 1, text: "A"), .paragraph(text: "text\nmore")])
        XCTAssertEqual(blocks("a\rb"), [.paragraph(text: "a\nb")])
    }

    func testTabsInIndentation() {
        XCTAssertEqual(blocks("\tcode"), [.code(info: "", content: "code")])
        guard case .list(let list)? = blocks("-\titem").first else { return XCTFail() }
        XCTAssertEqual(list.items[0].blocks, [.paragraph(text: "item")])
    }

    func testHungarianAndEmojiTextIsPreserved() {
        let text = "Árvíztűrő tükörfúrógép – ŐŰ őű 👍🏽"
        XCTAssertEqual(blocks("## \(text)"), [.heading(level: 2, text: text)])
        XCTAssertEqual(blocks(text), [.paragraph(text: text)])
    }

    func testEmptyDocument() {
        XCTAssertTrue(blocks("").isEmpty)
        XCTAssertTrue(blocks("\n\n   \n").isEmpty)
    }

    func testLargeDocumentParsesQuickly() {
        let chunk = "## Szakasz\n\nBekezdés **félkövér** szöveggel.\n\n- a\n- b\n\n| x | y |\n|---|---|\n| 1 | 2 |\n\n"
        let text = String(repeating: chunk, count: 20_000) // ~1.4 MB
        measure {
            _ = MarkdownParser.parse(text)
        }
    }
}
