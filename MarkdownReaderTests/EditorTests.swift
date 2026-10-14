import AppKit
import XCTest
@testable import MarkdownReader

final class ListContinuationTests: XCTestCase {
    func testBulletContinuation() {
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "- item"), .insert("\n- "))
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "  * nested"), .insert("\n  * "))
    }

    func testOrderedListIncrements() {
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "9. nine"), .insert("\n10. "))
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "3) three"), .insert("\n4) "))
    }

    func testTaskItemsContinueUnchecked() {
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "- [x] done"), .insert("\n- [ ] "))
    }

    func testEmptyItemEndsList() {
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "- "), .replaceLine(""))
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "> - "), .replaceLine("> "))
    }

    func testQuotesContinueAndEnd() {
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "> idézet"), .insert("\n> "))
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "> "), .replaceLine(""))
    }

    func testAutoIndentAndPlainLines() {
        XCTAssertEqual(ListContinuation.action(forLineBeforeCursor: "    code"), .insert("\n    "))
        XCTAssertNil(ListContinuation.action(forLineBeforeCursor: "plain text"))
        XCTAssertNil(ListContinuation.action(forLineBeforeCursor: "-not a list"))
    }

    func testIndentWidth() {
        XCTAssertEqual(ListContinuation.parse("- a").map(ListContinuation.indentWidth), 2)
        XCTAssertEqual(ListContinuation.parse("10. a").map(ListContinuation.indentWidth), 4)
    }
}

final class EditorBehaviorTests: XCTestCase {
    private func makeEditor(_ text: String) -> (MarkdownDocument, EditorController) {
        let doc = MarkdownDocument()
        doc.replaceText(text)
        let editor = EditorController(document: doc)
        return (doc, editor)
    }

    func testReturnContinuesListThroughTextView() {
        let (doc, editor) = makeEditor("- első")
        editor.textView.setSelectedRange(NSRange(location: (doc.text as NSString).length, length: 0))
        editor.textView.insertNewline(nil)
        editor.textView.insertText("második", replacementRange: editor.textView.selectedRange())
        XCTAssertEqual(doc.text, "- első\n- második")
        editor.detach()
    }

    func testTabIndentsListItem() {
        let (doc, editor) = makeEditor("- a\n- b")
        editor.textView.setSelectedRange(NSRange(location: 6, length: 0))
        editor.textView.insertTab(nil)
        XCTAssertEqual(doc.text, "- a\n  - b")
        editor.textView.insertBacktab(nil)
        XCTAssertEqual(doc.text, "- a\n- b")
        editor.detach()
    }

    func testBoldToggle() {
        let (doc, editor) = makeEditor("szó")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 3))
        editor.textView.toggleBold(nil)
        XCTAssertEqual(doc.text, "**szó**")
        editor.textView.toggleBold(nil)
        XCTAssertEqual(doc.text, "szó")
        editor.detach()
    }

    func testHighlighterTracksFenceStateIncrementally() {
        let (doc, editor) = makeEditor("a\nb\nc")
        let highlighter = editor.highlighter
        let storage = doc.textStorage
        // Process the initial full pass synchronously.
        highlighter.rehighlightAll()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(highlighter.isInsideFence(at: 4))

        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "```\n")
        XCTAssertTrue(highlighter.isInsideFence(at: (doc.text as NSString).length - 1))

        storage.replaceCharacters(in: NSRange(location: 0, length: 4), with: "")
        XCTAssertFalse(highlighter.isInsideFence(at: (doc.text as NSString).length - 1))
        editor.detach()
    }
}

final class SupportTests: XCTestCase {
    func testLineIndex() {
        let index = LineIndex("a\nbc\r\nd\re" as NSString)
        XCTAssertEqual(index.starts, [0, 2, 6, 8])
        XCTAssertEqual(index.line(containing: 0), 0)
        XCTAssertEqual(index.line(containing: 3), 1)
        XCTAssertEqual(index.line(containing: 9), 3)
    }

    func testTextStatistics() {
        let stats = TextStatistics.compute("Árvíztűrő  tükörfúrógép\nmásodik sor\r\n")
        XCTAssertEqual(stats.words, 4)
        XCTAssertEqual(stats.lines, 3)
        XCTAssertEqual(stats.characters, "Árvíztűrő  tükörfúrógép\nmásodik sor\r\n".count)
        XCTAssertEqual(TextStatistics.compute(""), TextStatistics())
    }
}

final class PreviewIncrementalTests: XCTestCase {
    func testIncrementalUpdateMatchesFullRender() {
        let doc = MarkdownDocument()
        doc.replaceText("# Egy\n\nelső bekezdés\n\n- a\n- b\n\n| x | y |\n|---|---|\n| 1 | 2 |\n\nutolsó")
        let preview = PreviewController(document: doc)
        preview.isActive = true

        func fullRender() -> String {
            let parsed = MarkdownParser.parse(doc.text)
            return MarkdownRenderer(style: RenderStyle(fontSize: Preferences.shared.readerFontSize), baseURL: nil,
                                    references: parsed.references).render(parsed).string
        }
        XCTAssertEqual(preview.textView.string, fullRender())

        // Edit a block in the middle; only that block is re-rendered.
        let range = (doc.text as NSString).range(of: "első bekezdés")
        doc.textStorage.replaceCharacters(in: range, with: "módosított **bekezdés**\n\n## Új cím")
        preview.update(immediately: true)
        XCTAssertEqual(preview.textView.string, fullRender())
        XCTAssertEqual(preview.headings.map(\.title), ["Egy", "Új cím"])

        // Delete everything.
        doc.textStorage.replaceCharacters(in: NSRange(location: 0, length: doc.textStorage.length), with: "")
        preview.update(immediately: true)
        XCTAssertEqual(preview.textView.string, "")
    }
}
