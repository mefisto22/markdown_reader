import AppKit
import XCTest
@testable import MarkdownReader

final class TextDecodingTests: XCTestCase {
    let hungarian = "Árvíztűrő tükörfúrógép – ŐŰ őű"

    func testUTF8RoundTrip() {
        let decoded = TextDecoding.decode(Data(hungarian.utf8))
        XCTAssertEqual(decoded, .init(text: hungarian, encoding: .utf8, hasBOM: false))
        let (data, used) = TextDecoding.encode(decoded.text, encoding: decoded.encoding, hasBOM: decoded.hasBOM)
        XCTAssertEqual(data, Data(hungarian.utf8))
        XCTAssertEqual(used, .utf8)
    }

    func testUTF8BOMIsPreserved() {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("# Cím".utf8)
        let decoded = TextDecoding.decode(original)
        XCTAssertEqual(decoded.text, "# Cím")
        XCTAssertTrue(decoded.hasBOM)
        XCTAssertEqual(TextDecoding.encode(decoded.text, encoding: decoded.encoding, hasBOM: true).0, original)
    }

    func testUTF16WithBOM() {
        let original = Data([0xFF, 0xFE]) + hungarian.data(using: .utf16LittleEndian)!
        let decoded = TextDecoding.decode(original)
        XCTAssertEqual(decoded.text, hungarian)
        XCTAssertEqual(TextDecoding.encode(decoded.text, encoding: decoded.encoding, hasBOM: decoded.hasBOM).0, original)
    }

    func testWindows1250HungarianFile() {
        let legacy = "Árvíztűrő tükörfúrógép".data(using: .windowsCP1250)!
        XCTAssertNil(String(data: legacy, encoding: .utf8))
        let decoded = TextDecoding.decode(legacy)
        XCTAssertEqual(decoded.text, "Árvíztűrő tükörfúrógép")
        XCTAssertEqual(TextDecoding.encode(decoded.text, encoding: decoded.encoding, hasBOM: false).0, legacy)
    }

    func testUnrepresentableCharactersFallBackToUTF8() {
        let (data, used) = TextDecoding.encode("emoji 👍", encoding: .isoLatin1, hasBOM: false)
        XCTAssertEqual(used, .utf8)
        XCTAssertEqual(String(data: data, encoding: .utf8), "emoji 👍")
    }
}

final class MarkdownDocumentTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MDTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let markdownType = "net.daringfireball.markdown"

    func testOpenEditSaveReopenPreservesContentAndLineEndings() throws {
        let url = directory.appendingPathComponent("jegyzet.md")
        let original = "# Cím\r\n\r\nÁrvíztűrő tükörfúrógép\r\n"
        try Data(original.utf8).write(to: url)

        let doc = try MarkdownDocument(contentsOf: url, ofType: markdownType)
        XCTAssertEqual(doc.text, original)
        XCTAssertFalse(doc.hasUnsavedChanges)

        doc.textStorage.replaceCharacters(in: NSRange(location: doc.textStorage.length, length: 0), with: "Új sor – őű\r\n")
        XCTAssertTrue(doc.hasUnsavedChanges)

        let saved = expectation(description: "saved")
        doc.save(to: url, ofType: markdownType, for: .saveOperation) { error in
            XCTAssertNil(error)
            saved.fulfill()
        }
        wait(for: [saved], timeout: 5)
        XCTAssertFalse(doc.hasUnsavedChanges)

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(onDisk, original + "Új sor – őű\r\n")

        let reopened = try MarkdownDocument(contentsOf: url, ofType: markdownType)
        XCTAssertEqual(reopened.text, onDisk)
    }

    func testLegacyEncodingIsWrittenBackUnchanged() throws {
        let url = directory.appendingPathComponent("legacy.md")
        let bytes = "Tükörfúrógép\n".data(using: .windowsCP1250)!
        try bytes.write(to: url)
        let doc = try MarkdownDocument(contentsOf: url, ofType: markdownType)
        XCTAssertEqual(doc.text, "Tükörfúrógép\n")
        XCTAssertEqual(try doc.data(ofType: markdownType), bytes)
    }

    func testRevertReloadsFromDiskAndClearsUndo() throws {
        let url = directory.appendingPathComponent("revert.md")
        try Data("első".utf8).write(to: url)
        let doc = try MarkdownDocument(contentsOf: url, ofType: markdownType)
        try Data("második".utf8).write(to: url)
        try doc.revert(toContentsOf: url, ofType: markdownType)
        XCTAssertEqual(doc.text, "második")
        XCTAssertFalse(doc.hasUnsavedChanges)
        XCTAssertFalse(doc.undoManager?.canUndo ?? false)
    }

    func testPrintOperationRendersDocument() throws {
        let url = directory.appendingPathComponent("print.md")
        try Data("# Nyomtatás\n\n| a | b |\n|---|---|\n| 1 | 2 |\n".utf8).write(to: url)
        let doc = try MarkdownDocument(contentsOf: url, ofType: markdownType)
        let operation = try doc.printOperation(withSettings: [:])
        let view = try XCTUnwrap(operation.view as? NSTextView)
        XCTAssertTrue(view.string.contains("Nyomtatás"))
        XCTAssertGreaterThan(view.frame.height, 20)
    }

    func testExportToPDFWritesAPDFFile() throws {
        let url = directory.appendingPathComponent("export.md")
        try Data("# PDF export\n\nÁrvíztűrő tükörfúrógép\n\n```\ncode\n```\n".utf8).write(to: url)
        let doc = try MarkdownDocument(contentsOf: url, ofType: markdownType)
        let pdfURL = directory.appendingPathComponent("export.pdf")
        let operation = try doc.printOperation(withSettings: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: pdfURL,
        ])
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        XCTAssertTrue(operation.run())
        let data = try Data(contentsOf: pdfURL)
        XCTAssertEqual(data.prefix(4), Data("%PDF".utf8))
    }
}

final class AppearanceTests: XCTestCase {
    private func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> CGFloat {
        var brightness: CGFloat = 0
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            brightness = color.usingColorSpace(.deviceRGB)!.brightnessComponent
        }
        return brightness
    }

    func testRenderColorsAdaptToDarkMode() {
        XCTAssertLessThan(resolved(RenderColors.text, .aqua), 0.3)
        XCTAssertGreaterThan(resolved(RenderColors.text, .darkAqua), 0.7)
        // Code background: darkens the page in light mode, lightens it in dark mode.
        var lightAlpha: CGFloat = 0, darkWhite: CGFloat = 0
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            lightAlpha = RenderColors.codeBackground.usingColorSpace(.deviceGray)!.whiteComponent
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            darkWhite = RenderColors.codeBackground.usingColorSpace(.deviceGray)!.whiteComponent
        }
        XCTAssertEqual(lightAlpha, 0, accuracy: 0.01)
        XCTAssertEqual(darkWhite, 1, accuracy: 0.01)
    }
}
