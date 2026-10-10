import AppKit

let output = CommandLine.arguments[1]
let sizes = [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x")]
for (size, name) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let s = CGFloat(size)
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.03, dy: s * 0.03), xRadius: s * 0.22, yRadius: s * 0.22)
    let gradient = NSGradient(starting: NSColor(red: 0.25, green: 0.40, blue: 0.49, alpha: 1), ending: NSColor(red: 0.09, green: 0.19, blue: 0.27, alpha: 1))!
    gradient.draw(in: path, angle: -75)
    let symbol = NSImage(systemSymbolName: "books.vertical.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: s * 0.53, weight: .medium))!
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus(); NSColor.white.set(); NSRect(origin: .zero, size: symbol.size).fill()
    symbol.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1); tinted.unlockFocus()
    tinted.draw(in: NSRect(x: s * 0.20, y: s * 0.22, width: s * 0.60, height: s * 0.56))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
}
