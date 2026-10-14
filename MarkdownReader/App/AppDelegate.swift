import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("willFinishLaunching")
        UserActivity.install()
        NSApp.mainMenu = MainMenu.build()
        applyAppearance()
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesDidChange),
                                               name: Preferences.didChangeNotification, object: nil)
        // Classic autosave to a separate location: protects unsaved edits
        // against crashes without writing to the user's file.
        NSDocumentController.shared.autosavingDelay = 20
        // Sandboxed build: re-open folders the user granted access to.
        FolderAccess.restoreBookmarks()
    }

    /// True when the app was launched to open documents (Finder double-click,
    /// drop on the Dock icon, `open file.md`) rather than plainly.
    private var launchedWithDocuments = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("didFinishLaunching")
        if let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool {
            launchedWithDocuments = !isDefault
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Called at launch (and on Dock-icon reopen) only when no document was
    /// opened or restored. A reader app shows the Open panel instead of an
    /// empty untitled document.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard !isRunningTests else { return false }
        // When launched from Finder the "open document" event can arrive after
        // this is asked, so never show the (modal) Open panel for a launch that
        // came with documents, and otherwise only if none got opened meanwhile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            let skip = launchedWithDocuments
            launchedWithDocuments = false   // later Dock reopens show the panel
            let controller = NSDocumentController.shared
            if !skip, controller.documents.isEmpty, NSApp.modalWindow == nil {
                controller.openDocument(nil)
            }
        }
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        for case let document as MarkdownDocument in NSDocumentController.shared.documents {
            document.checkForExternalChanges()
        }
    }

    // MARK: - Global view preferences (apply to every window)

    /// View ▸ Appearance. Diagnostics only: MDR_APPEARANCE=dark|light
    /// overrides it without touching the stored setting.
    private func applyAppearance() {
        let appearance: AppAppearance
        switch ProcessInfo.processInfo.environment["MDR_APPEARANCE"] {
        case "dark": appearance = .dark
        case "light": appearance = .light
        default: appearance = Preferences.shared.appearance
        }
        let target = appearance.nsAppearance
        if NSApp.appearance?.name != target?.name { NSApp.appearance = target }
    }

    @objc private func preferencesDidChange() {
        // Not from inside the menu action: AppKit crashed once in its scroller
        // appearance handling right after switching (not reproducible), so the
        // change is applied after the menu has closed and the event is done.
        DispatchQueue.main.async { [weak self] in self?.applyAppearance() }
    }

    @IBAction func setAppearance(_ sender: NSMenuItem) {
        if let appearance = AppAppearance(rawValue: sender.tag) { Preferences.shared.appearance = appearance }
    }

    @IBAction func toggleMonospacedEditor(_ sender: Any?) {
        Preferences.shared.editorMonospaced.toggle()
    }

    @IBAction func toggleSyntaxHighlighting(_ sender: Any?) {
        Preferences.shared.syntaxHighlighting.toggle()
    }

    @IBAction func toggleLineWrapping(_ sender: Any?) {
        Preferences.shared.wrapLines.toggle()
    }

    @IBAction func toggleSynchronizedScrolling(_ sender: Any?) {
        Preferences.shared.syncScrolling.toggle()
    }

    @IBAction func toggleRemoteImages(_ sender: Any?) {
        Preferences.shared.loadRemoteImages.toggle()
    }

    @IBAction func setReadingWidth(_ sender: NSMenuItem) {
        if let width = ReadingWidth(rawValue: sender.tag) { Preferences.shared.readingWidth = width }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let prefs = Preferences.shared
        switch menuItem.action {
        case #selector(toggleMonospacedEditor(_:)): menuItem.state = prefs.editorMonospaced ? .on : .off
        case #selector(toggleSyntaxHighlighting(_:)): menuItem.state = prefs.syntaxHighlighting ? .on : .off
        case #selector(toggleLineWrapping(_:)): menuItem.state = prefs.wrapLines ? .on : .off
        case #selector(toggleSynchronizedScrolling(_:)): menuItem.state = prefs.syncScrolling ? .on : .off
        case #selector(toggleRemoteImages(_:)): menuItem.state = prefs.loadRemoteImages ? .on : .off
        case #selector(setReadingWidth(_:)): menuItem.state = prefs.readingWidth.rawValue == menuItem.tag ? .on : .off
        case #selector(setAppearance(_:)): menuItem.state = prefs.appearance.rawValue == menuItem.tag ? .on : .off
        default: break
        }
        return true
    }
}
