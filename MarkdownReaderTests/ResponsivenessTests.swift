import AppKit
import XCTest
@testable import MarkdownReader

/// Main-thread work in slices (reader rendering, editor highlighting) yields
/// to the user, and re-renders during rendering reuse the current parse.
final class ResponsivenessTests: XCTestCase {
    func testSlicesAreShortWhileTheUserInteracts() {
        UserActivity.noteInput()
        XCTAssertTrue(UserActivity.isInteracting)
        XCTAssertEqual(UserActivity.sliceBudget(idle: 0.035), 0.003, accuracy: 1e-9)
        XCTAssertEqual(UserActivity.sliceBudget(idle: 0.002), 0.002, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(UserActivity.sliceDelay, 0.008)

        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        XCTAssertFalse(UserActivity.isInteracting)
        XCTAssertEqual(UserActivity.sliceBudget(idle: 0.035), 0.035, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(UserActivity.sliceDelay, 0.002)
    }

    /// A width change while the document is still rendering (as when a
    /// window opens) re-renders from the same parse and matches a full render.
    func testWidthChangeDuringRenderingMatchesFullRender() {
        let wide = "```\n" + String(repeating: "w", count: 140) + "\n```\n\n"
        var text = ""
        for i in 0..<400 { text += "## Section \(i)\n\nParagraph with *emphasis* and `code` \(i).\n\n" + (i % 20 == 0 ? wide : "") }
        let doc = MarkdownDocument()
        doc.replaceText(text)
        let preview = PreviewController(document: doc)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2000, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = preview.scrollView
        preview.textView.setFrameSize(NSSize(width: 2000, height: 600))
        preview.isActive = true
        XCTAssertTrue(preview.isRendering, "the document should take more than one slice")

        // Narrow the column mid-render: wide code blocks switch to scrolling.
        preview.textView.setFrameSize(NSSize(width: 500, height: 600))
        let deadline = Date().addingTimeInterval(20)
        while preview.isRendering, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        // The width change is debounced; let it run and finish too.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        while preview.isRendering, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(preview.isRendering)

        let parsed = MarkdownParser.parse(doc.text)
        var options = RenderOptions()
        options.availableWidth = preview.textView.columnWidth
        let expected = MarkdownRenderer(style: RenderStyle(fontSize: Preferences.shared.readerFontSize), baseURL: nil,
                                        references: parsed.references, options: options).render(parsed)
        XCTAssertEqual(preview.textView.string, expected.string)
        XCTAssertEqual(preview.textView.string.filter { $0 == "\u{FFFC}" }.count, 20)
    }
}

final class AppearanceSettingTests: XCTestCase {
    func testAppearanceOptions() {
        XCTAssertNil(AppAppearance.system.nsAppearance)
        XCTAssertEqual(AppAppearance.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppAppearance.dark.nsAppearance?.name, .darkAqua)
        XCTAssertEqual(AppAppearance.allCases.map(\.rawValue), [0, 1, 2])
    }

    /// Smoke test: switching Dark → Match System → Light → Match System while
    /// the reader scrolls (overlay scrollers flash). It did not reproduce the
    /// one crash seen in the app, which happened inside AppKit.
    func testSwitchingAppearanceWhileScrolling() {
        let saved = NSApp.appearance
        defer { NSApp.appearance = saved }
        let doc = MarkdownDocument()
        doc.replaceText(String(repeating: "Line of text\n\n", count: 400))
        let preview = PreviewController(document: doc)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = preview.scrollView
        preview.isActive = true
        for option in [AppAppearance.dark, .system, .light, .system, .dark, .system] {
            NSApp.appearance = option.nsAppearance
            autoreleasepool {
                let clip = preview.scrollView.contentView
                clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 120))
                preview.scrollView.reflectScrolledClipView(clip)
                preview.scrollView.flashScrollers()
                window.displayIfNeeded()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            _ = preview.scrollView.verticalScroller?.effectiveAppearance.name
        }
    }

    func testReaderFollowsTheApplicationAppearance() {
        let saved = NSApp.appearance
        defer { NSApp.appearance = saved }
        let doc = MarkdownDocument()
        doc.replaceText("# Title\n\nText")
        let preview = PreviewController(document: doc)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = preview.scrollView
        for option in [AppAppearance.dark, .light] {
            NSApp.appearance = option.nsAppearance
            XCTAssertEqual(preview.textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
                           option == .dark ? .darkAqua : .aqua)
        }
    }

    func testAppearanceMenuIsInTheViewMenu() {
        let view = MainMenu.build().items.first { $0.submenu?.title == "View" }?.submenu
        let appearance = view?.items.first { $0.submenu?.title == "Appearance" }?.submenu
        XCTAssertEqual(appearance?.items.filter { !$0.isSeparatorItem }.map(\.title), ["Match System", "Light", "Dark"])
        XCTAssertEqual(appearance?.items.first?.action, #selector(AppDelegate.setAppearance(_:)))
    }
}
