import AppKit
import SwiftUI

/// Opens Apen's regular windows (History, Dictionary, Settings, …) from a menu-bar-only app.
///
/// While any window is open the app switches to the `.regular` activation policy so windows come to the
/// front and appear in ⌘Tab; when the last one closes it goes back to `.accessory` (menu bar only).
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    enum Kind: String, CaseIterable {
        case history, dictionary, settings, fileTranscription, onboarding, about

        var title: String {
            switch self {
            case .history: "Apen History"
            case .dictionary: "Apen Dictionary"
            case .settings: "Apen Settings"
            case .fileTranscription: "Transcribe a File"
            case .onboarding: "Welcome to Apen"
            case .about: "About Apen"
            }
        }

        var defaultSize: NSSize {
            switch self {
            case .history: NSSize(width: 860, height: 560)
            case .dictionary: NSSize(width: 820, height: 520)
            case .settings: NSSize(width: 620, height: 520)
            case .fileTranscription: NSSize(width: 640, height: 520)
            case .onboarding: NSSize(width: 620, height: 640)
            case .about: NSSize(width: 460, height: 420)
            }
        }
    }

    private var windows: [Kind: NSWindow] = [:]

    func show<Content: View>(_ kind: Kind, @ViewBuilder content: () -> Content) {
        let window = windows[kind] ?? makeWindow(kind, content: content())
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close(_ kind: Kind) {
        windows[kind]?.close()
    }

    /// True when one of Apen's own windows (not the menu popover or HUD) has keyboard focus.
    var hasKeyWindow: Bool {
        windows.values.contains { $0.isKeyWindow }
    }

    func isOpen(_ kind: Kind) -> Bool {
        windows[kind]?.isVisible == true
    }

    private func makeWindow<Content: View>(_ kind: Kind, content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: kind.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = kind.title
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(kind.defaultSize)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("Apen.\(kind.rawValue)")
        if !window.setFrameUsingName("Apen.\(kind.rawValue)") { window.center() }
        windows[kind] = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        // Drop the window so its view (and any observation tasks) are released.
        if let kind = windows.first(where: { $0.value === closing })?.key {
            windows[kind] = nil
        }
        if windows.values.allSatisfy({ !$0.isVisible || $0 === closing }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
