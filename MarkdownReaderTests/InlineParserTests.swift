import XCTest
@testable import MarkdownReader

final class InlineParserTests: XCTestCase {
    private func parse(_ s: String, refs: [String: LinkReference] = [:]) -> [Inline] {
        InlineParser(references: refs).parse(s)
    }

    func testEmphasisAndStrong() {
        XCTAssertEqual(parse("*a* **b** ***c***"), [
            .emphasis([.text("a")]), .text(" "), .strong([.text("b")]), .text(" "),
            .emphasis([.strong([.text("c")])]),
        ])
        XCTAssertEqual(parse("_a_ __b__"), [.emphasis([.text("a")]), .text(" "), .strong([.text("b")])])
    }

    func testIntrawordUnderscoreIsLiteral() {
        XCTAssertEqual(parse("snake_case_name"), [.text("snake_case_name")])
        XCTAssertEqual(parse("in*tra*word"), [.text("in"), .emphasis([.text("tra")]), .text("word")])
    }

    func testUnmatchedDelimitersStayLiteral() {
        XCTAssertEqual(parse("a * b"), [.text("a * b")])
        XCTAssertEqual(parse("**open"), [.text("**open")])
    }

    func testHungarianWordsWithEmphasis() {
        XCTAssertEqual(parse("**árvíztűrő** _tükörfúrógép_"),
                       [.strong([.text("árvíztűrő")]), .text(" "), .emphasis([.text("tükörfúrógép")])])
    }

    func testStrikethrough() {
        XCTAssertEqual(parse("~~gone~~ ~one~"), [.strikethrough([.text("gone")]), .text(" "), .strikethrough([.text("one")])])
        XCTAssertEqual(parse("~~~not~~~"), [.text("~~~not~~~")])
    }

    func testCodeSpans() {
        XCTAssertEqual(parse("`code` and ``a ` b``"), [.code("code"), .text(" and "), .code("a ` b")])
        XCTAssertEqual(parse("` *x* `"), [.code("*x*")])
        XCTAssertEqual(parse("`unclosed"), [.text("`unclosed")])
    }

    func testEscapesAndEntities() {
        XCTAssertEqual(parse("\\*not\\* &amp; &#337; &#x171; &odblac; &bogus;"),
                       [.text("*not* & ő ű ő &bogus;")])
    }

    func testBreaks() {
        XCTAssertEqual(parse("a\nb"), [.text("a"), .softBreak, .text("b")])
        XCTAssertEqual(parse("a  \nb"), [.text("a"), .lineBreak, .text("b")])
        XCTAssertEqual(parse("a\\\nb"), [.text("a"), .lineBreak, .text("b")])
    }

    func testInlineLinksAndImages() {
        XCTAssertEqual(parse("[text](url.md \"T\")"),
                       [.link(destination: "url.md", title: "T", children: [.text("text")])])
        XCTAssertEqual(parse("![alt *x*](img/a b.png)"), [.text("![alt "), .emphasis([.text("x")]), .text("](img/a b.png)")])
        XCTAssertEqual(parse("![alt](<img/a b.png>)"),
                       [.image(source: "img/a b.png", title: nil, alt: [.text("alt")])])
        XCTAssertEqual(parse("[a](foo(bar))"), [.link(destination: "foo(bar)", title: nil, children: [.text("a")])])
        XCTAssertEqual(parse("[empty]()"), [.link(destination: "", title: nil, children: [.text("empty")])])
    }

    func testNestedLinksAreNotAllowed() {
        XCTAssertEqual(parse("[a [b](x) c](y)"),
                       [.text("[a "), .link(destination: "x", title: nil, children: [.text("b")]), .text(" c](y)")])
    }

    func testReferenceLinks() {
        let refs = ["foo": LinkReference(destination: "/url", title: "t")]
        let expected: Inline = .link(destination: "/url", title: "t", children: [.text("Foo")])
        XCTAssertEqual(parse("[Foo][foo]", refs: refs), [expected])
        XCTAssertEqual(parse("[Foo][]", refs: refs), [expected])
        XCTAssertEqual(parse("[Foo]", refs: refs), [expected])
        XCTAssertEqual(parse("[missing]", refs: refs), [.text("[missing]")])
    }

    func testAutolinks() {
        XCTAssertEqual(parse("<https://a.b/c>"), [.link(destination: "https://a.b/c", title: nil, children: [.text("https://a.b/c")])])
        XCTAssertEqual(parse("<me@example.com>"),
                       [.link(destination: "mailto:me@example.com", title: nil, children: [.text("me@example.com")])])
    }

    func testExtendedAutolinksTrimTrailingPunctuation() {
        XCTAssertEqual(parse("see https://example.com/a."), [
            .text("see "), .link(destination: "https://example.com/a", title: nil, children: [.text("https://example.com/a")]), .text("."),
        ])
        XCTAssertEqual(parse("(www.example.com)"), [
            .text("("), .link(destination: "http://www.example.com", title: nil, children: [.text("www.example.com")]), .text(")"),
        ])
        XCTAssertEqual(parse("nothttps://x.y"), [.text("nothttps://x.y")])
    }

    func testRawHTMLIsKeptAsHTMLNode() {
        XCTAssertEqual(parse("a <b>c</b> <!-- x -->"),
                       [.text("a "), .html("<b>"), .text("c"), .html("</b>"), .text(" "), .html("<!-- x -->")])
        XCTAssertEqual(parse("a < b"), [.text("a < b")])
    }

    func testPlainText() {
        XCTAssertEqual(parse("**Bold** [link](x) `c`").plainText, "Bold link c")
    }
}
