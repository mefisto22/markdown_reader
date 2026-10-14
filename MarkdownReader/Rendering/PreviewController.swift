import AppKit

struct OutlineHeading: Identifiable, Hashable {
    let id: Int
    let level: Int
    let title: String
    let line: Int
    let blockIndex: Int
    let anchor: String
}

enum OutlineBuilder {
    static func headings(_ parsed: ParsedMarkdown) -> [OutlineHeading] {
        let parser = InlineParser(references: parsed.references)
        var result: [OutlineHeading] = []
        for (i, block) in parsed.blocks.enumerated() {
            guard case .heading(let level, let text) = block else { continue }
            let title = parser.parse(text).plainText.trimmingCharacters(in: .whitespaces)
            result.append(OutlineHeading(id: result.count, level: level, title: title.isEmpty ? "Untitled" : title,
                                         line: parsed.lineRanges[i].lowerBound, blockIndex: i,
                                         anchor: LinkResolver.anchor(for: title)))
        }
        return result
    }
}

/// Owns the reader view and keeps it in sync with the document text.
///
/// Rendering is incremental: each top-level block is identified by a hash of
/// its source; after an edit only the blocks between the unchanged prefix and
/// suffix are re-rendered and spliced into the text storage. Large documents
/// are rendered in short time slices so the first screen appears immediately
/// and the UI never blocks.
final class PreviewController: NSObject, NSTextViewDelegate {
    let textView: PreviewTextView
    let scrollView: NSScrollView
    private unowned let document: MarkdownDocument

    var onHeadingsChanged: (([OutlineHeading]) -> Void)?
    var onRenderProgress: (() -> Void)?

    /// When false (editor-only mode), text changes are only noted, not rendered.
    var isActive = false {
        didSet {
            if isActive, needsUpdate { update(immediately: true) }
        }
    }

    /// What a rendered block depends on besides its source; only blocks
    /// with wide content or loading images have one.
    private final class Dependencies {
        let info: BlockRenderInfo
        /// Column width the block was rendered for.
        let width: CGFloat?

        init(info: BlockRenderInfo, width: CGFloat?) {
            self.info = info
            self.width = width
        }
    }

    private struct Entry {
        var key: Int
        var length: Int
        var line: Int
        var end: Int
        var dependencies: Dependencies?

        var info: BlockRenderInfo { dependencies?.info ?? BlockRenderInfo() }
        var width: CGFloat? { dependencies?.width }

        init(key: Int, length: Int, line: Int, end: Int, dependencies: Dependencies? = nil) {
            self.key = key
            self.length = length
            self.line = line
            self.end = end
            self.dependencies = dependencies
        }

        init(key: Int, length: Int, line: Int, end: Int, info: BlockRenderInfo, width: CGFloat?) {
            let needed = !info.widthThresholds.isEmpty || !info.pendingImages.isEmpty
            self.init(key: key, length: length, line: line, end: end,
                      dependencies: needed ? Dependencies(info: info, width: width) : nil)
        }
    }

    /// Key that never matches a parsed block, forcing a re-render.
    private static let invalidKey = Int.min

    private final class Job {
        let parsed: ParsedMarkdown
        let renderer: MarkdownRenderer
        let keys: [Int]
        var next: Int
        let end: Int
        var entryIndex: Int
        var location: Int
        init(parsed: ParsedMarkdown, renderer: MarkdownRenderer, keys: [Int], next: Int, end: Int, entryIndex: Int, location: Int) {
            self.parsed = parsed
            self.renderer = renderer
            self.keys = keys
            self.next = next
            self.end = end
            self.entryIndex = entryIndex
            self.location = location
        }
    }

    private var entries: [Entry] = []
    private var entryOffsets: [Int]?
    private(set) var headings: [OutlineHeading] = []
    private var job: Job?
    private var needsUpdate = true
    private var generation = 0
    /// Counts edits of the document text.
    private var textVersion = 0
    /// The parse being rendered and the text version it belongs to; lets
    /// re-renders during rendering (e.g. the first width change) skip parsing.
    private var renderingParse: (parsed: ParsedMarkdown, version: Int)?
    private var pendingWork: DispatchWorkItem?
    private var style = RenderStyle(fontSize: Preferences.shared.readerFontSize)
    private var pendingAnchor: String?
    private(set) var isRendering = false
    /// `<details>` the user expanded or collapsed, by id.
    private var detailsState: [String: Bool] = [:]
    private var widthWork: DispatchWorkItem?
    private var imageWork: DispatchWorkItem?
    private var loadedImages: Set<URL> = []
    private var loadsRemoteImages = Preferences.shared.loadRemoteImages

    init(document: MarkdownDocument) {
        self.document = document
        textView = TextKit1.makeTextView(PreviewTextView.self)
        scrollView = TextKit1.makeScrollView(documentView: textView)
        super.init()

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        // Find is handled by PreviewTextView (it also searches wide blocks).
        textView.allowsUndo = false
        textView.delegate = self
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        textView.setAccessibilityLabel("Rendered Markdown")
        textView.overlayLinkDelegate = self
        textView.onColumnWidthChange = { [weak self] _ in self?.columnWidthDidChange() }
        textView.onTaskToggle = { [weak self] line, index in self?.toggleTask(relativeLine: line, at: index) }
        textView.onDetailsToggle = { [weak self] id, index in self?.toggleDetails(id, at: index) }
        applyPreferences()

        NotificationCenter.default.addObserver(self, selector: #selector(documentTextDidChange(_:)),
                                               name: NSTextStorage.didProcessEditingNotification,
                                               object: document.textStorage)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesDidChange),
                                               name: Preferences.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(remoteImageDidLoad(_:)),
                                               name: RemoteImageLoader.didLoadNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(folderAccessDidChange),
                                               name: FolderAccess.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollDidStart),
                                               name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollDidEnd),
                                               name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    @objc private func liveScrollDidStart() { textView.isLiveScrolling = true }
    @objc private func liveScrollDidEnd() { textView.isLiveScrolling = false }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pendingWork?.cancel()
        widthWork?.cancel()
        imageWork?.cancel()
    }

    private func applyPreferences() {
        let prefs = Preferences.shared
        textView.maxReadingWidth = prefs.readingWidth.maxWidth(fontSize: prefs.readerFontSize)
        let newStyle = RenderStyle(fontSize: prefs.readerFontSize)
        if newStyle != style || prefs.loadRemoteImages != loadsRemoteImages {
            if prefs.loadRemoteImages, !loadsRemoteImages { RemoteImageLoader.shared.resetFailures() }
            loadsRemoteImages = prefs.loadRemoteImages
            style = newStyle
            invalidateAll()
        }
    }

    @objc private func folderAccessDidChange() {
        invalidateAll()
    }

    // MARK: - Targeted re-rendering

    /// Marks entries for re-rendering; the next update renders them again.
    private func invalidateEntries(where predicate: (Entry) -> Bool) {
        var any = false
        for k in entries.indices where predicate(entries[k]) {
            entries[k].key = Self.invalidKey
            any = true
        }
        guard any else { return }
        needsUpdate = true
        if isActive { update(immediately: true) }
    }

    /// Wide blocks switch between wrapping and scrolling at their natural
    /// width; re-render those whose threshold was crossed.
    private func columnWidthDidChange() {
        widthWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let width = self.textView.columnWidth
            self.invalidateEntries { entry in
                guard let old = entry.width, !entry.info.widthThresholds.isEmpty else { return false }
                return entry.info.widthThresholds.contains { ($0 > old) != ($0 > width) }
            }
        }
        widthWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    @objc private func remoteImageDidLoad(_ note: Notification) {
        guard let url = note.object as? URL else { return }
        loadedImages.insert(url)
        imageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let urls = self.loadedImages
            self.loadedImages = []
            self.invalidateEntries { !$0.info.pendingImages.isDisjoint(with: urls) }
        }
        imageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func entryIndex(containing charIndex: Int) -> Int? {
        let offs = offsets()
        guard !entries.isEmpty, charIndex < offs[entries.count] else { return nil }
        var lo = 0, hi = entries.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if offs[mid] <= charIndex { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func toggleDetails(_ id: String, at charIndex: Int) {
        guard let index = entryIndex(containing: charIndex) else { return }
        let expanded = textView.textStorage.map { storage -> Bool in
            let range = (storage.string as NSString).paragraphRange(for: NSRange(location: charIndex, length: 0))
            return (storage.string as NSString).substring(with: range).hasPrefix("▾")
        } ?? false
        detailsState[id] = !expanded
        entries[index].key = Self.invalidKey
        needsUpdate = true
        update(immediately: true)
    }

    /// Toggles `[ ]` / `[x]` of the task item on `relativeLine` of the block
    /// containing `charIndex`, as an undoable edit of the document.
    private func toggleTask(relativeLine: Int, at charIndex: Int) {
        guard let index = entryIndex(containing: charIndex) else { return }
        let line = entries[index].line + relativeLine
        document.toggleTaskItem(atLine: line)
    }

    @objc private func preferencesDidChange() {
        applyPreferences()
    }

    @objc private func documentTextDidChange(_ note: Notification) {
        guard document.textStorage.editedMask.contains(.editedCharacters) else { return }
        textVersion += 1
        needsUpdate = true
        if isActive { update(immediately: false) }
    }

    /// Forces a complete re-render (font size or base URL changes).
    func invalidateAll() {
        job = nil
        entries = []
        entryOffsets = nil
        textView.textStorage?.setAttributedString(NSAttributedString())
        needsUpdate = true
        if isActive { update(immediately: true) }
    }

    private var lastBaseURL: URL?

    /// Schedules a render. Typing is debounced in proportion to document size.
    func update(immediately: Bool) {
        pendingWork?.cancel()
        let length = document.textStorage.length
        let delay: TimeInterval = immediately ? 0 : (length < 60_000 ? 0.06 : length < 600_000 ? 0.25 : 0.6)
        let work = DispatchWorkItem { [weak self] in self?.performUpdate() }
        pendingWork = work
        if delay == 0 {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func performUpdate() {
        pendingWork = nil
        guard needsUpdate else { return }
        needsUpdate = false
        if document.baseURL != lastBaseURL {
            lastBaseURL = document.baseURL
            if !entries.isEmpty {
                entries = []
                entryOffsets = nil
                job = nil
                textView.textStorage?.setAttributedString(NSAttributedString())
            }
        }
        generation += 1
        let gen = generation
        isRendering = true
        let version = textVersion
        if let renderingParse, renderingParse.version == version {
            apply(renderingParse.parsed, version: version)
            return
        }
        let text = String(document.textStorage.string)
        if text.utf8.count > 250_000 {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let parsed = MarkdownParser.parse(text)
                DispatchQueue.main.async {
                    guard let self, gen == self.generation else { return }
                    self.apply(parsed, version: version)
                }
            }
        } else {
            apply(MarkdownParser.parse(text), version: version)
        }
    }

    private func referencesFingerprint(_ refs: [String: LinkReference]) -> Int {
        guard !refs.isEmpty else { return 0 }
        var hasher = Hasher()
        for key in refs.keys.sorted() {
            hasher.combine(key)
            hasher.combine(refs[key]?.destination)
            hasher.combine(refs[key]?.title)
        }
        return hasher.finalize()
    }

    private func apply(_ parsed: ParsedMarkdown, version: Int) {
        guard let storage = textView.textStorage else { return }
        job = nil
        renderingParse = (parsed, version)
        var refs = referencesFingerprint(parsed.references)
        if !parsed.footnotes.isEmpty {
            var hasher = Hasher()
            hasher.combine(refs)
            for key in parsed.footnotes.keys.sorted() { hasher.combine(key); hasher.combine(parsed.footnotes[key]) }
            refs = hasher.finalize()
        }
        let keys = parsed.blockHashes.map { hash -> Int in
            var hasher = Hasher()
            hasher.combine(hash)
            hasher.combine(refs)
            return hasher.finalize()
        }

        // Diff against what is currently displayed.
        let old = entries
        var prefix = 0
        while prefix < old.count, prefix < keys.count, old[prefix].key == keys[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < keys.count - prefix,
              old[old.count - 1 - suffix].key == keys[keys.count - 1 - suffix] { suffix += 1 }

        let removeStart = old[..<prefix].reduce(0) { $0 + $1.length }
        let removeLength = old[prefix..<(old.count - suffix)].reduce(0) { $0 + $1.length }
        if removeLength > 0 {
            storage.beginEditing()
            storage.deleteCharacters(in: NSRange(location: removeStart, length: removeLength))
            storage.endEditing()
        }

        var kept: [Entry] = []
        kept.reserveCapacity(prefix + suffix)
        for i in 0..<prefix {
            kept.append(Entry(key: keys[i], length: old[i].length, line: parsed.lineRanges[i].lowerBound,
                              end: parsed.lineRanges[i].upperBound, dependencies: old[i].dependencies))
        }
        for k in 0..<suffix {
            let newIndex = keys.count - suffix + k
            let oldIndex = old.count - suffix + k
            kept.append(Entry(key: keys[newIndex], length: old[oldIndex].length,
                              line: parsed.lineRanges[newIndex].lowerBound, end: parsed.lineRanges[newIndex].upperBound,
                              dependencies: old[oldIndex].dependencies))
        }
        entries = kept
        entryOffsets = nil

        headings = OutlineBuilder.headings(parsed)
        onHeadingsChanged?(headings)

        var options = RenderOptions()
        // Before the view has its real width, render everything unscrolled;
        // the width change then re-renders only the blocks that overflow.
        options.availableWidth = textView.frame.width > 1 ? textView.columnWidth : .greatestFiniteMagnitude
        options.loadRemoteImages = loadsRemoteImages
        options.detailsState = detailsState
        let renderer = MarkdownRenderer(style: style, baseURL: document.baseURL, references: parsed.references,
                                        footnotes: parsed.footnotes, options: options)
        job = Job(parsed: parsed, renderer: renderer, keys: keys, next: prefix, end: keys.count - suffix,
                  entryIndex: prefix, location: removeStart)
        runJob()
    }

    private func runJob() {
        guard let job, let storage = textView.textStorage else { return }
        let deadline = Date().addingTimeInterval(UserActivity.sliceBudget(idle: 0.035))
        let pieces = NSMutableAttributedString()
        var newEntries: [Entry] = []
        while job.next < job.end, newEntries.isEmpty || Date() < deadline {
            let range = job.parsed.lineRanges[job.next]
            let rendered = autoreleasepool {
                job.renderer.render(job.parsed.blocks[job.next], key: job.keys[job.next], startLine: range.lowerBound)
            }
            pieces.append(rendered)
            newEntries.append(Entry(key: job.keys[job.next], length: rendered.length, line: range.lowerBound,
                                    end: range.upperBound, info: job.renderer.lastInfo,
                                    width: job.renderer.options.availableWidth))
            job.next += 1
        }
        if pieces.length > 0 {
            storage.beginEditing()
            storage.insert(pieces, at: job.location)
            storage.endEditing()
        }
        entries.insert(contentsOf: newEntries, at: job.entryIndex)
        entryOffsets = nil
        job.entryIndex += newEntries.count
        job.location += pieces.length

        if job.next < job.end {
            DispatchQueue.main.asyncAfter(deadline: .now() + UserActivity.sliceDelay) { [weak self] in
                guard let self, self.job === job else { return }
                self.runJob()
            }
        } else {
            self.job = nil
            renderingParse = nil
            isRendering = false
            if let anchor = pendingAnchor {
                pendingAnchor = nil
                scrollToAnchor(anchor)
            }
        }
        onRenderProgress?()
    }

    // MARK: - Position mapping (used for mode switches, outline and scroll sync)

    private func offsets() -> [Int] {
        if let entryOffsets { return entryOffsets }
        var result = [Int]()
        result.reserveCapacity(entries.count + 1)
        var total = 0
        for e in entries {
            result.append(total)
            total += e.length
        }
        result.append(total)
        entryOffsets = result
        return result
    }

    private func blockTop(_ index: Int) -> CGFloat {
        let offs = offsets()
        guard index < entries.count else {
            return textView.frame.height
        }
        return textView.lineTop(forCharacterAt: offs[index], precise: true)
    }

    /// Fractional source line shown at the top of the reader.
    func topSourceLine() -> Double {
        guard !entries.isEmpty else { return 0 }
        let char = textView.topVisibleCharacterIndex(in: scrollView)
        let offs = offsets()
        var lo = 0, hi = entries.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if offs[mid] <= char { lo = mid } else { hi = mid - 1 }
        }
        let top = blockTop(lo)
        let bottom = lo + 1 < entries.count ? blockTop(lo + 1) : textView.frame.height
        let visibleTop = scrollView.visibleDocumentTop
        let fraction = bottom > top ? Double(min(max((visibleTop - top) / (bottom - top), 0), 1)) : 0
        let startLine = entries[lo].line
        let endLine = entries[lo].end
        return Double(startLine) + fraction * Double(endLine - startLine)
    }

    /// Scrolls the reader so that the given fractional source line is at the top.
    func scrollToSourceLine(_ line: Double) {
        guard !entries.isEmpty else { return }
        var lo = 0, hi = entries.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Double(entries[mid].line) <= line { lo = mid } else { hi = mid - 1 }
        }
        let startLine = Double(entries[lo].line)
        let endLine = Double(entries[lo].end)
        let fraction = endLine > startLine ? min(max((line - startLine) / (endLine - startLine), 0), 1) : 0
        let top = blockTop(lo)
        let bottom = lo + 1 < entries.count ? blockTop(lo + 1) : top
        let y = line <= 0 ? 0 : top + CGFloat(fraction) * (bottom - top)
        scrollView.scrollDocument(toTop: y)
    }

    func scrollToHeading(_ heading: OutlineHeading) {
        guard heading.blockIndex < entries.count else { return }
        let y = blockTop(heading.blockIndex)
        scrollView.scrollDocument(toTop: max(y - 8, 0))
    }

    /// Scrolls to an in-document anchor: a heading (`#heading-name`), a
    /// footnote (`#fn-1`, `#fnref-1`) or an HTML `id`/`name`.
    func scrollToAnchor(_ anchor: String) {
        let target = anchor.lowercased()
        if let heading = headings.first(where: { $0.anchor == target }) {
            if heading.blockIndex < entries.count {
                scrollToHeading(heading)
            } else {
                pendingAnchor = anchor
            }
            return
        }
        guard let storage = textView.textStorage else { return }
        var found: Int?
        storage.enumerateAttribute(.mdrAnchor, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if let name = value as? String, name == anchor || name.lowercased() == target {
                found = range.location
                stop.pointee = true
            }
        }
        if let found {
            let y = textView.lineTop(forCharacterAt: found, precise: true)
            scrollView.scrollDocument(toTop: max(y - 8, 0))
            textView.showFindIndicator(for: (storage.string as NSString).lineRange(for: NSRange(location: found, length: 0)))
        } else if isRendering {
            pendingAnchor = anchor
        } else {
            NSSound.beep()
        }
    }

    // MARK: - Links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let destination: String
        if let s = link as? String {
            destination = s
        } else if let url = link as? URL {
            destination = url.absoluteString
        } else {
            return false
        }
        LinkOpener.open(destination, baseURL: document.baseURL, inDocumentAnchor: { [weak self] anchor in
            self?.scrollToAnchor(anchor)
        })
        return true
    }
}
