import AppKit
import SwiftUI

/// Shows the recording HUD in a floating panel that never takes keyboard focus, so the text field you
/// are dictating into stays focused and receives the paste.
@MainActor
final class HUDController {
    private unowned let model: AppModel
    private var panel: HUDPanel?
    private var moveObserver: NSObjectProtocol?
    private var isPositioning = false

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let panel = panel ?? makePanel()
        if !panel.isVisible { position(panel) }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> HUDPanel {
        let panel = HUDPanel()
        let hosting = ClickThroughHostingView(rootView: HUDView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberPosition() }
        }
        self.panel = panel
        return panel
    }

    private func position(_ panel: HUDPanel) {
        isPositioning = true
        defer { isPositioning = false }
        let size = panel.frame.size
        if let origin = model.settings.hudOrigin,
            NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSRect(origin: origin, size: CGSize(width: 40, height: 40))) })
        {
            panel.setFrameOrigin(origin)
            return
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 72))
    }

    private func rememberPosition() {
        guard !isPositioning, let panel, panel.isVisible else { return }
        model.settings.hudOrigin = panel.frame.origin
    }
}

/// Borderless, non-activating, floating on every Space (including full-screen apps).
final class HUDPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 72),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets HUD buttons respond to the first click even though the panel is never key.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
