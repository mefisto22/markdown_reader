import AppKit

extension NSAttributedString.Key {
    /// Block state after a line (see `SyntaxHighlighter.State`), stored on
    /// every character of the line so incremental highlighting knows whether
    /// a line is inside a code block.
    static let markdownFenceState = NSAttributedString.Key("MarkdownFenceState")
}

/// Markdown syntax highlighter for the source editor.
///
/// Block constructs (headings, quotes, lists, fenced and indented code) are
/// recognized line by line, carrying a small state from line to line.
/// Inline constructs (emphasis, code spans, links, …) are matched per
/// paragraph, so emphasis that spans several lines is colored too.
///
/// Edits are highlighted synchronously in the text storage's
/// `didProcessEditing` callback, from the start of the edited paragraph and
/// only until the line state converges again, so typing is O(edited
/// paragraph). Not `willProcessEditing`: attribute changes made there widen
/// the edited range, and the layout manager then moves the insertion point
/// to the end of that wider range (the cursor jumped lines down). Full-document passes (on open, after preference changes) run
/// in short time slices on the main thread so large files never block.
final class SyntaxHighlighter: NSObject, NSTextStorageDelegate {
    /// Line state: the open fence (character * 1000 + length) in the low
    /// bits, plus flags for indented code, paragraph text, list context and
    /// a preceding blank line.
    enum State {
        static let fenceMask = 0xFFFFF
        static let indentedCode = 1 << 20
        static let paragraph = 1 << 21
        static let list = 1 << 22
        static let afterBlank = 1 << 23
    }

    /// How a line takes part in inline highlighting.
    private enum LineKind {
        /// Blank, code or another line without inline content: ends a paragraph.
        case boundary
        /// A heading: a paragraph of its own.
        case heading
        /// Starts a new paragraph (list item).
        case start
        /// Continues the current paragraph.
        case text
    }

    private unowned let storage: NSTextStorage
    var isEnabled: Bool
    private(set) var baseFont: NSFont
    private var boldFont: NSFont
    private var italicFont: NSFont
    private var boldItalicFont: NSFont
    private var codeFont: NSFont
    private var baseAttributes: [NSAttributedString.Key: Any]

    /// Location of the next unhighlighted character of a running full pass.
    private var fullPassLocation: Int?
    private var fullPassScheduled = false

    private enum Colors {
        static let marker = NSColor.tertiaryLabelColor
        static let heading = NSColor.labelColor
        static let listMarker = NSColor.controlAccentColor
        static let code = NSColor.systemPink
        static let fencedCode = NSColor.secondaryLabelColor
        static let link = NSColor.linkColor
        static let url = NSColor.tertiaryLabelColor
        static let quote = NSColor.secondaryLabelColor
        static let html = NSColor.systemGray
        static let math = NSColor.systemTeal
    }

    private static func regex(_ pattern: String, multiline: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: multiline ? [.dotMatchesLineSeparators] : [])
    }

    private static let headingRegex = regex("^ {0,3}(#{1,6})(?=[ \\t]|$)")
    private static let quoteRegex = regex("^((?: {0,3}>[ \\t]?)+)")
    private static let listRegex = regex("^[ \\t]*([-*+]|\\d{1,9}[.)])(?=[ \\t])([ \\t]+\\[[ xX]\\](?=[ \\t]))?")
    private static let ruleRegex = regex("^ {0,3}(?:(?:\\*[ \\t]*){3,}|(?:-[ \\t]*){3,}|(?:_[ \\t]*){3,}|=+[ \\t]*)$")
    private static let codeSpanRegex = regex("(`+)(?!`)(.+?)(?<!`)\\1(?!`)", multiline: true)
    private static let boldRegex = regex("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1", multiline: true)
    private static let italicRegex = regex("(?<![*\\w\\\\])\\*(?![*\\s])(.+?)(?<![\\s*\\\\])\\*(?!\\*)|(?<![_\\w\\\\])_(?![_\\s])(.+?)(?<![\\s_\\\\])_(?![_\\w])", multiline: true)
    private static let strikeRegex = regex("~~(?=\\S)(.+?)(?<=\\S)~~", multiline: true)
    private static let mathRegex = regex("\\$\\$.+?\\$\\$|(?<![\\w$\\\\])\\$(?![\\s$])[^$\\n]*?(?<![\\s\\\\])\\$(?!\\d)", multiline: true)
    private static let linkRegex = regex("(!?\\[)([^\\]\\n]*)(\\]\\()([^)\\n]*)(\\))")
    private static let refLinkRegex = regex("(!?\\[)([^\\]\\n]+)(\\]\\[)([^\\]\\n]*)(\\])")
    private static let refDefRegex = regex("^ {0,3}\\[[^\\]]+\\]:[ \\t]*\\S.*$")
    private static let autolinkRegex = regex("<(?:[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\\s<>]*|[^\\s<>@]+@[^\\s<>@]+)>|(?<![\\w/])(?:https?://|www\\.)[^\\s<>]+[^\\s<>.,:;!?\"')\\]*_~]")
    private static let htmlRegex = regex("</?[A-Za-z][A-Za-z0-9-]*(?:\\s[^<>]*)?/?>|<!--.*?-->")

    init(storage: NSTextStorage) {
        self.storage = storage
        let prefs = Preferences.shared
        isEnabled = prefs.syntaxHighlighting
        baseFont = EditorStyle.font()
        boldFont = baseFont
        italicFont = baseFont
        boldItalicFont = baseFont
        codeFont = baseFont
        baseAttributes = [:]
        super.init()
        updateFonts()
    }

    /// Re-reads fonts from preferences. Call `rehighlightAll()` afterwards.
    func updateFonts() {
        let prefs = Preferences.shared
        baseFont = EditorStyle.font(size: prefs.editorFontSize, monospaced: prefs.editorMonospaced)
        let fm = NSFontManager.shared
        boldFont = fm.convert(baseFont, toHaveTrait: .boldFontMask)
        italicFont = fm.convert(baseFont, toHaveTrait: .italicFontMask)
        if italicFont == baseFont, let f = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic), size: baseFont.pointSize) {
            italicFont = f
        }
        boldItalicFont = fm.convert(italicFont, toHaveTrait: .boldFontMask)
        codeFont = prefs.editorMonospaced ? baseFont : NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.95, weight: .regular)
        baseAttributes = EditorStyle.baseAttributes(font: baseFont)
    }

    var typingAttributes: [NSAttributedString.Key: Any] { baseAttributes }

    // MARK: - NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        if let pass = fullPassLocation, editedRange.location < pass {
            fullPassLocation = max(editedRange.location, pass + delta)
        }
        if editedRange.length > 50_000 {
            // Bulk change (load, revert, large paste): highlight in the background.
            storage.setAttributes(baseAttributes, range: editedRange)
            startFullPass(from: lineStart(editedRange.location))
            return
        }
        guard isEnabled else {
            if editedRange.length > 0 { storage.setAttributes(baseAttributes, range: editedRange) }
            return
        }
        highlightIncrementally(from: editedRange)
    }

    // MARK: - Full passes

    /// Resets attributes and re-highlights the whole document in time slices.
    func rehighlightAll() {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)
        storage.endEditing()
        startFullPass(from: 0)
    }

    private func startFullPass(from location: Int) {
        guard isEnabled else { fullPassLocation = nil; return }
        fullPassLocation = min(fullPassLocation ?? location, location)
        scheduleFullPass()
    }

    private func scheduleFullPass() {
        guard !fullPassScheduled else { return }
        fullPassScheduled = true
        // A timer (not an immediate async block) lets the run loop draw between slices.
        DispatchQueue.main.asyncAfter(deadline: .now() + UserActivity.sliceDelay) { [weak self] in
            guard let self else { return }
            self.fullPassScheduled = false
            self.runFullPassSlice()
        }
    }

    private func runFullPassSlice() {
        guard isEnabled, let location = fullPassLocation else { return }
        let deadline = Date().addingTimeInterval(UserActivity.sliceBudget(idle: 0.012))
        storage.beginEditing()
        let end = highlightLines(from: unitStart(before: location), stopWhen: { _, _, atBoundary in
            atBoundary && Date() > deadline
        })
        storage.endEditing()
        if end < storage.length {
            fullPassLocation = end
            scheduleFullPass()
        } else {
            fullPassLocation = nil
        }
    }

    // MARK: - Incremental

    private func lineStart(_ location: Int) -> Int {
        let ns: NSString = storage.mutableString
        guard ns.length > 0 else { return 0 }
        return ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0)).location
    }

    private func stateBefore(_ lineStart: Int) -> Int {
        guard lineStart > 0, lineStart <= storage.length else { return State.afterBlank }
        return storage.attribute(.markdownFenceState, at: lineStart - 1, effectiveRange: nil) as? Int ?? 0
    }

    private func storedState(endingAt lineEnd: Int) -> Int? {
        guard lineEnd > 0, lineEnd <= storage.length else { return nil }
        return storage.attribute(.markdownFenceState, at: lineEnd - 1, effectiveRange: nil) as? Int
    }

    private func highlightIncrementally(from editedRange: NSRange) {
        let ns: NSString = storage.mutableString
        let length = ns.length
        guard length > 0 else { return }
        let start = min(editedRange.location, length)
        let edited = ns.lineRange(for: NSRange(location: start, length: min(editedRange.length, length - start)))
        let editEnd = NSMaxRange(edited)
        var extraLines = 0
        let end = highlightLines(from: unitStart(before: edited.location), stopWhen: { lineEnd, converged, atBoundary in
            guard lineEnd >= editEnd else { return false }
            // Past the edited lines, stop once the state matches what was
            // there before and the current paragraph has ended.
            if converged && atBoundary { return true }
            extraLines += 1
            return extraLines > 400
        })
        if end < length, extraLines > 400 {
            // A fence change affects a long stretch: finish in time slices.
            startFullPass(from: end)
        }
    }

    /// Start of the paragraph containing `location` (inline constructs can
    /// span its lines), looking back at most 200 lines.
    private func unitStart(before location: Int) -> Int {
        let ns: NSString = storage.mutableString
        var start = lineStart(location)
        var steps = 0
        while start > 0, steps < 200 {
            let previous = ns.lineRange(for: NSRange(location: start - 1, length: 0))
            let state = stateBefore(previous.location)
            guard state & State.fenceMask == 0 else { break }
            let text = ns.substring(with: previous).trimmingCharacters(in: .newlines)
            if text.trimmingCharacters(in: .whitespaces).isEmpty { break }
            let full = NSRange(location: 0, length: (text as NSString).length)
            if Self.headingRegex.firstMatch(in: text, range: full) != nil || SyntaxHighlighter.fenceInfo(text as NSString) != nil
                || Self.ruleRegex.firstMatch(in: text, range: full) != nil { break }
            start = previous.location
            if Self.listRegex.firstMatch(in: text, range: full) != nil { break }
            steps += 1
        }
        return start
    }

    /// Highlights lines from `start` until `stopWhen(lineEnd, converged,
    /// atParagraphBoundary)` returns true or the text ends; returns the
    /// location after the last highlighted line.
    private func highlightLines(from start: Int, stopWhen: (Int, Bool, Bool) -> Bool) -> Int {
        let ns: NSString = storage.mutableString
        let length = ns.length
        var location = start
        var state = stateBefore(start)
        var paragraphStart: Int?
        func flushParagraph(_ end: Int) {
            if let s = paragraphStart, end > s { highlightInline(NSRange(location: s, length: end - s), in: ns) }
            paragraphStart = nil
        }
        while location < length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let oldStateAfter = storedState(endingAt: NSMaxRange(line))
            let (newState, kind) = highlightLine(line, in: ns, stateBefore: state)
            state = newState
            switch kind {
            case .boundary:
                flushParagraph(line.location)
            case .heading:
                flushParagraph(line.location)
                highlightInline(line, in: ns)
            case .start:
                flushParagraph(line.location)
                paragraphStart = line.location
            case .text:
                if paragraphStart == nil { paragraphStart = line.location }
            }
            location = NSMaxRange(line)
            if stopWhen(location, oldStateAfter == state, paragraphStart == nil) { break }
        }
        flushParagraph(location)
        return location
    }

    // MARK: - Per-line highlighting

    private static func fenceInfo(_ line: NSString) -> (char: unichar, count: Int, indent: Int)? {
        var i = 0
        let n = line.length
        while i < n, i < 4, line.character(at: i) == 0x20 { i += 1 }
        guard i < 4, i < n else { return nil }
        let c = line.character(at: i)
        guard c == 0x60 || c == 0x7E else { return nil } // ` or ~
        var j = i
        while j < n, line.character(at: j) == c { j += 1 }
        guard j - i >= 3 else { return nil }
        return (c, j - i, i)
    }

    /// Indentation in columns (tabs to 4-column stops), or nil for a blank line.
    private static func indentation(_ line: NSString) -> Int? {
        var columns = 0
        for i in 0..<line.length {
            switch line.character(at: i) {
            case 0x20: columns += 1
            case 0x09: columns += 4 - columns % 4
            default: return columns
            }
        }
        return nil
    }

    /// Highlights one line's block structure and returns the state after it.
    private func highlightLine(_ range: NSRange, in ns: NSString, stateBefore: Int) -> (Int, LineKind) {
        guard range.length > 0 else { return (stateBefore, .boundary) }
        storage.setAttributes(baseAttributes, range: range)
        var contentRange = range
        // Exclude the line terminator from content.
        while contentRange.length > 0 {
            let c = ns.character(at: NSMaxRange(contentRange) - 1)
            if c == 0x0A || c == 0x0D { contentRange.length -= 1 } else { break }
        }
        let line = ns.substring(with: contentRange) as NSString
        let fence = stateBefore & State.fenceMask
        var stateAfter = 0
        var kind = LineKind.boundary

        if fence != 0 {
            let openChar = unichar(fence / 1000)
            let openCount = fence % 1000
            if let info = Self.fenceInfo(line), info.char == openChar, info.count >= openCount,
               line.substring(from: info.indent + info.count).trimmingCharacters(in: .whitespaces).isEmpty {
                apply([.foregroundColor: Colors.marker, .font: codeFont], contentRange)
            } else {
                apply([.foregroundColor: Colors.fencedCode, .font: codeFont], contentRange)
                stateAfter = fence
            }
            stateAfter |= stateBefore & State.list
        } else if let indent = Self.indentation(line) {
            let inList = stateBefore & State.list != 0
            let afterBlank = stateBefore & State.afterBlank != 0
            let continuesParagraph = stateBefore & State.paragraph != 0
            if indent >= 4, !continuesParagraph, !inList || (stateBefore & State.indentedCode != 0) {
                // Indented code block.
                apply([.foregroundColor: Colors.fencedCode, .font: codeFont], contentRange)
                stateAfter = State.indentedCode | (stateBefore & State.list)
            } else if let info = Self.fenceInfo(line),
                      !(info.char == 0x60 && line.substring(from: info.indent + info.count).contains("`")) {
                apply([.foregroundColor: Colors.marker, .font: codeFont], contentRange)
                stateAfter = Int(info.char) * 1000 + min(info.count, 999) | (stateBefore & State.list)
            } else {
                kind = highlightMarkdownLine(line, offset: contentRange.location)
                let isListItem = kind == .start
                // List context lasts through indented and lazy continuation lines.
                var list = isListItem || (inList && (indent > 0 || !afterBlank))
                if kind == .heading, indent == 0 { list = false }
                stateAfter = (kind == .text || kind == .start ? State.paragraph : 0) | (list ? State.list : 0)
            }
        } else {
            // Blank line: ends paragraphs, keeps indented code and list context.
            stateAfter = State.afterBlank | (stateBefore & (State.indentedCode | State.list))
        }
        storage.addAttribute(.markdownFenceState, value: stateAfter, range: range)
        return (stateAfter, kind)
    }

    private func apply(_ attrs: [NSAttributedString.Key: Any], _ range: NSRange) {
        guard range.length > 0 else { return }
        storage.addAttributes(attrs, range: range)
    }

    /// Block-level markup of a normal line (headings, quotes, list markers,
    /// rules, reference definitions).
    private func highlightMarkdownLine(_ line: NSString, offset: Int) -> LineKind {
        let full = NSRange(location: 0, length: line.length)
        func r(_ range: NSRange) -> NSRange { NSRange(location: range.location + offset, length: range.length) }
        let text = line as String

        if let m = Self.ruleRegex.firstMatch(in: text, range: full) {
            apply([.foregroundColor: Colors.marker], r(m.range))
            return .boundary
        }
        if let m = Self.refDefRegex.firstMatch(in: text, range: full) {
            apply([.foregroundColor: Colors.url], r(m.range))
            return .boundary
        }
        var contentStart = 0
        if let m = Self.quoteRegex.firstMatch(in: text, range: full) {
            apply([.foregroundColor: Colors.marker], r(m.range(at: 1)))
            apply([.foregroundColor: Colors.quote], r(NSRange(location: m.range.length, length: full.length - m.range.length)))
            contentStart = m.range.length
        }
        let rest = NSRange(location: contentStart, length: full.length - contentStart)
        if let m = Self.headingRegex.firstMatch(in: text, range: rest) {
            apply([.font: boldFont, .foregroundColor: Colors.heading],
                  r(NSRange(location: m.range.location, length: full.length - m.range.location)))
            apply([.foregroundColor: Colors.marker], r(m.range(at: 1)))
            return .heading
        }
        if let m = Self.listRegex.firstMatch(in: text, range: rest) {
            apply([.foregroundColor: Colors.listMarker], r(m.range(at: 1)))
            if m.range(at: 2).location != NSNotFound {
                apply([.foregroundColor: Colors.listMarker], r(m.range(at: 2)))
            }
            return .start
        }
        return .text
    }

    /// Inline markup of one paragraph (several lines without blank lines).
    private func highlightInline(_ range: NSRange, in ns: NSString) {
        guard range.length > 0 else { return }
        let paragraph = ns.substring(with: range) as NSString
        let full = NSRange(location: 0, length: paragraph.length)
        func r(_ sub: NSRange) -> NSRange { NSRange(location: sub.location + range.location, length: sub.length) }
        let text = paragraph as String

        // Inline constructs. Quick rejects keep plain prose cheap.
        var codeRanges: [NSRange] = []
        if paragraph.range(of: "`").location != NSNotFound {
            for m in Self.codeSpanRegex.matches(in: text, range: full) {
                codeRanges.append(m.range)
                apply([.foregroundColor: Colors.code, .font: codeFont], r(m.range))
            }
        }
        if paragraph.range(of: "$").location != NSNotFound {
            for m in Self.mathRegex.matches(in: text, range: full)
            where !codeRanges.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                codeRanges.append(m.range)
                apply([.foregroundColor: Colors.math, .font: codeFont], r(m.range))
            }
        }
        func outsideCode(_ range: NSRange) -> Bool {
            !codeRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }
        func isHeading(_ location: Int) -> Bool {
            let font = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
            return font == boldFont
        }
        let hasStar = paragraph.range(of: "*").location != NSNotFound
        let hasUnderscore = paragraph.range(of: "_").location != NSNotFound
        if hasStar || hasUnderscore {
            var boldRanges: [NSRange] = []
            for m in Self.boldRegex.matches(in: text, range: full) where outsideCode(m.range) {
                boldRanges.append(m.range)
                apply([.font: boldFont], r(m.range))
                let markerLength = m.range(at: 1).length
                apply([.foregroundColor: Colors.marker], r(NSRange(location: m.range.location, length: markerLength)))
                apply([.foregroundColor: Colors.marker], r(NSRange(location: NSMaxRange(m.range) - markerLength, length: markerLength)))
            }
            for m in Self.italicRegex.matches(in: text, range: full) where outsideCode(m.range) {
                let insideBold = boldRanges.contains { NSIntersectionRange($0, m.range).length == m.range.length }
                let heading = isHeading(r(m.range).location)
                apply([.font: (insideBold || heading) ? boldItalicFont : italicFont], r(m.range))
                apply([.foregroundColor: Colors.marker], r(NSRange(location: m.range.location, length: 1)))
                apply([.foregroundColor: Colors.marker], r(NSRange(location: NSMaxRange(m.range) - 1, length: 1)))
            }
        }
        if paragraph.range(of: "~~").location != NSNotFound {
            for m in Self.strikeRegex.matches(in: text, range: full) where outsideCode(m.range) {
                apply([.strikethroughStyle: NSUnderlineStyle.single.rawValue], r(m.range))
            }
        }
        if paragraph.range(of: "[").location != NSNotFound {
            for regex in [Self.linkRegex, Self.refLinkRegex] {
                for m in regex.matches(in: text, range: full) where outsideCode(m.range) {
                    apply([.foregroundColor: Colors.marker], r(m.range(at: 1)))
                    apply([.foregroundColor: Colors.link], r(m.range(at: 2)))
                    apply([.foregroundColor: Colors.marker], r(m.range(at: 3)))
                    apply([.foregroundColor: Colors.url], r(m.range(at: 4)))
                    apply([.foregroundColor: Colors.marker], r(m.range(at: 5)))
                }
            }
        }
        if paragraph.range(of: "<").location != NSNotFound {
            for m in Self.htmlRegex.matches(in: text, range: full) where outsideCode(m.range) {
                apply([.foregroundColor: Colors.html], r(m.range))
            }
        }
        if paragraph.range(of: "<").location != NSNotFound || paragraph.range(of: "://").location != NSNotFound
            || paragraph.range(of: "www.").location != NSNotFound {
            for m in Self.autolinkRegex.matches(in: text, range: full) where outsideCode(m.range) {
                apply([.foregroundColor: Colors.link], r(m.range))
            }
        }
    }

    /// True if the given character index lies inside a fenced code block.
    func isInsideFence(at index: Int) -> Bool {
        let start = lineStart(index)
        return stateBefore(start) & State.fenceMask != 0
    }
}
