import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let microphoneUID = "microphoneUID"
        static let autoPaste = "autoPaste"
        static let restoreClipboard = "restoreClipboard"
        static let trailingSpace = "trailingSpace"
        static let showLiveText = "showLiveText"
        static let playSounds = "playSounds"
        static let cleanupEnabled = "cleanupEnabled"
        static let cleanupInstructions = "cleanupInstructions"
        static let keepWarmSeconds = "keepWarmSeconds"
        static let maxRecordingMinutes = "maxRecordingMinutes"
        static let keepRecordings = "keepRecordings"
        static let historyRetentionDays = "historyRetentionDays"
        static let hudOrigin = "hudOrigin"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// nil = follow the system default input.
    var microphoneUID: String? { didSet { defaults.set(microphoneUID, forKey: Key.microphoneUID) } }
    var autoPaste: Bool { didSet { defaults.set(autoPaste, forKey: Key.autoPaste) } }
    var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: Key.restoreClipboard) } }
    var trailingSpace: Bool { didSet { defaults.set(trailingSpace, forKey: Key.trailingSpace) } }
    var showLiveText: Bool { didSet { defaults.set(showLiveText, forKey: Key.showLiveText) } }
    var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }
    var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: Key.cleanupEnabled) } }
    var cleanupInstructions: String { didSet { defaults.set(cleanupInstructions, forKey: Key.cleanupInstructions) } }
    var keepWarmSeconds: Int { didSet { defaults.set(keepWarmSeconds, forKey: Key.keepWarmSeconds) } }
    var maxRecordingMinutes: Int { didSet { defaults.set(maxRecordingMinutes, forKey: Key.maxRecordingMinutes) } }
    var keepRecordings: Bool { didSet { defaults.set(keepRecordings, forKey: Key.keepRecordings) } }
    /// 0 = keep forever.
    var historyRetentionDays: Int { didSet { defaults.set(historyRetentionDays, forKey: Key.historyRetentionDays) } }
    /// Bottom-left corner of the HUD after the user drags it; nil = centered near the bottom.
    var hudOrigin: CGPoint? {
        didSet {
            if let hudOrigin {
                defaults.set([hudOrigin.x, hudOrigin.y], forKey: Key.hudOrigin)
            } else {
                defaults.removeObject(forKey: Key.hudOrigin)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.autoPaste: true,
            Key.restoreClipboard: true,
            Key.trailingSpace: true,
            Key.showLiveText: true,
            Key.playSounds: true,
            Key.cleanupEnabled: false,
            Key.keepWarmSeconds: 0,
            Key.maxRecordingMinutes: 60,
            Key.keepRecordings: false,
            Key.historyRetentionDays: 0,
        ])
        microphoneUID = defaults.string(forKey: Key.microphoneUID)
        autoPaste = defaults.bool(forKey: Key.autoPaste)
        restoreClipboard = defaults.bool(forKey: Key.restoreClipboard)
        trailingSpace = defaults.bool(forKey: Key.trailingSpace)
        showLiveText = defaults.bool(forKey: Key.showLiveText)
        playSounds = defaults.bool(forKey: Key.playSounds)
        cleanupEnabled = defaults.bool(forKey: Key.cleanupEnabled)
        cleanupInstructions = defaults.string(forKey: Key.cleanupInstructions) ?? ""
        keepWarmSeconds = defaults.integer(forKey: Key.keepWarmSeconds)
        maxRecordingMinutes = max(1, defaults.integer(forKey: Key.maxRecordingMinutes))
        keepRecordings = defaults.bool(forKey: Key.keepRecordings)
        historyRetentionDays = defaults.integer(forKey: Key.historyRetentionDays)
        if let pair = defaults.array(forKey: Key.hudOrigin) as? [Double], pair.count == 2 {
            hudOrigin = CGPoint(x: pair[0], y: pair[1])
        } else {
            hudOrigin = nil
        }
    }
}
