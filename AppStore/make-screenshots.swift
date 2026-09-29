// Composes the Mac App Store screenshots (2880×1800) from the captures in docs/screenshots.
// usage: swift AppStore/make-screenshots.swift   (run from the repository root)
import AppKit
import ImageIO
import UniformTypeIdentifiers

let width = 2880.0, height = 1800.0
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let shots = root.appending(path: "docs/screenshots")
let output = root.appending(path: "AppStore/screenshots")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func image(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: shots.appending(path: name)) else { fatalError("missing \(name)") }
    // Captures are 2× retina PNGs; work in pixels.
    let rep = image.representations[0]
    image.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    return image
}

/// Draws into a flipped (top-left origin), opaque sRGB canvas and writes a PNG without alpha.
func render(_ name: String, _ draw: () -> Void) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let cg = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                       space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    cg.translateBy(x: 0, y: height)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw()
    NSGraphicsContext.current = nil
    let url = output.appending(path: name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, cg.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(name)") }
    print("wrote \(url.path(percentEncoded: false))")
}

/// The icon's gradient, deepened so white type stays legible, plus a soft peach glow.
func background() {
    let gradient = NSGradient(colors: [color(0xF2557F), color(0xD9508F), color(0x8B5CD8)],
                              atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
    gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -32)
    let glow = NSGradient(colors: [color(0xFFB199, 0.55), color(0xFFB199, 0)], atLocations: [0, 1],
                          colorSpace: .sRGB)!
    glow.draw(fromCenter: NSPoint(x: 260, y: 1700), radius: 0, toCenter: NSPoint(x: 260, y: 1700), radius: 1300,
              options: [])
    let shine = NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)],
                           atLocations: [0, 1], colorSpace: .sRGB)!
    shine.draw(fromCenter: NSPoint(x: 700, y: 0), radius: 0, toCenter: NSPoint(x: 700, y: 0), radius: 1500,
               options: [])
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1, center: Bool = true)
    -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = center ? .center : .left
    paragraph.lineHeightMultiple = 1.05
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 14
    shadow.shadowOffset = NSSize(width: 0, height: -3)
    return NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        .paragraphStyle: paragraph, .shadow: shadow, .kern: size > 100 ? -1.5 : 0,
    ])
}

/// Headline and subtitle; returns the y where content may start.
@discardableResult
func captions(_ title: String, _ subtitle: String, in rect: NSRect, center: Bool = true, headline: CGFloat = 124)
    -> CGFloat {
    let head = text(title, size: headline, weight: .bold, center: center)
    let sub = text(subtitle, size: 54, weight: .medium, alpha: 0.92, center: center)
    let headHeight = head.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin]).height
    head.draw(with: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: headHeight),
              options: [.usesLineFragmentOrigin])
    let subTop = rect.minY + headHeight + 26
    let subHeight = sub.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin]).height
    sub.draw(with: NSRect(x: rect.minX, y: subTop, width: rect.width, height: subHeight),
             options: [.usesLineFragmentOrigin])
    return subTop + subHeight
}

/// Draws `image` (or its `crop`, in top-left pixel coordinates) scaled to fit `box`, centered.
func place(_ image: NSImage, fitting box: NSRect, crop: NSRect? = nil, maxScale: CGFloat = 1.5) {
    let source = crop ?? NSRect(origin: .zero, size: image.size)
    let scale = min(box.width / source.width, box.height / source.height, maxScale)
    let size = NSSize(width: source.width * scale, height: source.height * scale)
    let rect = NSRect(x: box.midX - size.width / 2, y: box.minY + (box.height - size.height) / 2,
                      width: size.width, height: size.height)
    // NSImage source rects use a bottom-left origin.
    let from = NSRect(x: source.minX, y: image.size.height - source.maxY, width: source.width, height: source.height)
    image.draw(in: rect, from: from, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

func tinted(_ image: NSImage, _ tint: NSColor) -> NSImage {
    NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        tint.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// 1. Hero: the menu bar popover hanging from Apen's icon, and the recording panel.
render("1-dictate-anywhere.png") {
    background()
    // A minimal menu bar with Apen's item selected.
    color(0x000000, 0.16).setFill()
    NSRect(x: 0, y: 0, width: width, height: 74).fill()
    let iconX = 2000.0
    color(0xFFFFFF, 0.28).setFill()
    NSBezierPath(roundedRect: NSRect(x: iconX - 50, y: 9, width: 100, height: 56), xRadius: 14, yRadius: 14).fill()
    let glyph = NSImage(contentsOf: root.appending(path: "App/Resources/Assets.xcassets/MenuBarIdle.imageset/MenuBarIdle.svg"))!
    tinted(glyph, .white).draw(in: NSRect(x: iconX - 25, y: 16, width: 50, height: 43))

    // The popover capture minus its original menu bar strip; its icon sat 108 px from the image's left edge.
    let menu = image("menu.png"), menuScale = 1.2
    let crop = NSRect(x: 0, y: 62, width: menu.size.width, height: menu.size.height - 62)
    let menuRect = NSRect(x: iconX - 108 * menuScale, y: 70, width: crop.width * menuScale,
                          height: crop.height * menuScale)
    let from = NSRect(x: crop.minX, y: menu.size.height - crop.maxY, width: crop.width, height: crop.height)
    menu.draw(in: menuRect, from: from, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

    let bottom = captions("Talk. Apen types.",
                          "Press ⌥Space in any app and speak.\nYour words appear right where you're typing.",
                          in: NSRect(x: 170, y: 500, width: 1650, height: 600), center: false, headline: 150)
    // The capture is 2× already; scaling past ~1.5× blurs its text. Its shadow margin is 46 px per side.
    let hud = image("recording.png"), scale = 1.45
    hud.draw(in: NSRect(x: 170 - 46 * scale, y: bottom + 120, width: hud.size.width * scale,
                        height: hud.size.height * scale),
             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

let slides: [(file: String, title: String, subtitle: String, capture: String)] = [
    ("2-private.png", "Private by design",
     "Speech is transcribed on your Mac with open-weight models. No account, no cloud.", "welcome.png"),
    ("3-dictionary.png", "Your jargon, spelled right",
     "Say “RLS” and get “row-level security”. Teach Apen your acronyms and names.", "dictionary.png"),
    ("4-modes.png", "The right style for every app",
     "Optional cleanup by a local LLM for coding prompts, messages, email and notes.", "settings-modes.png"),
    ("5-history.png", "Every dictation, one click away",
     "Searchable history that stays on your Mac, with Copy on every transcript.", "history.png"),
]
for slide in slides {
    render(slide.file) {
        background()
        let top = captions(slide.title, slide.subtitle, in: NSRect(x: 200, y: 120, width: width - 400, height: 500))
        place(image(slide.capture), fitting: NSRect(x: 160, y: top + 30, width: width - 320, height: height - top - 60))
    }
}
