import AppKit

extension NSAttributedString.Key {
    /// Source line of a task item's marker, relative to its top-level block.
    static let mdrTaskLine = NSAttributedString.Key("MDRTaskLine")
    /// Identifier of a `<details>` element whose summary toggles it.
    static let mdrDetailsToggle = NSAttributedString.Key("MDRDetailsToggle")
    /// In-document anchor (`fn-1`, `fnref-1`, `<a id>`), used for `#…` links.
    static let mdrAnchor = NSAttributedString.Key("MDRAnchor")
}

/// Settings that affect rendering beyond the Markdown source.
struct RenderOptions {
    /// Width of the reader's text column. When set, code blocks and tables
    /// wider than the column scroll horizontally instead of wrapping.
    var availableWidth: CGFloat?
    /// Fetch remote images (View ▸ Load Remote Images).
    var loadRemoteImages = false
    /// Expanded state of `<details>` elements the user toggled, by id.
    var detailsState: [String: Bool] = [:]
    /// Show every `<details>` expanded (printing and PDF export).
    var expandAllDetails = false
}

/// What a rendered block depends on besides its source, so the preview
/// knows when to render it again.
struct BlockRenderInfo {
    /// Column widths at which a code block or table switches between
    /// wrapping and horizontal scrolling.
    var widthThresholds: [CGFloat] = []
    /// Remote images that were still loading.
    var pendingImages: Set<URL> = []
}

/// Converts the Markdown AST into an `NSAttributedString` for a TextKit 1
/// `NSTextView`. Code blocks and block quotes use `NSTextBlock`, tables use
/// `NSTextTable`; images, rules, math and diagrams use attachment cells.
///
/// Raw HTML is never interpreted by a browser engine: a safe subset of tags
/// and inline CSS is mapped to text attributes, everything else is dropped.
/// Remote resources are fetched only when the user turned that on.
final class MarkdownRenderer {
    let style: RenderStyle
    let baseURL: URL?
    let options: RenderOptions
    private let inlineParser: InlineParser
    private let fonts = FontCache()

    /// Dependencies of the most recently rendered top-level block.
    private(set) var lastInfo = BlockRenderInfo()
    private var blockKey = 0
    private var blockStartLine = 0
    private var detailsOrdinal = 0

    init(style: RenderStyle, baseURL: URL?, references: [String: LinkReference],
         footnotes: [String: Int] = [:], options: RenderOptions = RenderOptions()) {
        self.style = style
        self.baseURL = baseURL
        self.options = options
        self.inlineParser = InlineParser(references: references, footnotes: footnotes)
    }

    /// Renders a top-level block. The result ends with a newline (or is empty).
    /// `key` identifies the block's content (for `<details>` state) and
    /// `startLine` is its first source line (for task toggling).
    func render(_ block: Block, key: Int = 0, startLine: Int = 0) -> NSAttributedString {
        lastInfo = BlockRenderInfo()
        blockKey = key
        blockStartLine = startLine
        detailsOrdinal = 0
        let out = NSMutableAttributedString()
        let ctx = Context()
        renderBlock(block, ctx, out)
        if out.length > 0 {
            setTrailingSpacing(out, from: 0, ctx: ctx, spacing: spacingAfter(block, ctx))
            previousTail = (out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: nil) as? NSParagraphStyle)?
                .textBlocks ?? []
        }
        return out
    }

    /// Renders a complete document (used for printing / PDF export and tests).
    func render(_ parsed: ParsedMarkdown) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, block) in parsed.blocks.enumerated() {
            let start = i < parsed.lineRanges.count ? parsed.lineRanges[i].lowerBound : 0
            out.append(render(block, key: i < parsed.blockHashes.count ? parsed.blockHashes[i] : 0, startLine: start))
        }
        return out
    }

    // MARK: - Context

    private struct Marker {
        var text: String
        var color: NSColor
        var font: NSFont
        var taskLine: Int?
    }

    private struct Context {
        var indent: CGFloat = 0
        var blocks: [NSTextBlock] = []
        var tight = false
        var color: NSColor = RenderColors.text
        var marker: Marker?
        var listDepth = 0
    }

    /// Character-level formatting state.
    private struct InlineAttrs {
        var size: CGFloat
        var weight: NSFont.Weight = .regular
        var bold = false
        var italic = false
        var mono = false
        var strike = false
        var underline = false
        var highlight = false
        var background: NSColor?
        var baselineShift = 0
        var color: NSColor
        var link: String?
        var title: String?
        var hidden = false
        var uppercase = false
    }

    private func attributes(_ a: InlineAttrs) -> [NSAttributedString.Key: Any] {
        var size = a.size
        if a.mono { size = (size * 0.9).rounded() }
        if a.baselineShift != 0 { size = (size * 0.75).rounded() }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: fonts.font(size: size, bold: a.bold, italic: a.italic, mono: a.mono, weight: a.weight),
            .foregroundColor: a.color,
        ]
        if a.mono { attrs[.backgroundColor] = RenderColors.inlineCodeBackground }
        if a.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if a.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if a.highlight { attrs[.backgroundColor] = RenderColors.mark }
        if let background = a.background { attrs[.backgroundColor] = background }
        if a.baselineShift != 0 { attrs[.baselineOffset] = CGFloat(a.baselineShift) * a.size * 0.33 }
        if let link = a.link {
            attrs[.link] = link
            attrs[.toolTip] = a.title ?? link
        } else if let title = a.title {
            attrs[.toolTip] = title
        }
        return attrs
    }

    private func baseAttrs(_ ctx: Context) -> InlineAttrs {
        InlineAttrs(size: style.fontSize, color: ctx.color)
    }

    // MARK: - Paragraph styles

    private func paragraphStyle(_ ctx: Context, firstIndent: CGFloat? = nil, headIndent: CGFloat? = nil,
                                before: CGFloat = 0, after: CGFloat? = nil, alignment: NSTextAlignment = .natural,
                                tabs: [NSTextTab] = [], lineHeight: CGFloat? = nil,
                                extraBlocks: [NSTextBlock] = []) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.textBlocks = ctx.blocks + extraBlocks
        p.firstLineHeadIndent = firstIndent ?? ctx.indent
        p.headIndent = headIndent ?? ctx.indent
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after ?? style.paragraphSpacing
        p.alignment = alignment
        p.tabStops = tabs
        p.defaultTabInterval = style.fontSize * 2
        p.lineHeightMultiple = lineHeight ?? style.lineHeightMultiple
        return p
    }

    /// Paragraph styles without text blocks, shared between all paragraphs
    /// with the same settings (most paragraphs and list items). Without
    /// sharing, a large document holds hundreds of thousands of equal style
    /// objects, and attribute dictionaries that cannot be uniqued.
    private var plainStyles: [NSParagraphStyle] = []
    /// The style most recently handed out for a paragraph inside text blocks:
    /// consecutive paragraphs of one block (code lines, quote paragraphs)
    /// share it. Blocks are compared by identity, so separate blocks stay separate.
    private var lastBlockStyle: NSParagraphStyle?

    /// Styles whose text blocks are all shared blocks, by block identity.
    private var sharedBlockStyles: [[ObjectIdentifier]: [NSParagraphStyle]] = [:]

    private static func sameBlocks(_ a: NSParagraphStyle, _ b: NSParagraphStyle) -> Bool {
        a.textBlocks.count == b.textBlocks.count && zip(a.textBlocks, b.textBlocks).allSatisfy { $0 === $1 }
    }

    private func interned(_ ps: NSParagraphStyle) -> NSParagraphStyle {
        if ps.textBlocks.isEmpty {
            // isEqual compares every setting; the list stays small (a few dozen).
            if let shared = plainStyles.first(where: { $0.isEqual(ps) }) { return shared }
            let copy = (ps.copy() as? NSParagraphStyle) ?? ps
            if plainStyles.count < 256 { plainStyles.append(copy) }
            return copy
        }
        let ids = ps.textBlocks.map(ObjectIdentifier.init)
        if ids.allSatisfy({ sharedBlockKeys[$0] != nil }) {
            var list = sharedBlockStyles[ids] ?? []
            if let shared = list.first(where: { $0.isEqual(ps) }) { return shared }
            let copy = (ps.copy() as? NSParagraphStyle) ?? ps
            if list.count < 64 {
                list.append(copy)
                sharedBlockStyles[ids] = list
            }
            return copy
        }
        if let last = lastBlockStyle, Self.sameBlocks(last, ps), last.isEqual(ps) { return last }
        let copy = (ps.copy() as? NSParagraphStyle) ?? ps
        lastBlockStyle = copy
        return copy
    }

    // MARK: - Shared text blocks

    /// Code blocks, quotes and heading rules with the same settings share one
    /// `NSTextBlock` instance (TextKit treats only *contiguous* paragraphs
    /// with the same block as one block). Neighbouring elements of the same
    /// kind alternate between two variants so they never merge, and the
    /// bottom margin is part of the identity, so shared blocks are never
    /// mutated after use.
    private enum SharedBlockKind: Int { case code, quote, headingRule }

    private struct BlockKey: Hashable {
        var kind: Int
        var indent: CGFloat
        var bottom: CGFloat
        var variant: Int
    }

    private var sharedBlocks: [BlockKey: MarkdownTextBlock] = [:]
    private var sharedBlockKeys: [ObjectIdentifier: BlockKey] = [:]
    /// Text blocks of the last paragraph of the previous top-level block.
    private var previousTail: [NSTextBlock] = []

    private func sharedBlock(_ key: BlockKey) -> MarkdownTextBlock {
        if let block = sharedBlocks[key] { return block }
        let block = MarkdownTextBlock()
        // Without an explicit content width TextKit shrinks a block to its
        // minimum width (one character per line).
        block.setContentWidth(100, type: .percentageValueType)
        block.setWidth(key.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        block.setWidth(key.bottom, type: .absoluteValueType, for: .margin, edge: .maxY)
        switch SharedBlockKind(rawValue: key.kind)! {
        case .code:
            block.fillColor = RenderColors.codeBackground
            block.cornerRadius = 6
            block.setWidth(style.codePadding, type: .absoluteValueType, for: .padding)
        case .quote:
            block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(RenderColors.quoteBorder, for: .minX)
            block.setWidth((style.fontSize * 0.9).rounded(), type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(2, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(2, type: .absoluteValueType, for: .padding, edge: .maxY)
        case .headingRule:
            block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            block.setBorderColor(RenderColors.headingRule, for: .maxY)
            block.setWidth((style.fontSize * 0.3).rounded(), type: .absoluteValueType, for: .padding, edge: .maxY)
        }
        sharedBlocks[key] = block
        sharedBlockKeys[ObjectIdentifier(block)] = key
        return block
    }

    /// A shared block for a new element at nesting `depth`.
    private func newBlock(_ kind: SharedBlockKind, indent: CGFloat, depth: Int, _ out: NSMutableAttributedString) -> MarkdownTextBlock {
        var neighbour: NSTextBlock?
        if out.length > 0 {
            if let ps = out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: nil) as? NSParagraphStyle,
               ps.textBlocks.count > depth {
                neighbour = ps.textBlocks[depth]
            }
        } else if previousTail.count > depth {
            neighbour = previousTail[depth]
        }
        var variant = 0
        if let neighbour, let key = sharedBlockKeys[ObjectIdentifier(neighbour)], key.kind == kind.rawValue, key.indent == indent {
            variant = 1 - key.variant
        }
        return sharedBlock(BlockKey(kind: kind.rawValue, indent: indent, bottom: 0, variant: variant))
    }

    /// Gives the block at `depth` of the paragraphs in `range` a bottom margin
    /// of `bottom`: shared blocks are swapped for the matching variant,
    /// tables (never shared) are changed in place.
    private func setBlockBottom(_ old: NSTextBlock, depth: Int, bottom: CGFloat, in out: NSMutableAttributedString, range: NSRange) {
        if let cell = old as? NSTextTableBlock {
            cell.table.setWidth(bottom, type: .absoluteValueType, for: .margin, edge: .maxY)
            return
        }
        guard var key = sharedBlockKeys[ObjectIdentifier(old)] else {
            old.setWidth(bottom, type: .absoluteValueType, for: .margin, edge: .maxY)
            return
        }
        guard key.bottom != bottom else { return }
        key.bottom = bottom
        let replacement = sharedBlock(key)
        out.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
            guard let ps = value as? NSParagraphStyle, ps.textBlocks.count > depth, ps.textBlocks[depth] === old,
                  let mutable = ps.mutableCopy() as? NSMutableParagraphStyle else { return }
            var blocks = ps.textBlocks
            blocks[depth] = replacement
            mutable.textBlocks = blocks
            setParagraphStyle(mutable, in: out, range: subrange)
        }
    }

    private func setParagraphStyle(_ ps: NSParagraphStyle, in out: NSMutableAttributedString, range: NSRange) {
        out.addAttribute(.paragraphStyle, value: interned(ps), range: range)
    }

    private func spacingAfter(_ block: Block, _ ctx: Context) -> CGFloat {
        if case .heading(let level, _) = block { return style.headingSpacingAfter(level) }
        return ctx.tight ? style.tightSpacing : style.paragraphSpacing
    }

    /// Sets the spacing below the last paragraph appended since `start`. When
    /// that paragraph sits inside a text block created by this element (code
    /// block, quote, table), the spacing becomes the block's bottom margin so
    /// it appears outside the block's background and borders.
    private func setTrailingSpacing(_ out: NSMutableAttributedString, from start: Int, ctx: Context, spacing: CGFloat) {
        guard out.length > start else { return }
        let last = out.length - 1
        let range = (out.string as NSString).paragraphRange(for: NSRange(location: last, length: 0))
        guard let original = out.attribute(.paragraphStyle, at: last, effectiveRange: nil) as? NSParagraphStyle else { return }
        let depth = ctx.blocks.count
        let blocked = original.textBlocks.count > depth
        if blocked {
            let element = NSRange(location: start, length: out.length - start)
            for (d, block) in original.textBlocks.enumerated() where d >= depth {
                setBlockBottom(block, depth: d, bottom: d == depth ? spacing : 0, in: out, range: element)
            }
        }
        guard let ps = out.attribute(.paragraphStyle, at: last, effectiveRange: nil) as? NSParagraphStyle,
              let mutable = ps.mutableCopy() as? NSMutableParagraphStyle else { return }
        mutable.paragraphSpacing = blocked ? 0 : spacing
        setParagraphStyle(mutable, in: out, range: NSRange(location: max(range.location, start),
                                                                         length: NSMaxRange(range) - max(range.location, start)))
    }

    // MARK: - Blocks

    private func renderBlocks(_ blocks: [Block], _ ctx: Context, _ out: NSMutableAttributedString) {
        for (i, block) in blocks.enumerated() {
            var c = ctx
            if i > 0 { c.marker = nil }
            let start = out.length
            renderBlock(block, c, out)
            setTrailingSpacing(out, from: start, ctx: ctx, spacing: spacingAfter(block, ctx))
        }
    }

    private func renderBlock(_ block: Block, _ ctx: Context, _ out: NSMutableAttributedString) {
        switch block {
        case .paragraph(let text):
            let inlines = inlineParser.parse(text)
            // A paragraph that is only display math is centered like a $$ block.
            if inlines.count == 1, case .math(let tex, true) = inlines[0] {
                renderDisplayMath(tex, ctx, out)
            } else {
                renderInlineParagraph(inlines, ctx, out, attrs: baseAttrs(ctx))
            }
        case .heading(let level, let text):
            renderHeading(level, text, ctx, out)
        case .code(let info, let content):
            let language = info.split(separator: " ").first.map { $0.lowercased() } ?? ""
            if language == "math" || language == "latex-math" || language == "katex" {
                renderDisplayMath(content, ctx, out)
            } else if language == "mermaid" {
                renderMermaid(content, info, ctx, out)
            } else {
                renderCode(info, content, ctx, out)
            }
        case .quote(let children):
            renderQuote(children, ctx, out)
        case .list(let list):
            renderList(list, ctx, out)
        case .table(let table):
            renderTable(table, ctx, out)
        case .thematicBreak:
            renderRule(ctx, out)
        case .html(let html):
            renderHTMLBlock(html, ctx, out)
        case .math(let tex):
            renderDisplayMath(tex, ctx, out)
        case .definitionList(let items):
            renderDefinitionList(items, ctx, out)
        case .details(let summary, let open, let children):
            renderDetails(summary, open: open, children, ctx, out)
        case .footnotes(let definitions):
            renderFootnotes(definitions, ctx, out)
        }
    }

    /// Appends one paragraph of inline content, including a pending list marker.
    private func renderInlineParagraph(_ inlines: [Inline], _ ctx: Context, _ out: NSMutableAttributedString,
                                       attrs: InlineAttrs, before: CGFloat = 0, alignment: NSTextAlignment = .natural,
                                       extraBlocks: [NSTextBlock] = []) {
        let start = out.length
        var tabs: [NSTextTab] = []
        var firstIndent = ctx.indent
        var blocks = extraBlocks
        if let marker = ctx.marker {
            let gap = (style.fontSize * 0.45).rounded()
            firstIndent = ctx.indent - style.listMarkerWidth
            tabs = [NSTextTab(textAlignment: .right, location: ctx.indent - gap),
                    NSTextTab(textAlignment: .left, location: ctx.indent)]
            out.append(markerString(marker))
            blocks = []
        }
        var state = HTMLInlineState()
        appendInlines(inlines, attrs, out, &state)
        out.append(NSAttributedString(string: "\n", attributes: attributes(attrs)))
        let indent = blocks.isEmpty ? ctx.indent : 0
        let ps = paragraphStyle(ctx, firstIndent: blocks.isEmpty ? firstIndent : 0, headIndent: indent,
                                before: before, alignment: alignment, tabs: tabs, extraBlocks: blocks)
        // A line-height multiple would also scale image heights, leaving a gap above images.
        if out.attributedSubstring(from: NSRange(location: start, length: out.length - start)).containsAttachments {
            ps.lineHeightMultiple = 1
        }
        setParagraphStyle(ps, in: out, range: NSRange(location: start, length: out.length - start))
    }

    /// `\t<marker>\t`; task markers are clickable in the reader.
    private func markerString(_ marker: Marker) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "\t" + marker.text + "\t",
                                               attributes: [.font: marker.font, .foregroundColor: marker.color])
        if let line = marker.taskLine {
            result.addAttributes([.mdrTaskLine: line, .cursor: NSCursor.pointingHand, .toolTip: "Click to toggle"],
                                 range: NSRange(location: 1, length: (marker.text as NSString).length))
        }
        return result
    }

    private func renderHeading(_ level: Int, _ text: String, _ ctx: Context, _ out: NSMutableAttributedString) {
        var attrs = baseAttrs(ctx)
        attrs.size = style.headingSize(level)
        attrs.weight = level <= 2 ? .bold : .semibold
        if level == 6 { attrs.color = RenderColors.secondaryText }
        var extra: [NSTextBlock] = []
        if level <= 2, ctx.marker == nil {
            extra = [newBlock(.headingRule, indent: ctx.indent, depth: ctx.blocks.count, out)]
        }
        let start = out.length
        renderInlineParagraph(inlineParser.parse(text), ctx, out, attrs: attrs,
                              before: style.headingSpacingBefore(level), extraBlocks: extra)
        // Headings use a slightly tighter line height.
        out.enumerateAttribute(.paragraphStyle, in: NSRange(location: start, length: out.length - start)) { value, range, _ in
            guard let ps = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            ps.lineHeightMultiple = 1.08
            setParagraphStyle(ps, in: out, range: range)
        }
    }

    // MARK: Code

    private func highlightedCode(_ info: String, _ content: String, font: NSFont, color: NSColor,
                                 paragraphStyle ps: NSParagraphStyle?) -> NSMutableAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let ps { attrs[.paragraphStyle] = interned(ps) }
        let text = NSMutableAttributedString(string: content, attributes: attrs)
        if let tokens = CodeHighlighter.highlight(content, language: info) {
            for (range, token) in tokens where NSMaxRange(range) <= text.length {
                text.addAttribute(.foregroundColor, value: token.color, range: range)
            }
        }
        return text
    }

    private func renderCode(_ info: String, _ content: String, _ ctx: Context, _ out: NSMutableAttributedString) {
        let font = fonts.font(size: style.codeFontSize, mono: true)
        let text = content.isEmpty ? " " : content
        let color = ctx.color

        // Wide code scrolls horizontally instead of wrapping.
        if let available = options.availableWidth {
            let natural = naturalCodeWidth(text, font: font) + style.codePadding * 2
            lastInfo.widthThresholds.append(natural + ctx.indent)
            if natural > available - ctx.indent {
                let ps = NSMutableParagraphStyle()
                ps.lineHeightMultiple = 1.12
                ps.lineBreakMode = .byClipping
                let code = highlightedCode(info, text, font: font, color: color, paragraphStyle: ps)
                let size = ScrollableBlockCell.measure(code, width: natural)
                let cell = ScrollableBlockCell(content: code, contentSize: size,
                                               padding: NSEdgeInsets(top: style.codePadding, left: style.codePadding,
                                                                     bottom: style.codePadding, right: style.codePadding),
                                               fillColor: RenderColors.codeBackground, cornerRadius: 6)
                appendAttachmentParagraph(cell, ctx, out)
                return
            }
        }

        let block = newBlock(.code, indent: ctx.indent, depth: ctx.blocks.count, out)
        var c = ctx
        c.indent = 0
        let ps = paragraphStyle(c, after: 0, lineHeight: 1.12, extraBlocks: [block])
        ps.lineBreakMode = .byCharWrapping
        out.append(highlightedCode(info, text + "\n", font: font, color: color, paragraphStyle: ps))
    }

    /// Width of the longest line, fast for monospaced ASCII.
    private func naturalCodeWidth(_ text: String, font: NSFont) -> CGFloat {
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        var widest: CGFloat = 0
        text.enumerateLines { line, _ in
            var width: CGFloat
            if line.utf8.allSatisfy({ $0 < 0x80 && $0 != 0x09 }) {
                width = CGFloat(line.utf8.count) * advance
            } else {
                let expanded = line.replacingOccurrences(of: "\t", with: "    ")
                width = (expanded as NSString).size(withAttributes: [.font: font]).width
            }
            widest = max(widest, width)
        }
        return ceil(widest) + 2
    }

    /// One paragraph holding a single attachment (scrollable block, diagram).
    private func appendAttachmentParagraph(_ cell: NSTextAttachmentCell, _ ctx: Context, _ out: NSMutableAttributedString,
                                           alignment: NSTextAlignment = .natural) {
        if let marker = ctx.marker { renderMarkerOnly(marker, ctx, out) }
        let attachment = NSTextAttachment()
        attachment.attachmentCell = cell
        let start = out.length
        out.append(NSAttributedString(attachment: attachment))
        out.append(NSAttributedString(string: "\n", attributes: [.font: fonts.font(size: style.fontSize)]))
        var c = ctx
        c.marker = nil
        let ps = paragraphStyle(c, alignment: alignment, lineHeight: 1)
        setParagraphStyle(ps, in: out, range: NSRange(location: start, length: out.length - start))
        out.addAttribute(.foregroundColor, value: ctx.color, range: NSRange(location: start, length: out.length - start))
    }

    // MARK: Math and diagrams

    private func renderDisplayMath(_ tex: String, _ ctx: Context, _ out: NSMutableAttributedString) {
        let box = MathRenderer.layout(tex, display: true, fontSize: style.fontSize * 1.05)
        let cell = MathAttachmentCell(box: box, color: ctx.color, display: true)
        let start = out.length
        appendAttachmentParagraph(cell, ctx, out, alignment: .center)
        out.addAttribute(.toolTip, value: tex, range: NSRange(location: start, length: 1))
    }

    private func renderMermaid(_ source: String, _ info: String, _ ctx: Context, _ out: NSMutableAttributedString) {
        if let diagram = MermaidRenderer.diagram(source, fontSize: style.fontSize) {
            appendAttachmentParagraph(MermaidAttachmentCell(diagram: diagram), ctx, out, alignment: .center)
            return
        }
        // Unsupported diagram type: show the source with a short note.
        var attrs = baseAttrs(ctx)
        attrs.size = (style.fontSize * 0.82).rounded()
        attrs.color = RenderColors.secondaryText
        attrs.italic = true
        let type = MermaidRenderer.diagramType(source)
        var c = ctx
        renderInlineParagraph([.text("Mermaid “\(type)” diagram (shown as source)")], c, out, attrs: attrs)
        setTrailingSpacing(out, from: out.length - 1, ctx: ctx, spacing: style.tightSpacing)
        c.marker = nil
        renderCode("", source, c, out)
    }

    // MARK: Quotes and lists

    private func renderQuote(_ children: [Block], _ ctx: Context, _ out: NSMutableAttributedString) {
        if let marker = ctx.marker {
            renderMarkerOnly(marker, ctx, out)
        }
        let block = newBlock(.quote, indent: ctx.indent, depth: ctx.blocks.count, out)
        var c = ctx
        c.blocks.append(block)
        c.indent = 0
        c.color = RenderColors.secondaryText
        c.marker = nil
        c.tight = false
        if children.isEmpty {
            out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: interned(paragraphStyle(c, after: 0))]))
        } else {
            renderBlocks(children, c, out)
        }
    }

    private static let bullets = ["•", "◦", "▪︎"]

    private func renderList(_ list: ListBlock, _ ctx: Context, _ out: NSMutableAttributedString) {
        let markerFont = NSFont.monospacedDigitSystemFont(ofSize: style.fontSize, weight: .regular)
        for (i, item) in list.items.enumerated() {
            var c = ctx
            c.indent = ctx.indent + style.listMarkerWidth
            c.tight = list.tight
            c.listDepth = ctx.listDepth + 1
            let marker: Marker
            if let checked = item.task {
                marker = Marker(text: checked ? "☑︎" : "☐", color: checked ? .controlAccentColor : RenderColors.secondaryText,
                                font: fonts.font(size: (style.fontSize * 1.1).rounded()),
                                taskLine: item.line >= 0 ? item.line - blockStartLine : nil)
            } else if list.ordered {
                marker = Marker(text: "\(list.start + i).", color: ctx.color == RenderColors.text ? RenderColors.secondaryText : ctx.color,
                                font: markerFont)
            } else {
                marker = Marker(text: Self.bullets[ctx.listDepth % Self.bullets.count],
                                color: RenderColors.secondaryText, font: markerFont)
            }
            c.marker = marker
            let itemStart = out.length
            switch item.blocks.first {
            case .paragraph?, .heading?:
                renderBlocks(item.blocks, c, out)
            case nil:
                renderMarkerOnly(marker, c, out)
            default:
                renderMarkerOnly(marker, c, out)
                var rest = c
                rest.marker = nil
                renderBlocks(item.blocks, rest, out)
            }
            if out.length > itemStart, i < list.items.count - 1 {
                setTrailingSpacing(out, from: itemStart, ctx: ctx, spacing: list.tight ? style.tightSpacing : style.paragraphSpacing)
            }
        }
    }

    private func renderMarkerOnly(_ marker: Marker, _ ctx: Context, _ out: NSMutableAttributedString) {
        var c = ctx
        c.marker = marker
        renderInlineParagraph([], c, out, attrs: baseAttrs(ctx))
        setTrailingSpacing(out, from: out.length - 1, ctx: ctx, spacing: 0)
    }

    private func renderDefinitionList(_ items: [DefinitionItem], _ ctx: Context, _ out: NSMutableAttributedString) {
        if let marker = ctx.marker { renderMarkerOnly(marker, ctx, out) }
        var c = ctx
        c.marker = nil
        for (i, item) in items.enumerated() {
            for (t, term) in item.terms.enumerated() {
                var attrs = baseAttrs(c)
                attrs.bold = true
                let start = out.length
                renderInlineParagraph(inlineParser.parse(term), c, out, attrs: attrs,
                                      before: i > 0 && t == 0 ? style.tightSpacing : 0)
                setTrailingSpacing(out, from: start, ctx: c, spacing: style.tightSpacing)
            }
            var d = c
            d.indent = c.indent + style.listMarkerWidth
            d.tight = true
            for (k, definition) in item.definitions.enumerated() {
                let start = out.length
                renderBlocks(definition, d, out)
                let isLast = i == items.count - 1 && k == item.definitions.count - 1
                if !isLast { setTrailingSpacing(out, from: start, ctx: c, spacing: style.tightSpacing) }
            }
        }
    }

    // MARK: Details

    private func renderDetails(_ summary: String, open: Bool, _ children: [Block], _ ctx: Context,
                               _ out: NSMutableAttributedString) {
        let id = "\(blockKey)-\(detailsOrdinal)"
        detailsOrdinal += 1
        let expanded = options.expandAllDetails || (options.detailsState[id] ?? open)
        var attrs = baseAttrs(ctx)
        attrs.weight = .semibold
        let inlines = summary.isEmpty ? [Inline.text("Details")] : inlineParser.parse(summary)
        let start = out.length
        renderInlineParagraph([.text(expanded ? "▾\u{2009}" : "▸\u{2009}")] + inlines, ctx, out, attrs: attrs)
        let summaryRange = NSRange(location: start, length: out.length - start - 1)
        if !options.expandAllDetails {
            out.addAttributes([.mdrDetailsToggle: id, .cursor: NSCursor.pointingHand,
                               .toolTip: expanded ? "Click to collapse" : "Click to expand"], range: summaryRange)
        }
        guard expanded, !children.isEmpty else { return }
        setTrailingSpacing(out, from: start, ctx: ctx, spacing: style.tightSpacing)
        var c = ctx
        c.marker = nil
        c.indent = ctx.indent + (style.fontSize * 1.1).rounded()
        renderBlocks(children, c, out)
    }

    // MARK: Footnotes

    private func renderFootnotes(_ definitions: [FootnoteDefinition], _ ctx: Context, _ out: NSMutableAttributedString) {
        renderRule(ctx, out)
        let small = (style.fontSize * 0.9).rounded()
        let markerFont = NSFont.monospacedDigitSystemFont(ofSize: small, weight: .regular)
        for definition in definitions {
            var c = ctx
            c.indent = ctx.indent + style.listMarkerWidth
            c.tight = true
            c.color = RenderColors.secondaryText
            c.marker = Marker(text: "\(definition.number).", color: RenderColors.secondaryText, font: markerFont)
            let start = out.length
            var blocks = definition.blocks
            // Backlink to the reference, appended to the last paragraph.
            let backlink = " [↩︎](#fnref-\(definition.label.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? definition.label))"
            if case .paragraph(let text)? = blocks.last {
                blocks[blocks.count - 1] = .paragraph(text: text + backlink)
            } else {
                blocks.append(.paragraph(text: backlink))
            }
            renderBlocks(blocks, c, out)
            if out.length > start {
                out.addAttribute(.mdrAnchor, value: "fn-\(definition.label)", range: NSRange(location: start, length: 1))
            }
            setTrailingSpacing(out, from: start, ctx: ctx, spacing: style.tightSpacing)
        }
    }

    // MARK: Tables

    private func renderTable(_ table: TableBlock, _ ctx: Context, _ out: NSMutableAttributedString) {
        let columns = table.alignments.count
        guard columns > 0 else { return }
        let padV = (style.fontSize * 0.35).rounded()
        let padH = (style.fontSize * 0.6).rounded()
        if let marker = ctx.marker { renderMarkerOnly(marker, ctx, out) }
        let allRows = [table.header] + table.rows
        let parsedRows = allRows.map { row in (0..<columns).map { inlineParser.parse($0 < row.count ? row[$0] : "") } }

        // Wide tables scroll horizontally: measure each column's natural width
        // (capped, so long prose still wraps inside a column).
        var fixedWidths: [CGFloat]?
        if let available = options.availableWidth {
            let cap = (style.fontSize * 26).rounded()
            var widths = [CGFloat](repeating: 0, count: columns)
            for (r, row) in parsedRows.enumerated() {
                for (col, inlines) in row.enumerated() {
                    var attrs = baseAttrs(ctx)
                    if r == 0 { attrs.bold = true }
                    let cell = NSMutableAttributedString()
                    var state = HTMLInlineState()
                    appendInlines(inlines, attrs, cell, &state)
                    widths[col] = max(widths[col], min(ceil(cell.size().width) + 2, cap))
                }
            }
            let natural = widths.reduce(0) { $0 + $1 + padH * 2 + 1 } + 1
            lastInfo.widthThresholds.append(natural + ctx.indent)
            if natural > available - ctx.indent { fixedWidths = widths }
        }

        let textTable = NSTextTable()
        textTable.numberOfColumns = columns
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false
        let tableOut = fixedWidths == nil ? out : NSMutableAttributedString()
        var c = ctx
        c.marker = nil
        if let fixedWidths {
            textTable.layoutAlgorithm = .fixedLayoutAlgorithm
            c.blocks = []
            c.indent = 0
            let total = fixedWidths.reduce(0) { $0 + $1 + padH * 2 + 1 } + 1
            textTable.setContentWidth(total, type: .absoluteValueType)
        } else {
            textTable.setWidth(ctx.indent, type: .absoluteValueType, for: .margin, edge: .minX)
            c.indent = 0
        }

        for (r, row) in parsedRows.enumerated() {
            for col in 0..<columns {
                let cell = NSTextTableBlock(table: textTable, startingRow: r, rowSpan: 1, startingColumn: col, columnSpan: 1)
                cell.setWidth(1, type: .absoluteValueType, for: .border)
                cell.setBorderColor(RenderColors.tableBorder)
                cell.setWidth(padV, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(padV, type: .absoluteValueType, for: .padding, edge: .maxY)
                cell.setWidth(padH, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(padH, type: .absoluteValueType, for: .padding, edge: .maxX)
                if let fixedWidths { cell.setContentWidth(fixedWidths[col], type: .absoluteValueType) }
                if r == 0 {
                    cell.backgroundColor = RenderColors.tableHeaderBackground
                } else if r % 2 == 0 {
                    cell.backgroundColor = RenderColors.tableStripeBackground
                }
                let alignment: NSTextAlignment
                switch table.alignments[col] {
                case .left: alignment = .left
                case .center: alignment = .center
                case .right: alignment = .right
                case .none: alignment = .natural
                }
                var attrs = baseAttrs(c)
                if r == 0 { attrs.bold = true }
                let start = tableOut.length
                var state = HTMLInlineState()
                appendInlines(row[col], attrs, tableOut, &state)
                tableOut.append(NSAttributedString(string: "\n", attributes: attributes(attrs)))
                let ps = paragraphStyle(c, after: 0, alignment: alignment, lineHeight: 1.12, extraBlocks: [cell])
                setParagraphStyle(ps, in: tableOut, range: NSRange(location: start, length: tableOut.length - start))
            }
        }
        if let fixedWidths {
            let total = fixedWidths.reduce(0) { $0 + $1 + padH * 2 + 1 } + 1
            let size = ScrollableBlockCell.measure(tableOut, width: total)
            let cell = ScrollableBlockCell(content: tableOut, contentSize: size,
                                           padding: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
                                           fillColor: nil, cornerRadius: 0)
            var attachmentContext = ctx
            attachmentContext.marker = nil
            appendAttachmentParagraph(cell, attachmentContext, out)
        }
    }

    private func renderRule(_ ctx: Context, _ out: NSMutableAttributedString) {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = HorizontalRuleCell(height: (style.fontSize * 0.8).rounded())
        let start = out.length
        out.append(NSAttributedString(attachment: attachment))
        out.append(NSAttributedString(string: "\n", attributes: [.font: fonts.font(size: style.fontSize)]))
        let ps = paragraphStyle(ctx, before: (style.fontSize * 0.3).rounded(), lineHeight: 1)
        setParagraphStyle(ps, in: out, range: NSRange(location: start, length: out.length - start))
    }

    // MARK: - Inlines

    /// Formatting applied by inline HTML tags (`<b>`, `<kbd>`, `<a href>`,
    /// `<span style>`, `<font>` …).
    private struct HTMLInlineState {
        var bold = 0, italic = 0, mono = 0, strike = 0, underline = 0, mark = 0, sup = 0, sub = 0, small = 0, big = 0
        var links: [String] = []
        /// Inline CSS of open elements, innermost last.
        var styles: [(name: String, style: CSSStyle)] = []
        /// `<a id>` / `<a name>` waiting for the next text.
        var pendingAnchor: String?

        func apply(to a: InlineAttrs) -> InlineAttrs {
            var r = a
            if bold > 0 { r.bold = true }
            if italic > 0 { r.italic = true }
            if mono > 0 { r.mono = true }
            if strike > 0 { r.strike = true }
            if underline > 0 { r.underline = true }
            if mark > 0 { r.highlight = true }
            if sup > 0 { r.baselineShift = 1 } else if sub > 0 { r.baselineShift = -1 }
            if small > 0 { r.size = (r.size * 0.85).rounded() }
            if big > 0 { r.size = (r.size * 1.2).rounded() }
            for (_, css) in styles {
                if let color = css.color { r.color = color }
                if let background = css.background { r.background = background }
                if let bold = css.bold { r.bold = bold }
                if let italic = css.italic { r.italic = italic }
                if let underline = css.underline { r.underline = underline }
                if let strike = css.strike { r.strike = strike }
                if let mono = css.mono { r.mono = mono }
                if let scale = css.fontScale { r.size = max((r.size * scale).rounded(), 6) }
                if let shift = css.verticalShift { r.baselineShift = shift }
                if css.uppercase == true { r.uppercase = true }
                if css.hidden { r.hidden = true }
            }
            if let link = links.last, r.link == nil, !link.isEmpty { r.link = link }
            return r
        }

        /// Returns true if the tag was recognized as a formatting tag.
        mutating func handle(_ name: String, closing: Bool, tag: String) -> Bool {
            let delta = closing ? -1 : 1
            func bump(_ v: inout Int) { v = max(0, v + delta) }
            var recognized = true
            switch name {
            case "b", "strong": bump(&bold)
            case "i", "em", "cite", "var", "dfn": bump(&italic)
            case "code", "kbd", "samp", "tt": bump(&mono)
            case "s", "del", "strike": bump(&strike)
            case "u", "ins": bump(&underline)
            case "mark": bump(&mark)
            case "sup": bump(&sup)
            case "sub": bump(&sub)
            case "small": bump(&small)
            case "big": bump(&big)
            case "a":
                if closing {
                    if !links.isEmpty { links.removeLast() }
                } else {
                    links.append(HTMLScanner.attribute("href", in: tag) ?? "")
                    if let anchor = HTMLScanner.attribute("id", in: tag) ?? HTMLScanner.attribute("name", in: tag) {
                        pendingAnchor = anchor
                    }
                }
            case "span", "font":
                break
            default:
                recognized = false
            }
            // Inline CSS on any element; `<font>` attributes.
            if closing {
                if let k = styles.lastIndex(where: { $0.name == name }) { styles.remove(at: k) }
            } else {
                var css = HTMLScanner.attribute("style", in: tag).map(CSSStyle.parse) ?? CSSStyle()
                if name == "font" {
                    let legacy = CSSStyle.fontTag(tag)
                    css.color = css.color ?? legacy.color
                    css.fontScale = css.fontScale ?? legacy.fontScale
                    css.mono = css.mono ?? legacy.mono
                }
                if !css.isEmpty, !tag.hasSuffix("/>") { styles.append((name, css)) }
                if let anchor = HTMLScanner.attribute("id", in: tag), name != "a", pendingAnchor == nil {
                    pendingAnchor = anchor
                }
            }
            return recognized || name == "span" || name == "font"
        }
    }

    private func appendText(_ s: String, _ attrs: InlineAttrs, _ out: NSMutableAttributedString, _ state: inout HTMLInlineState) {
        guard !attrs.hidden else { return }
        let start = out.length
        out.append(NSAttributedString(string: attrs.uppercase ? s.uppercased() : s, attributes: attributes(attrs)))
        if let anchor = state.pendingAnchor, out.length > start {
            out.addAttribute(.mdrAnchor, value: anchor, range: NSRange(location: start, length: 1))
            state.pendingAnchor = nil
        }
    }

    private func appendInlines(_ inlines: [Inline], _ attrs: InlineAttrs, _ out: NSMutableAttributedString,
                               _ state: inout HTMLInlineState) {
        for inline in inlines {
            let effective = state.apply(to: attrs)
            switch inline {
            case .text(let s):
                appendText(s, effective, out, &state)
            case .softBreak:
                appendText(" ", effective, out, &state)
            case .lineBreak:
                appendText("\u{2028}", effective, out, &state)
            case .code(let s):
                var a = effective
                a.mono = true
                appendText(s, a, out, &state)
            case .emphasis(let children):
                var a = attrs
                a.italic = true
                appendInlines(children, a, out, &state)
            case .strong(let children):
                var a = attrs
                a.bold = true
                appendInlines(children, a, out, &state)
            case .strikethrough(let children):
                var a = attrs
                a.strike = true
                appendInlines(children, a, out, &state)
            case .link(let destination, let title, let children):
                var a = attrs
                a.link = destination
                a.title = title
                appendInlines(children, a, out, &state)
            case .image(let source, let title, let alt):
                guard !effective.hidden else { continue }
                out.append(image(source: source, title: title, alt: alt.plainText, attrs: effective, width: nil))
            case .html(let tag):
                appendInlineHTML(tag, effective, out, &state)
            case .math(let tex, let display):
                guard !effective.hidden else { continue }
                let box = MathRenderer.layout(tex, display: display, fontSize: effective.size)
                let attachment = NSTextAttachment()
                attachment.attachmentCell = MathAttachmentCell(box: box, color: effective.color, display: display)
                let result = NSMutableAttributedString(attachment: attachment)
                var a = attributes(effective)
                a.removeValue(forKey: .backgroundColor)
                a[.toolTip] = tex
                result.addAttributes(a, range: NSRange(location: 0, length: result.length))
                out.append(result)
            case .footnoteReference(let label, let number):
                var a = effective
                a.baselineShift = 1
                a.link = "#fn-" + (label.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? label)
                a.title = "Footnote \(number)"
                let start = out.length
                appendText("\(number)", a, out, &state)
                if out.length > start {
                    out.addAttribute(.mdrAnchor, value: "fnref-\(label)", range: NSRange(location: start, length: 1))
                }
            }
        }
    }

    private func appendInlineHTML(_ tag: String, _ attrs: InlineAttrs, _ out: NSMutableAttributedString,
                                  _ state: inout HTMLInlineState) {
        guard tag.hasPrefix("<"), !tag.hasPrefix("<!"), !tag.hasPrefix("<?") else { return }
        let closing = tag.hasPrefix("</")
        let name = HTMLScanner.tagName(tag)
        if name == "br" {
            appendText("\u{2028}", attrs, out, &state)
            return
        }
        if name == "img", !closing {
            if let src = HTMLScanner.attribute("src", in: tag), !attrs.hidden {
                let alt = HTMLScanner.attribute("alt", in: tag) ?? ""
                out.append(image(source: src, title: HTMLScanner.attribute("title", in: tag), alt: alt,
                                 attrs: attrs, width: Self.htmlImageWidth(tag)))
            }
            return
        }
        _ = state.handle(name, closing: closing, tag: tag)
    }

    private static func htmlImageWidth(_ tag: String) -> CGFloat? {
        let raw = HTMLScanner.attribute("width", in: tag)
            ?? HTMLScanner.attribute("style", in: tag).flatMap { style -> String? in
                guard let r = style.range(of: "(?<![-a-z])width\\s*:\\s*[0-9.]+px", options: [.regularExpression, .caseInsensitive])
                else { return nil }
                return String(style[r].split(separator: ":").last ?? "")
            }
        return raw.flatMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "px "))) }.map { CGFloat($0) }
    }

    // MARK: - Images

    private func image(source: String, title: String?, alt: String, attrs: InlineAttrs, width: CGFloat?) -> NSAttributedString {
        let isRemote = LinkResolver.isRemote(source)
        var remoteLoading = false
        var picture = isRemote ? nil : loadImage(source)
        if isRemote, let url = LinkResolver.resolve(source, relativeTo: baseURL) {
            switch RemoteImageLoader.shared.state(for: url) {
            case .loaded(let image):
                picture = image
            case .loading:
                remoteLoading = true
                lastInfo.pendingImages.insert(url)
            case .idle where options.loadRemoteImages:
                RemoteImageLoader.shared.load(url)
                remoteLoading = true
                lastInfo.pendingImages.insert(url)
            default:
                break
            }
        }
        if let picture {
            let attachment = NSTextAttachment()
            attachment.attachmentCell = ImageAttachmentCell(image: picture, preferredWidth: width)
            let result = NSMutableAttributedString(attachment: attachment)
            var a = attributes(attrs)
            a.removeValue(forKey: .backgroundColor)
            a[.toolTip] = title ?? (alt.isEmpty ? source : alt)
            result.addAttributes(a, range: NSRange(location: 0, length: result.length))
            return result
        }
        let label = alt.isEmpty ? (source as NSString).lastPathComponent : alt
        var a = attrs
        a.color = RenderColors.secondaryText
        a.italic = true
        if a.link == nil, isRemote { a.link = source }
        if remoteLoading {
            a.title = "Loading image: \(source)"
        } else if isRemote {
            a.title = options.loadRemoteImages ? "Remote image could not be loaded: \(source)"
                : "Remote image not loaded (View ▸ Load Remote Images): \(source)"
        } else if FolderAccess.needsGrant(for: source, baseURL: baseURL) {
            a.title = "No permission to read this image. Use File ▸ Grant Folder Access…: \(source)"
        } else {
            a.title = "Image not found: \(source)"
        }
        return NSAttributedString(string: (isRemote ? (remoteLoading ? "⏳ " : "🖼 ") : "⚠︎ ") + label, attributes: attributes(a))
    }

    private func loadImage(_ source: String) -> NSImage? {
        if source.hasPrefix("data:") {
            guard let comma = source.firstIndex(of: ","), source[..<comma].hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(source[source.index(after: comma)...]),
                                  options: .ignoreUnknownCharacters) else { return nil }
            return NSImage(data: data)
        }
        guard let url = LinkResolver.resolve(source, relativeTo: baseURL), url.isFileURL else { return nil }
        return ImageCache.shared.image(at: url)
    }

    // MARK: - HTML blocks

    private static let htmlBlockTags: Set<String> = [
        "p", "div", "center", "section", "article", "header", "footer", "nav", "main", "aside", "figure",
        "figcaption", "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "blockquote",
        "details", "summary", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "address", "hr", "picture", "caption",
    ]
    private static let htmlSkipContentTags: Set<String> = ["script", "style", "template", "noscript", "iframe", "object", "svg",
                                                           "math", "head", "title", "select", "textarea", "button"]

    /// Renders an HTML block using a safe subset: text, line/paragraph
    /// structure, headings, alignment, lists, tables, inline CSS, emphasis,
    /// links and images.
    private func renderHTMLBlock(_ html: String, _ ctx: Context, _ out: NSMutableAttributedString, inCell: Bool = false) {
        let s = Array(html.utf8)
        var state = HTMLInlineState()
        var paragraph = NSMutableAttributedString()
        var alignments: [NSTextAlignment] = []
        var headingLevel: Int?
        var preDepth = 0
        var pendingSpace = false
        var listStack: [(ordered: Bool, counter: Int)] = []
        var quoteDepth = 0
        var c = ctx
        if let marker = ctx.marker {
            renderMarkerOnly(marker, ctx, out)
            c.marker = nil
        }
        let baseIndent = c.indent
        let produced = out.length

        func currentAttrs() -> InlineAttrs {
            var a = baseAttrs(c)
            if let level = headingLevel {
                a.size = style.headingSize(level)
                a.weight = level <= 2 ? .bold : .semibold
            }
            if preDepth > 0 { a.mono = true }
            if quoteDepth > 0 { a.color = RenderColors.secondaryText }
            return state.apply(to: a)
        }

        func flush() {
            let trimmed = paragraph.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && !paragraph.containsAttachments {
                paragraph = NSMutableAttributedString()
                return
            }
            let start = out.length
            out.append(paragraph)
            out.append(NSAttributedString(string: "\n", attributes: attributes(currentAttrs())))
            let indent = baseIndent + CGFloat(listStack.count + quoteDepth) * style.listMarkerWidth
            var pc = c
            pc.indent = indent
            let ps = paragraphStyle(pc, before: headingLevel.map { style.headingSpacingBefore($0) } ?? 0,
                                    after: inCell ? 0 : (listStack.isEmpty ? nil : style.tightSpacing),
                                    alignment: alignments.last ?? .natural)
            if paragraph.string.hasPrefix("\t") {
                ps.firstLineHeadIndent = indent - style.listMarkerWidth
                ps.tabStops = [NSTextTab(textAlignment: .right, location: indent - (style.fontSize * 0.45).rounded()),
                               NSTextTab(textAlignment: .left, location: indent)]
            }
            if paragraph.containsAttachments { ps.lineHeightMultiple = 1 }
            setParagraphStyle(ps, in: out, range: NSRange(location: start, length: out.length - start))
            paragraph = NSMutableAttributedString()
            pendingSpace = false
        }

        func append(_ text: String, _ attrs: InlineAttrs) {
            let target = NSMutableAttributedString()
            appendText(text, attrs, target, &state)
            paragraph.append(target)
        }

        func appendTextRun(_ text: String) {
            guard !text.isEmpty else { return }
            if preDepth > 0 {
                append(text.replacingOccurrences(of: "\n", with: "\u{2028}"), currentAttrs())
                return
            }
            var collapsed = ""
            for ch in text {
                if ch.isWhitespace {
                    pendingSpace = true
                } else {
                    if pendingSpace, paragraph.length > 0 || !collapsed.isEmpty { collapsed.append(" ") }
                    pendingSpace = false
                    collapsed.append(ch)
                }
            }
            if !collapsed.isEmpty { append(collapsed, currentAttrs()) }
        }

        var i = 0
        var textStart = 0
        while i < s.count {
            guard s[i] == Byte.lt, let (end, kind) = HTMLScanner.scan(s, i) else {
                i += 1
                continue
            }
            if textStart < i { appendTextRun(HTMLEntities.decodeAll(s[textStart..<i])) }
            let tag = MarkdownScan.string(s[i..<end])
            i = end
            textStart = end
            guard kind != .other else { continue } // comments, declarations
            let closing = kind == .close
            let name = HTMLScanner.tagName(tag)

            if !closing, Self.htmlSkipContentTags.contains(name) {
                i = Self.indexAfterClosingTag(name, in: s, from: i)
                textStart = i
                continue
            }
            if !closing, name == "table" {
                flush()
                let close = Self.matchingClose("table", in: s, from: i)
                var tc = c
                tc.indent = baseIndent + CGFloat(listStack.count + quoteDepth) * style.listMarkerWidth
                renderHTMLTable(MarkdownScan.string(s[i..<close.contentEnd]), tc, out)
                i = close.end
                textStart = i
                continue
            }
            switch name {
            case "br":
                append("\u{2028}", currentAttrs())
                pendingSpace = false
            case "hr":
                flush()
                renderRule(c, out)
            case "img":
                if !closing, let src = HTMLScanner.attribute("src", in: tag) {
                    if pendingSpace, paragraph.length > 0 { append(" ", currentAttrs()) }
                    pendingSpace = false
                    let attrs = currentAttrs()
                    if !attrs.hidden {
                        paragraph.append(image(source: src, title: HTMLScanner.attribute("title", in: tag),
                                               alt: HTMLScanner.attribute("alt", in: tag) ?? "", attrs: attrs,
                                               width: Self.htmlImageWidth(tag)))
                    }
                }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                headingLevel = closing ? nil : Int(String(name.dropFirst()))
                if !closing {
                    pushAlignment(tag, &alignments)
                    if let id = HTMLScanner.attribute("id", in: tag) { state.pendingAnchor = id }
                } else if !alignments.isEmpty {
                    alignments.removeLast()
                }
                _ = state.handle(name, closing: closing, tag: tag)
            case "pre":
                flush()
                preDepth = max(0, preDepth + (closing ? -1 : 1))
            case "ul", "ol":
                flush()
                if closing {
                    if !listStack.isEmpty { listStack.removeLast() }
                } else {
                    let start = HTMLScanner.attribute("start", in: tag).flatMap { Int($0) } ?? 1
                    listStack.append((name == "ol", start))
                }
            case "li":
                flush()
                if !closing {
                    let depth = max(listStack.count - 1, 0)
                    var marker = Self.bullets[depth % Self.bullets.count]
                    if let top = listStack.last, top.ordered {
                        marker = "\(top.counter)."
                        listStack[listStack.count - 1].counter += 1
                    }
                    var attrs = currentAttrs()
                    attrs.color = RenderColors.secondaryText
                    if listStack.isEmpty { listStack.append((false, 1)) }
                    append("\t\(marker)\t", attrs)
                }
            case "blockquote":
                flush()
                quoteDepth = max(0, quoteDepth + (closing ? -1 : 1))
            case "dt":
                flush()
                _ = state.handle("b", closing: closing, tag: tag)
            case "dd":
                flush()
                quoteDepth = max(0, quoteDepth + (closing ? -1 : 1))
            default:
                if Self.htmlBlockTags.contains(name) {
                    flush()
                    if ["p", "div", "center", "section", "header", "footer", "figure", "article", "main", "aside",
                        "nav", "figcaption", "caption", "address", "summary"].contains(name) {
                        if closing {
                            if !alignments.isEmpty { alignments.removeLast() }
                        } else if name == "center" {
                            alignments.append(.center)
                        } else {
                            pushAlignment(tag, &alignments)
                        }
                    }
                    _ = state.handle(name, closing: closing, tag: tag)
                    if name == "summary" { _ = state.handle("b", closing: closing, tag: tag) }
                } else {
                    _ = state.handle(name, closing: closing, tag: tag)
                }
            }
        }
        if textStart < s.count { appendTextRun(HTMLEntities.decodeAll(s[textStart..<s.count])) }
        flush()
        // A table cell must contain at least one paragraph.
        if inCell, out.length == produced {
            out.append(NSAttributedString(string: "\n", attributes: [.font: fonts.font(size: style.fontSize),
                                                                    .paragraphStyle: interned(paragraphStyle(c, after: 0))]))
        }
    }

    /// Renders `<table>…</table>` as an `NSTextTable` (rows, header cells,
    /// `colspan`/`rowspan`, `align`).
    private func renderHTMLTable(_ html: String, _ ctx: Context, _ out: NSMutableAttributedString) {
        struct Cell {
            var html: String
            var header: Bool
            var colspan: Int
            var rowspan: Int
            var alignment: NSTextAlignment
        }
        let s = Array(html.utf8)
        var rows: [[Cell]] = []
        var current: [Cell]?
        var i = 0
        var caption: String?
        while i < s.count {
            guard s[i] == Byte.lt, let (end, kind) = HTMLScanner.scan(s, i) else { i += 1; continue }
            let tag = MarkdownScan.string(s[i..<end])
            let name = HTMLScanner.tagName(tag)
            i = end
            guard kind == .open else {
                if kind == .close, name == "tr", let row = current { rows.append(row); current = nil }
                continue
            }
            switch name {
            case "tr":
                if let row = current { rows.append(row) }
                current = []
            case "td", "th":
                let close = Self.matchingCellEnd(in: s, from: i)
                let alignment: NSTextAlignment
                switch (HTMLScanner.attribute("align", in: tag)
                        ?? HTMLScanner.attribute("style", in: tag).flatMap { CSSStyle.parse($0).alignment.map { a -> String in
                            a == .center ? "center" : a == .right ? "right" : "left" } })?.lowercased() {
                case "center": alignment = .center
                case "right": alignment = .right
                case "left": alignment = .left
                default: alignment = .natural
                }
                let cell = Cell(html: MarkdownScan.string(s[i..<close.contentEnd]), header: name == "th",
                                colspan: max(1, Int(HTMLScanner.attribute("colspan", in: tag) ?? "") ?? 1),
                                rowspan: max(1, Int(HTMLScanner.attribute("rowspan", in: tag) ?? "") ?? 1),
                                alignment: alignment)
                if current == nil { current = [] }
                current?.append(cell)
                i = close.end
            case "caption":
                let close = Self.matchingClose("caption", in: s, from: i)
                caption = MarkdownScan.string(s[i..<close.contentEnd])
                i = close.end
            case "table":
                // Nested table: render its text inside the current cell's flow.
                let close = Self.matchingClose("table", in: s, from: i)
                i = close.end
            default:
                break
            }
        }
        if let row = current { rows.append(row) }
        guard !rows.isEmpty else { return }

        if let caption {
            var attrs = baseAttrs(ctx)
            attrs.italic = true
            attrs.color = RenderColors.secondaryText
            renderInlineParagraph([.text(HTMLEntities.decodeAll(Array(caption.utf8)[...])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))], ctx, out, attrs: attrs)
            setTrailingSpacing(out, from: out.length - 1, ctx: ctx, spacing: style.tightSpacing)
        }

        // Grid placement honoring rowspan / colspan.
        var occupied: [[Bool]] = []
        var placements: [(cell: Cell, row: Int, col: Int)] = []
        for (r, row) in rows.enumerated() {
            while occupied.count <= r { occupied.append([]) }
            var col = 0
            for cell in row {
                while col < occupied[r].count, occupied[r][col] { col += 1 }
                placements.append((cell, r, col))
                for dr in 0..<cell.rowspan {
                    while occupied.count <= r + dr { occupied.append([]) }
                    for dc in 0..<cell.colspan {
                        while occupied[r + dr].count <= col + dc { occupied[r + dr].append(false) }
                        occupied[r + dr][col + dc] = true
                    }
                }
                col += cell.colspan
            }
        }
        let columns = max(occupied.map(\.count).max() ?? 1, 1)
        let textTable = NSTextTable()
        textTable.numberOfColumns = columns
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false
        textTable.setWidth(ctx.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        let padV = (style.fontSize * 0.35).rounded()
        let padH = (style.fontSize * 0.6).rounded()
        for placement in placements {
            let block = NSTextTableBlock(table: textTable, startingRow: placement.row, rowSpan: placement.cell.rowspan,
                                         startingColumn: placement.col, columnSpan: placement.cell.colspan)
            block.setWidth(1, type: .absoluteValueType, for: .border)
            block.setBorderColor(RenderColors.tableBorder)
            block.setWidth(padV, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(padV, type: .absoluteValueType, for: .padding, edge: .maxY)
            block.setWidth(padH, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(padH, type: .absoluteValueType, for: .padding, edge: .maxX)
            if placement.cell.header { block.backgroundColor = RenderColors.tableHeaderBackground }
            var c = ctx
            c.blocks = ctx.blocks + [block]
            c.indent = 0
            c.marker = nil
            let start = out.length
            let cellHTML = placement.cell.header ? "<b>\(placement.cell.html)</b>" : placement.cell.html
            renderHTMLBlock(cellHTML, c, out, inCell: true)
            if placement.cell.alignment != .natural {
                out.enumerateAttribute(.paragraphStyle, in: NSRange(location: start, length: out.length - start)) { value, range, _ in
                    guard let ps = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                    ps.alignment = placement.cell.alignment
                    setParagraphStyle(ps, in: out, range: range)
                }
            }
        }
    }

    private static func indexAfterClosingTag(_ name: String, in s: [UInt8], from i: Int) -> Int {
        let close = matchingClose(name, in: s, from: i)
        return close.end
    }

    /// Finds the `</name>` matching an already consumed `<name …>` at `from`.
    private static func matchingClose(_ name: String, in s: [UInt8], from: Int) -> (contentEnd: Int, end: Int) {
        var depth = 1
        var j = from
        while j < s.count {
            if s[j] == Byte.lt, let (end, kind) = HTMLScanner.scan(s, j) {
                let tagName = HTMLScanner.tagName(MarkdownScan.string(s[j..<end]))
                if tagName == name {
                    if kind == .open { depth += 1 }
                    if kind == .close {
                        depth -= 1
                        if depth == 0 { return (j, end) }
                    }
                }
                j = end
            } else {
                j += 1
            }
        }
        return (s.count, s.count)
    }

    /// End of a `<td>`/`<th>`: its closing tag, or the next cell/row (HTML
    /// allows omitting `</td>`).
    private static func matchingCellEnd(in s: [UInt8], from: Int) -> (contentEnd: Int, end: Int) {
        var depth = 0
        var j = from
        while j < s.count {
            if s[j] == Byte.lt, let (end, kind) = HTMLScanner.scan(s, j) {
                let name = HTMLScanner.tagName(MarkdownScan.string(s[j..<end]))
                if name == "table" { depth += kind == .open ? 1 : -1 }
                if depth <= 0 {
                    if kind == .close, name == "td" || name == "th" { return (j, end) }
                    if kind == .open, name == "td" || name == "th" || name == "tr" { return (j, j) }
                    if kind == .close, name == "tr" || name == "table" || name == "tbody" || name == "thead" { return (j, j) }
                }
                j = end
            } else {
                j += 1
            }
        }
        return (s.count, s.count)
    }

    private func pushAlignment(_ tag: String, _ alignments: inout [NSTextAlignment]) {
        let styleAlignment = HTMLScanner.attribute("style", in: tag).flatMap { CSSStyle.parse($0).alignment }
        switch HTMLScanner.attribute("align", in: tag)?.lowercased() {
        case "center": alignments.append(.center)
        case "right": alignments.append(.right)
        case "left": alignments.append(.left)
        case "justify": alignments.append(.justified)
        default: alignments.append(styleAlignment ?? alignments.last ?? .natural)
        }
    }
}

extension HTMLEntities {
    /// Decodes all entity references in a byte range (no backslash escapes).
    static func decodeAll(_ s: ArraySlice<UInt8>) -> String {
        guard s.contains(Byte.amp) else { return MarkdownScan.string(s) }
        var out = [UInt8]()
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == Byte.amp, let (decoded, next) = decode(s, at: i) {
                out.append(contentsOf: decoded.utf8)
                i = next
            } else {
                out.append(s[i])
                i += 1
            }
        }
        return MarkdownScan.string(out)
    }
}
