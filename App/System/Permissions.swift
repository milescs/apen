import AVFoundation
import AppKit
import CoreGraphics

/// Microphone and event-posting (Accessibility) permissions.
@MainActor
enum Permissions {
    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var hasMicrophone: Bool { microphoneStatus == .authorized }

    /// Prompts the first time; afterwards returns the stored decision.
    static func requestMicrophone() async -> Bool {
        switch microphoneStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Needed to synthesize ⌘V. Listed under Privacy & Security › Accessibility.
    static var canPostEvents: Bool { CGPreflightPostEventAccess() }

    static func requestPostEvents() {
        if !CGRequestPostEventAccess() {
            openAccessibilitySettings()
        }
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
