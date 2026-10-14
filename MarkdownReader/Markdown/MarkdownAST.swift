import Foundation

/// Block-level Markdown syntax tree.
///
/// Inline content (paragraph text, heading text, table cells) is kept as raw
/// source text and parsed lazily by `InlineParser` when a block is rendered.
/// This keeps whole-document parsing cheap: only blocks that actually need to
/// be (re)rendered pay for inline parsing.
enum Block: Hashable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case code(info: String, content: String)
    case quote([Block])
    case list(ListBlock)
    case table(TableBlock)
    case thematicBreak
    case html(String)
    /// Display math: a `$$ … $$` block (```` ```math ```` fences stay `.code`).
    case math(String)
    case definitionList([DefinitionItem])
    /// `<details>` with its `<summary>` (raw inline HTML/Markdown) and content.
    case details(summary: String, open: Bool, children: [Block])
    /// The document's footnote definitions, collected into one section that
    /// the parser appends after the last block (as GitHub does).
    case footnotes([FootnoteDefinition])
}

struct ListBlock: Hashable {
    var ordered: Bool
    var start: Int
    var tight: Bool
    var items: [ListItem]
}

struct ListItem: Hashable {
    /// `nil` for a normal item, `false` for `[ ]`, `true` for `[x]`.
    var task: Bool?
    var blocks: [Block]
    /// 0-based source line of the item's marker (used to toggle task items
    /// from the reader). Not part of equality.
    var line: Int = -1

    static func == (a: ListItem, b: ListItem) -> Bool {
        a.task == b.task && a.blocks == b.blocks
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(task)
        hasher.combine(blocks)
    }
}

struct DefinitionItem: Hashable {
    /// Raw inline text of each term.
    var terms: [String]
    /// Block content of each definition.
    var definitions: [[Block]]
}

struct FootnoteDefinition: Hashable {
    var label: String
    var number: Int
    var blocks: [Block]
}

enum TableAlignment: Hashable {
    case none, left, center, right
}

struct TableBlock: Hashable {
    var alignments: [TableAlignment]
    var header: [String]
    var rows: [[String]]
}

struct LinkReference: Equatable {
    var destination: String
    var title: String?
}

/// Result of parsing a whole document.
struct ParsedMarkdown {
    /// Top-level blocks in document order.
    var blocks: [Block]
    /// Source line range (0-based, half-open) of each top-level block.
    var lineRanges: [Range<Int>]
    /// Hash of each top-level block's source text, used to diff successive
    /// parses so that only changed blocks are re-rendered.
    var blockHashes: [Int]
    /// Link reference definitions, keyed by normalized label.
    var references: [String: LinkReference]
    /// Total number of source lines.
    var lineCount: Int
    /// Footnote numbers (in order of first reference), keyed by normalized label.
    var footnotes: [String: Int] = [:]
}

indirect enum Inline: Equatable {
    case text(String)
    case softBreak
    case lineBreak
    case code(String)
    case emphasis([Inline])
    case strong([Inline])
    case strikethrough([Inline])
    case link(destination: String, title: String?, children: [Inline])
    case image(source: String, title: String?, alt: [Inline])
    case html(String)
    /// TeX source of `$…$` (inline) or `$$…$$` (display) math.
    case math(String, display: Bool)
    case footnoteReference(label: String, number: Int)
}

extension Inline {
    /// Plain-text projection, used for image alt text and the outline.
    var plainText: String {
        switch self {
        case .text(let s), .code(let s): return s
        case .softBreak, .lineBreak: return " "
        case .html: return ""
        case .emphasis(let c), .strong(let c), .strikethrough(let c): return c.plainText
        case .link(_, _, let c): return c.plainText
        case .image(_, _, let alt): return alt.plainText
        case .math(let tex, _): return tex
        case .footnoteReference(_, let number): return "\(number)"
        }
    }
}

extension Array where Element == Inline {
    var plainText: String { map(\.plainText).joined() }
}
