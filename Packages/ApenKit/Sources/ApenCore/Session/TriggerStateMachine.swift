import Foundation

/// Decides what a press of the global dictation hotkey means.
///
/// There is a single hybrid mode:
/// - Tap the hotkey (release it before ``holdThreshold``) and recording stays on hands-free until the
///   next press stops it.
/// - Hold the hotkey for at least ``holdThreshold`` and its release stops recording (push-to-talk).
/// - Escape or the cancel button discards a recording.
///
/// After recording stops, Escape skips the paste. While the transcript is being cleaned up by the LLM, a
/// hotkey press skips the cleanup.
///
/// The machine is a pure value. Feed it ``Input`` events stamped with monotonic seconds and perform the
/// ``Action`` it returns. The pipeline reports its own progress with ``Input/cleanupStarted`` and
/// ``Input/sessionFinished``.
///
/// The machine remembers the hotkey press it saw go down. That way key-repeat downs are ignored, and a
/// release only counts for the press that started the recording. ``Input/sessionFinished`` forgets the
/// press so a lost key-up can never wedge the hotkey. The event tap should therefore still drop the OS's
/// key-repeat events, because a key held down across the end of a session would otherwise start the next
/// one.
public struct TriggerStateMachine: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// No session is running.
        case idle
        /// The microphone is recording.
        case recording
        /// Recording has stopped; the audio is being transcribed and delivered.
        case processing
        /// The transcript is being cleaned up by the LLM.
        case cleaning
    }

    public enum Input: Sendable, Equatable {
        /// The hotkey went down, in monotonic seconds (for example `ProcessInfo.systemUptime`).
        case hotkeyDown(at: TimeInterval)
        /// The hotkey came up, in monotonic seconds.
        case hotkeyUp(at: TimeInterval)
        case escape, stopButton, cancelButton
        /// The pipeline entered LLM cleanup.
        case cleanupStarted
        /// The session ended (pasted, saved, failed or cancelled), so the machine returns to idle.
        case sessionFinished
    }

    public enum Action: Sendable, Equatable {
        case none, startRecording, stopRecording, cancelRecording, skipCleanup, skipPaste
    }

    public private(set) var phase: Phase = .idle

    /// How long the hotkey must be held for its release to stop recording. A shorter press latches
    /// recording on until the next press.
    public let holdThreshold: TimeInterval

    /// When the hotkey went down, while the machine believes it is still held.
    ///
    /// During ``Phase/recording`` a held key is always the press that started the recording. In other
    /// phases the key is tracked only so that its key repeats and its release are ignored.
    private var keyDownAt: TimeInterval?

    /// Floating-point slack, so that a release exactly at the threshold counts as a hold.
    private static let timingTolerance: TimeInterval = 1e-9

    public init(holdThreshold: TimeInterval = 0.35) {
        self.holdThreshold = holdThreshold
    }

    public mutating func handle(_ input: Input) -> Action {
        switch input {
        case .hotkeyDown(let time):
            return hotkeyDown(at: time)
        case .hotkeyUp(let time):
            return hotkeyUp(at: time)
        case .escape:
            switch phase {
            case .idle: return .none
            case .recording: return cancelRecording()
            case .processing, .cleaning: return .skipPaste
            }
        case .cancelButton:
            return phase == .recording ? cancelRecording() : .none
        case .stopButton:
            return phase == .recording ? stopRecording() : .none
        case .cleanupStarted:
            if phase == .processing { phase = .cleaning }
            return .none
        case .sessionFinished:
            phase = .idle
            keyDownAt = nil
            return .none
        }
    }

    private mutating func hotkeyDown(at time: TimeInterval) -> Action {
        // The key is already down, so this is a key repeat.
        guard keyDownAt == nil else { return .none }
        keyDownAt = time
        switch phase {
        case .idle:
            phase = .recording
            return .startRecording
        case .recording:
            // No held key while recording means recording was latched by a tap. This press stops it, and
            // its release is ignored because the phase is no longer `recording`.
            return stopRecording()
        case .processing:
            return .none
        case .cleaning:
            return .skipCleanup
        }
    }

    private mutating func hotkeyUp(at time: TimeInterval) -> Action {
        guard let downAt = keyDownAt else { return .none }
        keyDownAt = nil
        // Only the release of the press that started the recording decides between toggle and hold.
        guard phase == .recording else { return .none }
        if time - downAt >= holdThreshold - Self.timingTolerance {
            return stopRecording()
        }
        // A tap: recording stays latched on until the next press.
        return .none
    }

    private mutating func stopRecording() -> Action {
        phase = .processing
        return .stopRecording
    }

    private mutating func cancelRecording() -> Action {
        // A key that is still held stays tracked, so its repeats cannot start a new recording.
        phase = .idle
        return .cancelRecording
    }
}
