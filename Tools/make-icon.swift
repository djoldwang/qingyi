import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixels) / 1024
    NSAffineTransform(transform: AffineTransform(scale: scale)).concat()
    let rect = NSRect(x: 78, y: 78, width: 868, height: 868)
    let path = NSBezierPath(roundedRect: rect, xRadius: 205, yRadius: 205)
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.40, green: 0.43, blue: 0.96, alpha: 1), ending: NSColor(calibratedRed: 0.23, green: 0.27, blue: 0.72, alpha: 1))!
    gradient.draw(in: path, angle: -60)
    let text: NSString = "译"
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 525, weight: .medium), .foregroundColor: NSColor.white]
    let size = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (1024 - size.width) / 2, y: (1024 - size.height) / 2 + 12), withAttributes: attributes)
    let dot = NSBezierPath(ovalIn: NSRect(x: 755, y: 765, width: 48, height: 48))
    NSColor(calibratedRed: 0.72, green: 0.93, blue: 0.89, alpha: 1).setFill(); dot.fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
}
