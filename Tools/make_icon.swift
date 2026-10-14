// Renders the app icon PNGs into the asset catalog.
// Usage: swift Tools/make_icon.swift MarkdownReader/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    // macOS icon grid: 824pt body centered in 1024 canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor(calibratedRed: 0.99, green: 0.99, blue: 0.98, alpha: 1),
                        NSColor(calibratedRed: 0.90, green: 0.91, blue: 0.93, alpha: 1)])!
        .draw(in: body, angle: -90)
    // Faint text lines, like a page.
    NSColor(calibratedRed: 0.55, green: 0.60, blue: 0.68, alpha: 0.22).setFill()
    for i in 0..<3 {
        NSBezierPath(roundedRect: NSRect(x: 220, y: 235 + CGFloat(i) * 62, width: i == 2 ? 380 : 584, height: 26),
                     xRadius: 13, yRadius: 13).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // "M↓" mark.
    let ink = NSColor(calibratedRed: 0.13, green: 0.17, blue: 0.24, alpha: 1)
    let accent = NSColor(calibratedRed: 0.16, green: 0.47, blue: 0.96, alpha: 1)
    let m = NSAttributedString(string: "M", attributes: [
        .font: NSFont.systemFont(ofSize: 400, weight: .heavy), .foregroundColor: ink])
    let mSize = m.size()
    m.draw(at: NSPoint(x: 205, y: 470 - mSize.height / 2 + 70))

    let arrow = NSBezierPath()
    let ax: CGFloat = 705
    arrow.move(to: NSPoint(x: ax - 34, y: 760))
    arrow.line(to: NSPoint(x: ax + 34, y: 760))
    arrow.line(to: NSPoint(x: ax + 34, y: 560))
    arrow.line(to: NSPoint(x: ax + 105, y: 560))
    arrow.line(to: NSPoint(x: ax, y: 430))
    arrow.line(to: NSPoint(x: ax - 105, y: 560))
    arrow.line(to: NSPoint(x: ax - 34, y: 560))
    arrow.close()
    accent.setFill()
    arrow.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(points * scale).write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(outDir.path)")
