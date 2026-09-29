#if DEBUG
import AppKit
import SwiftUI

/// `utter://debug/snapshot?dir=…` renders Utter's own visible windows (menu popover, HUD, windows) to PNGs
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
            guard let view = window.contentView?.superview ?? window.contentView,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window.title.isEmpty ? String(describing: type(of: window)) : window.title
            let file = directory.appendingPathComponent("\(index)-\(name.replacingOccurrences(of: " ", with: "_")).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
        }
        model.isMenuPresented = false

        // SwiftUI-rendered copies (the window captures above miss layer-backed SwiftUI content).
        render(MenuBarView(model: model, isPresented: .constant(true)).padding(1), to: directory.appendingPathComponent("render-menu.png"))
        render(HUDView(model: model), to: directory.appendingPathComponent("render-hud.png"))
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
