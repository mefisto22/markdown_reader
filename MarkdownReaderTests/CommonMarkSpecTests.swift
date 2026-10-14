import XCTest
@testable import MarkdownReader

/// Examples from the CommonMark 0.31 specification for the areas the README
/// used to list as incomplete: tabs and HTML blocks.
final class CommonMarkSpecTests: XCTestCase {
    private func blocks(_ md: String) -> [Block] { MarkdownParser.parse(md).blocks }

    private func item(_ blocks: [Block]) -> ListItem { ListItem(task: nil, blocks: blocks) }

    // MARK: Tabs (spec examples 1–11)

    func testTabs() {
        XCTAssertEqual(blocks("\tfoo\tbaz\t\tbim"), [.code(info: "", content: "foo\tbaz\t\tbim")])
        XCTAssertEqual(blocks("  \tfoo\tbaz\t\tbim"), [.code(info: "", content: "foo\tbaz\t\tbim")])
        XCTAssertEqual(blocks("    a\ta\n    ὐ\ta"), [.code(info: "", content: "a\ta\nὐ\ta")])
        XCTAssertEqual(blocks("  - foo\n\n\tbar"),
                       [.list(ListBlock(ordered: false, start: 1, tight: false,
                                        items: [item([.paragraph(text: "foo"), .paragraph(text: "bar")])]))])
        XCTAssertEqual(blocks("- foo\n\n\t\tbar"),
                       [.list(ListBlock(ordered: false, start: 1, tight: false,
                                        items: [item([.paragraph(text: "foo"), .code(info: "", content: "  bar")])]))])
        XCTAssertEqual(blocks(">\t\tfoo"), [.quote([.code(info: "", content: "  foo")])])
        XCTAssertEqual(blocks("-\t\tfoo"),
                       [.list(ListBlock(ordered: false, start: 1, tight: true, items: [item([.code(info: "", content: "  foo")])]))])
        XCTAssertEqual(blocks("    foo\n\tbar"), [.code(info: "", content: "foo\nbar")])
        let nested = blocks(" - foo\n   - bar\n\t - baz")
        guard case .list(let l1)? = nested.first, case .list(let l2)? = l1.items.first?.blocks.last,
              case .list(let l3)? = l2.items.first?.blocks.last else { return XCTFail("\(nested)") }
        XCTAssertEqual(l3.items.first?.blocks, [.paragraph(text: "baz")])
        XCTAssertEqual(blocks("#\tFoo"), [.heading(level: 1, text: "Foo")])
        XCTAssertEqual(blocks("*\t*\t*\t"), [.thematicBreak])
    }

    func testTabInsideListContentAndQuoteContinuation() {
        // A tab after the list marker counts as content indentation.
        XCTAssertEqual(blocks("-\tfoo\n\n\tbar"),
                       [.list(ListBlock(ordered: false, start: 1, tight: false,
                                        items: [item([.paragraph(text: "foo"), .paragraph(text: "bar")])]))])
        // `>` followed by a tab: the tab provides the optional space.
        XCTAssertEqual(blocks(">\tfoo"), [.quote([.paragraph(text: "foo")])])
        // Content tabs after an indented-code prefix are preserved.
        XCTAssertEqual(blocks("\t\tfoo"), [.code(info: "", content: "\tfoo")])
    }

    // MARK: HTML blocks (spec section 4.6)

    func testHTMLBlocks() {
        XCTAssertEqual(blocks("<table><tr><td>\n<pre>\n**Hello**,\n\n_world_.\n</pre>\n</td></tr></table>"),
                       [.html("<table><tr><td>\n<pre>\n**Hello**,"), .paragraph(text: "_world_.\n</pre>"),
                        .html("</td></tr></table>")])
        XCTAssertEqual(blocks("<div>\n  *hello*\n         <foo><a>"), [.html("<div>\n  *hello*\n         <foo><a>")])
        XCTAssertEqual(blocks("</div>\n*foo*"), [.html("</div>\n*foo*")])
        XCTAssertEqual(blocks("<DIV CLASS=\"foo\">\n\n*Markdown*\n\n</DIV>"),
                       [.html("<DIV CLASS=\"foo\">"), .paragraph(text: "*Markdown*"), .html("</DIV>")])
        XCTAssertEqual(blocks("<div id=\"foo\"\n  class=\"bar\">\n</div>"), [.html("<div id=\"foo\"\n  class=\"bar\">\n</div>")])
        XCTAssertEqual(blocks("<div>\n*foo*\n\n*bar*"), [.html("<div>\n*foo*"), .paragraph(text: "*bar*")])
        XCTAssertEqual(blocks("<a href=\"foo\">\n*bar*\n</a>"), [.html("<a href=\"foo\">\n*bar*\n</a>")])
        XCTAssertEqual(blocks("<Warning>\n*bar*\n</Warning>"), [.html("<Warning>\n*bar*\n</Warning>")])
        XCTAssertEqual(blocks("</ins>\n*bar*"), [.html("</ins>\n*bar*")])
        XCTAssertEqual(blocks("<del>\n\n*foo*\n\n</del>"), [.html("<del>"), .paragraph(text: "*foo*"), .html("</del>")])
        XCTAssertEqual(blocks("<del>*foo*</del>"), [.paragraph(text: "<del>*foo*</del>")])
        XCTAssertEqual(blocks("<pre language=\"haskell\"><code>\nimport Text.HTML.TagSoup\n\nmain :: IO ()\n</code></pre>\nokay"),
                       [.html("<pre language=\"haskell\"><code>\nimport Text.HTML.TagSoup\n\nmain :: IO ()\n</code></pre>"),
                        .paragraph(text: "okay")])
        XCTAssertEqual(blocks("<style\n  type=\"text/css\">\nh1 {color:red;}\n\np {color:blue;}\n</style>\nokay"),
                       [.html("<style\n  type=\"text/css\">\nh1 {color:red;}\n\np {color:blue;}\n</style>"), .paragraph(text: "okay")])
        XCTAssertEqual(blocks("<style\n  type=\"text/css\">\n\nfoo"), [.html("<style\n  type=\"text/css\">\n\nfoo")])
        XCTAssertEqual(blocks("> <div>\n> foo\n\nbar"), [.quote([.html("<div>\nfoo")]), .paragraph(text: "bar")])
        XCTAssertEqual(blocks("- <div>\n- foo"),
                       [.list(ListBlock(ordered: false, start: 1, tight: true,
                                        items: [item([.html("<div>")]), item([.paragraph(text: "foo")])]))])
        XCTAssertEqual(blocks("<style>p{color:red;}</style>\n*foo*"),
                       [.html("<style>p{color:red;}</style>"), .paragraph(text: "*foo*")])
        XCTAssertEqual(blocks("<!-- foo -->*bar*\n*baz*"), [.html("<!-- foo -->*bar*"), .paragraph(text: "*baz*")])
        XCTAssertEqual(blocks("<script>\nfoo\n</script>1. *bar*"), [.html("<script>\nfoo\n</script>1. *bar*")])
        XCTAssertEqual(blocks("<!-- Foo\n\nbar\n   baz -->\nokay"), [.html("<!-- Foo\n\nbar\n   baz -->"), .paragraph(text: "okay")])
        XCTAssertEqual(blocks("<?php\n\n  echo '>';\n\n?>\nokay"), [.html("<?php\n\n  echo '>';\n\n?>"), .paragraph(text: "okay")])
        XCTAssertEqual(blocks("<!DOCTYPE html>"), [.html("<!DOCTYPE html>")])
        XCTAssertEqual(blocks("  <!-- foo -->\n\n    <!-- foo -->"),
                       [.html("  <!-- foo -->"), .code(info: "", content: "<!-- foo -->")])
        XCTAssertEqual(blocks("  <div>\n\n    <div>"), [.html("  <div>"), .code(info: "", content: "<div>")])
        XCTAssertEqual(blocks("Foo\n<div>\nbar\n</div>"), [.paragraph(text: "Foo"), .html("<div>\nbar\n</div>")])
        XCTAssertEqual(blocks("<div>\nbar\n</div>\n*foo*"), [.html("<div>\nbar\n</div>\n*foo*")])
        XCTAssertEqual(blocks("Foo\n<a href=\"bar\">\nbaz"), [.paragraph(text: "Foo\n<a href=\"bar\">\nbaz")])
        XCTAssertEqual(blocks("<table>\n\n  <tr>\n\n    <td>\n      Hi\n    </td>\n\n  </tr>\n\n</table>"),
                       [.html("<table>"), .html("  <tr>"), .code(info: "", content: "<td>\n  Hi\n</td>"), .html("  </tr>"),
                        .html("</table>")])
    }

    func testHTMLBlocksInContainers() {
        // A list item ends an HTML block of type 6 at a blank line inside the item.
        XCTAssertEqual(blocks("- <div>\n  text\n\n  para"),
                       [.list(ListBlock(ordered: false, start: 1, tight: false,
                                        items: [item([.html("<div>\ntext"), .paragraph(text: "para")])]))])
        // A type 1 block inside a quote ends with the quote.
        XCTAssertEqual(blocks("> <pre>\n> code\n\nafter"), [.quote([.html("<pre>\ncode")]), .paragraph(text: "after")])
        // An HTML comment block inside a list item continues over a blank line.
        XCTAssertEqual(blocks("- <!--\n\n  -->\n- b"),
                       [.list(ListBlock(ordered: false, start: 1, tight: true,
                                        items: [item([.html("<!--\n\n-->")]), item([.paragraph(text: "b")])]))])
    }

    func testFullEntityTable() {
        let inlines = InlineParser().parse("&ngE; &frac78; &HilbertSpace; &DifferentialD; &ClockwiseContourIntegral; &bogus;")
        XCTAssertEqual(inlines.plainText, "≧̸ ⅞ ℋ ⅆ ∲ &bogus;")
    }
}
