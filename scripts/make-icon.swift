// Renders the MacTalk app icon (blue rounded tile + walkie-talkie glyph) into an .iconset.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = s * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    NSGradient(colors: [NSColor(red: 0.30, green: 0.62, blue: 1, alpha: 1), NSColor(red: 0.12, green: 0.33, blue: 0.93, alpha: 1)])!
        .draw(in: path, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    // Sound waves + handset
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let glyph = NSImage(systemSymbolName: "flipphone", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let g = glyph.size
        glyph.draw(in: NSRect(x: (s - g.width) / 2 - s * 0.06, y: (s - g.height) / 2, width: g.width, height: g.height))
    }
    let waves = NSImage.SymbolConfiguration(pointSize: s * 0.2, weight: .bold).applying(.init(paletteColors: [.white.withAlphaComponent(0.85)]))
    if let w = NSImage(systemSymbolName: "wave.3.right", accessibilityDescription: nil)?.withSymbolConfiguration(waves) {
        w.draw(in: NSRect(x: s * 0.6, y: s * 0.52, width: w.size.width, height: w.size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
