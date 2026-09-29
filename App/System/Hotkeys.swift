import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Tap to start/stop, or hold to talk. ⌥Space matches Superwhisper's default.
    static let toggleRecording = Self("toggleRecording", initial: .init(.space, modifiers: [.option]))
}

extension KeyboardShortcuts.Shortcut {
    /// Registered only while a dictation is running, so Esc keeps working normally in other apps.
    static let escape = KeyboardShortcuts.Shortcut(.escape)
}

enum Sounds {
    @MainActor
    static func play(_ name: String, enabled: Bool) {
        guard enabled, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.35
        sound.play()
    }
}
