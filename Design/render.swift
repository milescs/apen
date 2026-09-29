import AppKit
// usage: render2 <in.svg> <out.png> <pixelSize> [shadow]
let a = CommandLine.arguments
guard a.count >= 4, let size = Int(a[3]), let image = NSImage(contentsOf: URL(fileURLWithPath: a[1])) else { exit(1) }
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
if a.count > 4 {
    // macOS icon convention: the squircle floats on a soft shadow inside the transparent margin.
    let shadow = NSShadow()
    shadow.shadowBlurRadius = CGFloat(size) * 0.022
    shadow.shadowOffset = NSSize(width: 0, height: -CGFloat(size) * 0.012)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.set()
}
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
