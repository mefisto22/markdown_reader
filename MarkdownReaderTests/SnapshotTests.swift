import AppKit
import XCTest
@testable import MarkdownReader

/// Renders a document in an offscreen window and checks that the reader's
/// view hierarchy draws. Set MDR_SNAPSHOT_DIR to also write PNG snapshots
/// (light and dark) for visual inspection.
final class SnapshotTests: XCTestCase {
    private func snapshot(_ file: String, appearance: NSAppearance.Name, width: CGFloat = 820) throws -> NSBitmapImageRep {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Samples").appendingPathComponent(file)
        let doc = try MarkdownDocument(contentsOf: url, ofType: "net.daringfireball.markdown")
        let preview = PreviewController(document: doc)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = preview.scrollView
        preview.isActive = true
        let deadline = Date().addingTimeInterval(10)
        while (preview.isRendering || Date() < deadline - 9.5) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        // Let width-dependent re-rendering and remote images settle.
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let textView = preview.textView
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let height = min(textView.frame.height, 12_000)
        window.setContentSize(NSSize(width: width, height: height))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        textView.display()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let bounds = NSRect(x: 0, y: 0, width: textView.bounds.width, height: height)
        let rep = try XCTUnwrap(textView.bitmapImageRepForCachingDisplay(in: bounds))
        textView.cacheDisplay(in: bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["MDR_SNAPSHOT_DIR"] {
            let name = (file as NSString).deletingPathExtension + (appearance == .darkAqua ? "-dark" : "-light") + ".png"
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        return rep
    }

    func testExtensionsSampleRenders() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let rep = try snapshot("Extensions.md", appearance: appearance)
            XCTAssertGreaterThan(rep.pixelsHigh, 1000)
        }
    }
}
