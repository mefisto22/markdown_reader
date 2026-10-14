import AppKit

/// A Markdown file. The document's single source of truth is `textStorage`;
/// the editor's text view edits it directly (no copies), and the preview
/// observes it.
///
/// Uses classic (non-autosave-in-place) document semantics: changes are
/// written to the file only on Save, closing an edited document asks the
/// user, and crash protection comes from AppKit's autosave-elsewhere drafts.
final class MarkdownDocument: NSDocument {
    let textStorage = NSTextStorage()
    private(set) var encoding: String.Encoding = .utf8
    private(set) var hasBOM = false

    /// View mode of this document's window; restored with window state.
    var viewMode: ViewMode = Preferences.shared.viewMode {
        didSet { if viewMode != oldValue { invalidateRestorableState() } }
    }

    private var lastHandledExternalChange: Date?
    /// Hash of the text as last read from or written to the file. Used in
    /// addition to `isDocumentEdited` so that no edit path (typing, services,
    /// accessibility, scripting) can be mistaken for "no local changes".
    private var diskTextHash: Int?
    private var isPresentingExternalChangeAlert = false
    /// True while an autosave draft is written: drafts never change the
    /// document's encoding.
    private var isWritingDraft = false

    static let encodingDidChangeNotification = Notification.Name("MarkdownDocumentEncodingDidChange")

    override init() {
        super.init()
    }

    /// Called for new, untitled documents. They start in the editor.
    convenience init(type typeName: String) throws {
        self.init()
        fileType = typeName
        viewMode = .editor
    }

    override class var autosavesInPlace: Bool { false }
    override class var preservesVersions: Bool { false }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }
    /// Keep the document's own file type on Save As (no format pop-up).
    override var shouldRunSavePanelWithAccessoryView: Bool { false }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController())
    }

    // MARK: - Reading and writing

    override func read(from data: Data, ofType typeName: String) throws {
        LaunchTrace.mark("read document")
        let decoded = TextDecoding.decode(data)
        encoding = decoded.encoding
        hasBOM = decoded.hasBOM
        replaceText(decoded.text)
        diskTextHash = decoded.text.hashValue
    }

    override func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                        originalContentsURL absoluteOriginalContentsURL: URL?) throws {
        let snapshot = textStorage.string
        try super.write(to: url, ofType: typeName, for: saveOperation, originalContentsURL: absoluteOriginalContentsURL)
        if saveOperation == .saveOperation || saveOperation == .saveAsOperation {
            diskTextHash = snapshot.hashValue
        }
    }

    /// True if the text differs from what is on disk (as far as we know).
    var hasUnsavedChanges: Bool {
        isDocumentEdited || textStorage.string.hashValue != diskTextHash
    }

    override func data(ofType typeName: String) throws -> Data {
        let (data, used) = TextDecoding.encode(textStorage.string, encoding: encoding, hasBOM: hasBOM)
        if used != encoding, !isWritingDraft {
            encoding = used
            NotificationCenter.default.post(name: Self.encodingDidChangeNotification, object: self)
        }
        return data
    }

    /// Asks before converting a legacy-encoded file to UTF-8 because it
    /// gained characters the encoding cannot represent (for example emoji).
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        let isDraft = saveOperation == .autosaveElsewhereOperation || saveOperation == .autosaveAsOperation
        let text = textStorage.string
        guard !isDraft, let sample = TextDecoding.firstUnencodableCharacter(in: text, encoding: encoding),
              let window = windowForSheet else {
            isWritingDraft = isDraft
            super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
                self?.isWritingDraft = false
                completionHandler(error)
            }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(displayName ?? "This document")” can’t be saved in \(TextDecoding.displayName(encoding))."
        alert.informativeText = "The text contains characters that \(TextDecoding.displayName(encoding)) cannot represent, such as “\(sample)”. Save the document as UTF-8, which can represent every character, or cancel and remove those characters."
        alert.addButton(withTitle: "Save as UTF-8")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                completionHandler(CocoaError(.userCancelled))
                return
            }
            self.convertToUTF8()
            self.saveWithoutEncodingCheck(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
        }
    }

    private func convertToUTF8() {
        encoding = .utf8
        hasBOM = false
        NotificationCenter.default.post(name: Self.encodingDidChangeNotification, object: self)
    }

    private func saveWithoutEncodingCheck(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                                          completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
    }

    /// Replaces the entire text without registering undo (used for loading
    /// and reverting).
    func replaceText(_ text: String) {
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length),
                                      with: NSAttributedString(string: text, attributes: EditorStyle.baseAttributes()))
        textStorage.endEditing()
        undoManager?.removeAllActions()
    }

    var text: String { textStorage.string }

    // MARK: - Edits from the reader

    /// Replaces source text as an undoable edit ("Undo Toggle Task").
    func replaceSourceText(in range: NSRange, with string: String, actionName: String) {
        guard NSMaxRange(range) <= textStorage.length else { return }
        let previous = textStorage.attributedSubstring(from: range).string
        let newRange = NSRange(location: range.location, length: (string as NSString).length)
        undoManager?.registerUndo(withTarget: self) { document in
            document.replaceSourceText(in: newRange, with: previous, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: range, with: string)
        textStorage.endEditing()
    }

    private static let taskItemRegex = try! NSRegularExpression(
        pattern: "^((?:[ \\t]*>[ \\t]?)*[ \\t]*(?:[-*+]|\\d{1,9}[.)])[ \\t]+)\\[([ xX])\\]")

    /// Toggles `[ ]` ⇄ `[x]` of the task list item on source line `line`.
    func toggleTaskItem(atLine line: Int) {
        let ns = textStorage.mutableString
        let index = LineIndex(ns)
        guard line >= 0, line < index.lineCount else { NSSound.beep(); return }
        let start = index.start(ofLine: line)
        let end = index.start(ofLine: line + 1)
        let lineText = ns.substring(with: NSRange(location: start, length: end - start))
        guard let match = Self.taskItemRegex.firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length))
        else { NSSound.beep(); return }
        let box = match.range(at: 2)
        let checked = (lineText as NSString).substring(with: box) != " "
        replaceSourceText(in: NSRange(location: start + box.location, length: 1), with: checked ? " " : "x",
                          actionName: checked ? "Uncheck Task" : "Check Task")
    }

    /// Directory used to resolve relative links and images.
    var baseURL: URL? { fileURL?.deletingLastPathComponent() }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        lastHandledExternalChange = nil
    }

    // MARK: - External modifications

    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in
            self?.checkForExternalChanges()
        }
    }

    /// Compares the file on disk with the last known state. Unedited
    /// documents reload silently; edited documents ask the user. Nothing is
    /// ever overwritten or discarded without a decision from the user, and
    /// NSDocument's own save-time check still guards against overwriting a
    /// newer file.
    func checkForExternalChanges() {
        guard !isPresentingExternalChangeAlert, let url = fileURL, let known = fileModificationDate,
              let type = fileType else { return }
        guard let current = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              current != known, current != lastHandledExternalChange else { return }

        var diskText: String?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: self).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            if let data = try? Data(contentsOf: readURL) { diskText = TextDecoding.decode(data).text }
        }
        guard let diskText else { return }
        if diskText == textStorage.string {
            // Touched but not changed (or changed back): nothing to do.
            lastHandledExternalChange = current
            fileModificationDate = current
            return
        }
        if !hasUnsavedChanges {
            do {
                try revert(toContentsOf: url, ofType: type)
            } catch {
                presentError(error)
            }
            return
        }
        guard let window = windowForSheet else { return }
        isPresentingExternalChangeAlert = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(displayName ?? "This document")” was changed by another application."
        alert.informativeText = "You have unsaved changes. Keep your version to continue editing (you will be warned again before saving over the newer file), or reload the version on disk and discard your changes."
        alert.addButton(withTitle: "Keep My Version")
        alert.addButton(withTitle: "Reload from Disk")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isPresentingExternalChangeAlert = false
            self.lastHandledExternalChange = current
            if response == .alertSecondButtonReturn {
                do {
                    try self.revert(toContentsOf: url, ofType: type)
                } catch {
                    self.presentError(error)
                }
            }
        }
    }

    // MARK: - State restoration

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        coder.encode(viewMode.rawValue as NSString, forKey: "ViewMode")
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        if let raw = coder.decodeObject(of: NSString.self, forKey: "ViewMode") as String?,
           let mode = ViewMode(rawValue: raw) {
            viewMode = mode
            for case let controller as DocumentWindowController in windowControllers {
                controller.setMode(mode, animated: false)
            }
        }
    }

    // MARK: - Printing and PDF export

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let info = (printInfo.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        info.dictionary().addEntries(from: printSettings)
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        info.leftMargin = 54
        info.rightMargin = 54
        info.topMargin = 54
        info.bottomMargin = 54

        let width = max(info.paperSize.width - info.leftMargin - info.rightMargin, 200)
        let parsed = MarkdownParser.parse(text)
        var options = RenderOptions()
        options.expandAllDetails = true
        let renderer = MarkdownRenderer(style: RenderStyle(fontSize: 11), baseURL: baseURL, references: parsed.references,
                                        footnotes: parsed.footnotes, options: options)
        let rendered = renderer.render(parsed)

        let view = TextKit1.makeTextView(width: width)
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = false
        view.isEditable = false
        view.textContainerInset = .zero
        view.textStorage?.setAttributedString(rendered)
        if let layoutManager = view.layoutManager, let container = view.textContainer {
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            view.setFrameSize(NSSize(width: width, height: ceil(used.height) + 4))
        }
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = displayName
        return operation
    }
}
