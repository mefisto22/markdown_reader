import AppKit
import XCTest
@testable import MarkdownReader

/// The reader's find client also searches the text of wide (horizontally
/// scrolling) code blocks and tables.
final class ReaderFindTests: XCTestCase {
    private var window: NSWindow!
    private var document: MarkdownDocument!
    private var preview: PreviewController!

    override func setUp() {
        super.setUp()
        let doc = MarkdownDocument()
        document = doc
        let wideLine = String(repeating: "x", count: 150) + " needle-wide"
        doc.replaceText("before needle-main\n\n```\n\(wideLine)\nshort\n```\n\nafter\n")
        preview = PreviewController(document: doc)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = preview.scrollView
        preview.textView.setFrameSize(NSSize(width: 500, height: 400))
        preview.isActive = true
        preview.update(immediately: true)
    }

    override func tearDown() {
        window.close()
        window = nil
        preview = nil
        document = nil
        super.tearDown()
    }

    private var client: PreviewFindClient { preview.textView.findClient }

    /// The virtual string the text finder searches.
    private func virtualString() -> String {
        var result = ""
        var index = 0
        while index < client.stringLength() {
            var range = NSRange()
            var boundary: ObjCBool = false
            result += client.string(at: index, effectiveRange: &range, endsWithSearchBoundary: &boundary)
            XCTAssertEqual(range.location, index)
            XCTAssertTrue(range.length > 0)
            index = NSMaxRange(range)
        }
        return result
    }

    private var attachmentIndex: Int {
        (preview.textView.string as NSString).range(of: "\u{FFFC}").location
    }

    func testWideBlockIsRenderedAsOverlayAttachment() {
        XCTAssertNotEqual(attachmentIndex, NSNotFound)
        XCTAssertFalse(preview.textView.string.contains("needle-wide"))
    }

    func testVirtualStringContainsWideBlockText() {
        let text = virtualString()
        XCTAssertEqual((text as NSString).length, client.stringLength())
        XCTAssertTrue(text.contains("needle-main"))
        XCTAssertTrue(text.contains("needle-wide"))
        XCTAssertTrue(text.contains("after"))
        XCTAssertFalse(text.contains("\u{FFFC}"))
    }

    func testSelectingAMatchInsideAWideBlock() {
        let range = (virtualString() as NSString).range(of: "needle-wide")
        client.selectedRanges = [NSValue(range: range)]
        XCTAssertEqual(preview.textView.selectedRange(), NSRange(location: attachmentIndex, length: 0))
        guard let overlay = preview.textView.overlayTextView(forAttachmentAt: attachmentIndex, create: false) else {
            return XCTFail("no overlay")
        }
        XCTAssertEqual((overlay.string as NSString).substring(with: overlay.selectedRange()), "needle-wide")
        XCTAssertEqual(client.firstSelectedRange, range)

        var effective = NSRange()
        XCTAssertTrue(client.contentView(at: range.location, effectiveCharacterRange: &effective) === overlay)
        XCTAssertTrue(NSLocationInRange(range.location, effective))
        let rects = client.rects(forCharacterRange: range) ?? []
        XCTAssertFalse(rects.isEmpty)

        // Scrolling to the match reveals it horizontally inside the block.
        client.scrollRangeToVisible(range)
        guard let rect = rects.first?.rectValue else { return }
        XCTAssertTrue(overlay.visibleRect.intersects(rect))
    }

    func testSelectingAMatchInTheReaderText() {
        let text = virtualString() as NSString
        let range = text.range(of: "needle-main")
        client.selectedRanges = [NSValue(range: range)]
        XCTAssertEqual((preview.textView.string as NSString).substring(with: preview.textView.selectedRange()), "needle-main")
        XCTAssertEqual(client.firstSelectedRange, range)

        // Text after the wide block maps back past the attachment character.
        let after = text.range(of: "after")
        client.selectedRanges = [NSValue(range: after)]
        XCTAssertEqual((preview.textView.string as NSString).substring(with: preview.textView.selectedRange()), "after")
        XCTAssertEqual(client.firstSelectedRange, after)
    }

    func testOverlayCreatedForFindMatchesTheDrawnFrame() {
        let index = attachmentIndex
        guard let frame = preview.textView.attachmentFrame(at: index),
              let overlay = preview.textView.overlayTextView(forAttachmentAt: index),
              let scrollView = overlay.enclosingScrollView else { return XCTFail("no overlay") }
        let placed = scrollView.frame
        // Drawing places the overlay through the attachment cell.
        let textView = preview.textView
        if let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) {
            textView.cacheDisplay(in: textView.bounds, to: rep)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(scrollView.frame, placed)
        XCTAssertTrue(frame.contains(placed))
        XCTAssertFalse(scrollView.isHidden)
    }

    func testFindCommandsGoToTheReader() {
        let index = attachmentIndex
        guard let overlay = preview.textView.overlayTextView(forAttachmentAt: index) else { return XCTFail("no overlay") }
        XCTAssertFalse(overlay.responds(to: #selector(NSResponder.performTextFinderAction(_:))))
        let item = NSMenuItem(title: "Find…", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        XCTAssertTrue(preview.textView.validateUserInterfaceItem(item))
    }

    func testEditingInvalidatesTheVirtualString() {
        XCTAssertTrue(virtualString().contains("needle-wide"))
        document.replaceText("plain text only\n")
        preview.update(immediately: true)
        XCTAssertEqual(virtualString(), preview.textView.string)
    }
}
