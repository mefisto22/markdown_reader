import AppKit

/// Builds the main menu in code. Standard actions are sent to the first
/// responder, so AppKit, NSDocument and the text views handle them natively.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(formatMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        let help = NSMenu(title: "Help")
        main.addItem(submenu(help))
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                            _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        menu.addItem(item)
        return item
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Markdown Reader"
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: appName)
        add(menu, "About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        menu.addItem(submenu(services))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        add(menu, "Hide \(appName)", #selector(NSApplication.hide(_:)), "h")
        add(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(menu, "Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        add(menu, "New", #selector(NSDocumentController.newDocument(_:)), "n")
        add(menu, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
        let recent = NSMenu(title: "Open Recent")
        add(recent, "Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)))
        menu.addItem(submenu(recent))
        menu.addItem(.separator())
        add(menu, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(menu, "Save", #selector(NSDocument.save(_:)), "s")
        add(menu, "Save As…", #selector(NSDocument.saveAs(_:)), "S")
        add(menu, "Revert to Saved", #selector(NSDocument.revertToSaved(_:)))
        if FolderAccess.isSandboxed {
            menu.addItem(.separator())
            add(menu, "Grant Folder Access…", #selector(DocumentWindowController.grantFolderAccess(_:)))
        }
        menu.addItem(.separator())
        add(menu, "Export as PDF…", #selector(NSDocument.saveToPDF(_:)))
        add(menu, "Page Setup…", #selector(NSDocument.runPageLayout(_:)), "P")
        add(menu, "Print…", #selector(NSDocument.printDocument(_:)), "p")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        add(menu, "Undo", Selector(("undo:")), "z")
        add(menu, "Redo", Selector(("redo:")), "Z")
        menu.addItem(.separator())
        add(menu, "Cut", #selector(NSText.cut(_:)), "x")
        add(menu, "Copy", #selector(NSText.copy(_:)), "c")
        add(menu, "Paste", #selector(NSText.paste(_:)), "v")
        add(menu, "Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "V", [.command, .option])
        add(menu, "Delete", #selector(NSText.delete(_:)))
        add(menu, "Select All", #selector(NSText.selectAll(_:)), "a")
        menu.addItem(.separator())

        let find = NSMenu(title: "Find")
        let finder = #selector(NSResponder.performTextFinderAction(_:))
        add(find, "Find…", finder, "f", tag: NSTextFinder.Action.showFindInterface.rawValue)
        add(find, "Find and Replace…", finder, "f", [.command, .option], tag: NSTextFinder.Action.showReplaceInterface.rawValue)
        add(find, "Find Next", finder, "g", tag: NSTextFinder.Action.nextMatch.rawValue)
        add(find, "Find Previous", finder, "G", tag: NSTextFinder.Action.previousMatch.rawValue)
        add(find, "Use Selection for Find", finder, "e", tag: NSTextFinder.Action.setSearchString.rawValue)
        add(find, "Jump to Selection", #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j")
        menu.addItem(submenu(find))

        let spelling = NSMenu(title: "Spelling and Grammar")
        add(spelling, "Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":")
        add(spelling, "Check Document Now", #selector(NSText.checkSpelling(_:)), ";")
        spelling.addItem(.separator())
        add(spelling, "Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:)))
        menu.addItem(submenu(spelling))

        let substitutions = NSMenu(title: "Substitutions")
        add(substitutions, "Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)))
        add(substitutions, "Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:)))
        add(substitutions, "Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:)))
        menu.addItem(submenu(substitutions))
        return menu
    }

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        add(menu, "Bold", #selector(EditorTextView.toggleBold(_:)), "b")
        add(menu, "Italic", #selector(EditorTextView.toggleItalic(_:)), "i")
        add(menu, "Strikethrough", #selector(EditorTextView.toggleStrikethrough(_:)), "x", [.command, .shift])
        add(menu, "Inline Code", #selector(EditorTextView.toggleInlineCode(_:)), "k", [.command, .shift])
        add(menu, "Link", #selector(EditorTextView.insertMarkdownLink(_:)), "k")
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        add(menu, "Reader", #selector(DocumentWindowController.showReader(_:)), "1")
        add(menu, "Editor", #selector(DocumentWindowController.showEditor(_:)), "2")
        add(menu, "Split View", #selector(DocumentWindowController.showSplitView(_:)), "3")
        menu.addItem(.separator())
        add(menu, "Show Outline", #selector(DocumentWindowController.toggleSidebar(_:)), "s", [.command, .control])
        menu.addItem(.separator())
        add(menu, "Make Text Bigger", #selector(DocumentWindowController.makeTextLarger(_:)), "+")
        add(menu, "Make Text Smaller", #selector(DocumentWindowController.makeTextSmaller(_:)), "-")
        add(menu, "Actual Size", #selector(DocumentWindowController.makeTextStandardSize(_:)), "0")
        menu.addItem(.separator())

        let width = NSMenu(title: "Reading Width")
        for option in ReadingWidth.allCases {
            add(width, option.title, #selector(AppDelegate.setReadingWidth(_:)), tag: option.rawValue)
        }
        menu.addItem(submenu(width))
        let appearance = NSMenu(title: "Appearance")
        for option in AppAppearance.allCases {
            add(appearance, option.title, #selector(AppDelegate.setAppearance(_:)), tag: option.rawValue)
            if option == .system { appearance.addItem(.separator()) }
        }
        menu.addItem(submenu(appearance))
        add(menu, "Synchronize Scrolling in Split View", #selector(AppDelegate.toggleSynchronizedScrolling(_:)))
        add(menu, "Load Remote Images", #selector(AppDelegate.toggleRemoteImages(_:)))
        menu.addItem(.separator())
        add(menu, "Monospaced Editor Font", #selector(AppDelegate.toggleMonospacedEditor(_:)))
        add(menu, "Syntax Highlighting", #selector(AppDelegate.toggleSyntaxHighlighting(_:)))
        add(menu, "Wrap Lines", #selector(AppDelegate.toggleLineWrapping(_:)))
        menu.addItem(.separator())
        add(menu, "Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option])
        add(menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }
}
