#if DEBUG
import AppKit
import SwiftUI

/// `apen://debug/snapshot?dir=…` renders Apen's own visible windows (menu popover, HUD, windows) to PNGs
/// for layout review. Draws in-process, so it needs no screen-recording permission.
@MainActor
enum DebugSnapshots {
    static func capture(model: AppModel, into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.isMenuPresented = true
        model.show(AppModel.Notice(kind: .success, text: "Pasted"), for: .seconds(4))
        model.showHistory()
        model.showDictionary()
        model.showSettings()
        model.showOnboarding()
        model.showFileTranscription()
        try? await Task.sleep(for: .seconds(1.5))
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            let name = window.title.isEmpty ? String(describing: type(of: window)) : window.title
            let file = directory.appendingPathComponent("\(index)-\(name.replacingOccurrences(of: " ", with: "_")).png")
            if let png = layerSnapshot(of: window) { try? png.write(to: file) }
        }
        model.isMenuPresented = false

        // SwiftUI-rendered copies (the window captures above miss layer-backed SwiftUI content).
        render(MenuBarView(model: model, isPresented: .constant(true)).padding(1), to: directory.appendingPathComponent("render-menu.png"))
        render(HUDView(model: model), to: directory.appendingPathComponent("render-hud.png"))
    }

    /// Renders the window's whole layer tree (frame view included) at 2x, which captures SwiftUI content
    /// that `cacheDisplay` misses.
    static func layerSnapshot(of window: NSWindow, scale: CGFloat = 2) -> Data? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        view.wantsLayer = true
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let layer = view.layer else { return nil }
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        if layer.isGeometryFlipped || view.isFlipped {
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
        }
        layer.render(in: cg)
        return rep.representation(using: .png, properties: [:])
    }

    private static func render<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }
}
#endif
