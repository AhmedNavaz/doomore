// Regenerates FocusAssistant/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift
import AppKit

let dir = "FocusAssistant/Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.098
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor(red: 0.55, green: 0.13, blue: 0.16, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(red: 0.55, green: 0.13, blue: 0.16, alpha: 1),
               ending: NSColor(red: 0.86, green: 0.30, blue: 0.22, alpha: 1))!.draw(in: shape, angle: -45)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "iphone.slash", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceIn); return true
        }
        let w = tinted.size.width, h = tinted.size.height
        tinted.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)@\(scale)x.png"
        try! render(pt * scale).write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
        images.append("{\"idiom\":\"mac\",\"size\":\"\(pt)x\(pt)\",\"scale\":\"\(scale)x\",\"filename\":\"\(name)\"}")
    }
}
try! "{\"images\":[\(images.joined(separator: ","))],\"info\":{\"version\":1,\"author\":\"xcode\"}}"
    .write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
try! "{\"info\":{\"version\":1,\"author\":\"xcode\"}}"
    .write(toFile: "FocusAssistant/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)
