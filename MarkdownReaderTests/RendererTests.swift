import AppKit
import XCTest
@testable import MarkdownReader

final class RendererTests: XCTestCase {
    private func render(_ md: String, baseURL: URL? = nil) -> NSAttributedString {
        let parsed = MarkdownParser.parse(md)
        return MarkdownRenderer(style: RenderStyle(fontSize: 16), baseURL: baseURL, references: parsed.references).render(parsed)
    }

    func testTextContentOfCommonElements() {
        let s = render("# Cím\n\n**Félkövér** és `kód`\n\n- egy\n- kettő\n\n1. első\n2. második").string
        XCTAssertTrue(s.contains("Cím\n"))
        XCTAssertTrue(s.contains("Félkövér és kód\n"))
        XCTAssertTrue(s.contains("\t•\tegy\n"))
        XCTAssertTrue(s.contains("\t2.\tmásodik\n"))
    }

    func testTaskListMarkers() {
        let s = render("- [ ] nyitott\n- [x] kész").string
        XCTAssertTrue(s.contains("☐\tnyitott"))
        XCTAssertTrue(s.contains("☑︎\tkész"))
    }

    func testFontsForEmphasis() {
        let s = render("**b** *i* `c`")
        func font(at text: String) -> NSFont? {
            let range = (s.string as NSString).range(of: text)
            return s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        }
        XCTAssertTrue(font(at: "b")!.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(font(at: "i")!.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertTrue(font(at: "c")!.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testLinksCarryDestination() {
        let s = render("[doc](other.md)")
        let range = (s.string as NSString).range(of: "doc")
        XCTAssertEqual(s.attribute(.link, at: range.location, effectiveRange: nil) as? String, "other.md")
    }

    func testTableUsesTextTableWithAllCells() {
        let s = render("| a | b |\n|---|--:|\n| 1 | 2 |")
        var cells = 0
        var alignments: [NSTextAlignment] = []
        s.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            guard let ps = value as? NSParagraphStyle, ps.textBlocks.last is NSTextTableBlock else { return }
            cells += 1
            alignments.append(ps.alignment)
        }
        XCTAssertEqual(cells, 4)
        XCTAssertEqual(alignments, [.natural, .right, .natural, .right])
    }

    func testCodeAndQuoteBlocksSpanFullWidth() {
        // Regression: without an explicit content width TextKit collapses
        // text blocks to one character per line.
        let s = render("```\nlet x = 1\n```\n\n> quote\n\n# Heading")
        let textView = TextKit1.makeTextView(width: 600)
        textView.textStorage?.setAttributedString(s)
        let layoutManager = textView.layoutManager!
        layoutManager.ensureLayout(for: textView.textContainer!)
        var lines = 0
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { _, _, _, _, _ in
            lines += 1
        }
        XCTAssertEqual(lines, 3)
    }

    func testScriptAndStyleContentIsNeverShown() {
        let s = render("<div>\n<script>alert('x')</script>\n<style>p{}</style>\nvisible\n</div>").string
        XCTAssertFalse(s.contains("alert"))
        XCTAssertFalse(s.contains("p{}"))
        XCTAssertTrue(s.contains("visible"))
    }

    func testHTMLSubset() {
        let s = render("<p align=\"center\"><b>Bold</b><br>line &amp; <kbd>⌘</kbd></p>")
        XCTAssertTrue(s.string.contains("Bold\u{2028}line & ⌘"))
        let ps = s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(ps?.alignment, .center)
    }

    func testRemoteImagesAreNotFetched() {
        let s = render("![Logo](https://example.com/logo.png)")
        XCTAssertFalse(s.containsAttachments)
        XCTAssertTrue(s.string.contains("Logo"))
    }

    func testRelativeImageResolvesAgainstDocumentDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("img kép"), withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 20, height: 10), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: dir.appendingPathComponent("img kép/pic.png"))
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertTrue(render("![x](img%20k%C3%A9p/pic.png)", baseURL: dir).containsAttachments)
        XCTAssertTrue(render("![x](<img kép/pic.png>)", baseURL: dir).containsAttachments)
        XCTAssertFalse(render("![x](missing.png)", baseURL: dir).containsAttachments)
    }

    func testLinkResolver() {
        let base = URL(fileURLWithPath: "/tmp/docs")
        XCTAssertEqual(LinkResolver.resolve("a/b.md#sec", relativeTo: base)?.path, "/tmp/docs/a/b.md")
        XCTAssertEqual(LinkResolver.resolve("../x%20y.md", relativeTo: base)?.path, "/tmp/x y.md")
        XCTAssertEqual(LinkResolver.resolve("https://e.com/x", relativeTo: base)?.absoluteString, "https://e.com/x")
        XCTAssertTrue(LinkResolver.isRemote("https://e.com"))
        XCTAssertFalse(LinkResolver.isRemote("img/a.png"))
        XCTAssertEqual(LinkResolver.anchor(for: "Táblázatok és Ősz!"), "táblázatok-és-ősz")
    }
}
