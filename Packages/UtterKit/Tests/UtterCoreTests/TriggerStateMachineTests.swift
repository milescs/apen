import Testing
import UtterCore

private typealias Machine = TriggerStateMachine
private typealias Input = TriggerStateMachine.Input
private typealias Action = TriggerStateMachine.Action
private typealias Phase = TriggerStateMachine.Phase

/// A reachable configuration of the machine, built from inputs stamped at or before t = 12 s.
enum TriggerSetup: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case idle
    /// Cancelled with Escape while the hotkey was still held down.
    case idleKeyStillDown
    /// The hotkey went down at t = 10 and is still held.
    case recordingKeyDown
    /// Tapped at t = 10 (released at 10.1), so recording is latched on.
    case recordingLatched
    /// Push-to-talk released at t = 11.
    case processing
    /// Latched recording stopped by a press at t = 12 that is still held.
    case processingKeyDown
    case cleaning
    /// Cleanup skipped by a press at t = 12 that is still held.
    case cleaningKeyDown

    var inputs: [TriggerStateMachine.Input] {
        switch self {
        case .idle: []
        case .idleKeyStillDown: [.hotkeyDown(at: 10), .escape]
        case .recordingKeyDown: [.hotkeyDown(at: 10)]
        case .recordingLatched: [.hotkeyDown(at: 10), .hotkeyUp(at: 10.1)]
        case .processing: [.hotkeyDown(at: 10), .hotkeyUp(at: 11)]
        case .processingKeyDown: [.hotkeyDown(at: 10), .hotkeyUp(at: 10.1), .hotkeyDown(at: 12)]
        case .cleaning: [.hotkeyDown(at: 10), .hotkeyUp(at: 11), .cleanupStarted]
        case .cleaningKeyDown: [.hotkeyDown(at: 10), .hotkeyUp(at: 11), .cleanupStarted, .hotkeyDown(at: 12)]
        }
    }

    var phase: TriggerStateMachine.Phase {
        switch self {
        case .idle, .idleKeyStillDown: .idle
        case .recordingKeyDown, .recordingLatched: .recording
        case .processing, .processingKeyDown: .processing
        case .cleaning, .cleaningKeyDown: .cleaning
        }
    }

    func machine() -> TriggerStateMachine {
        var machine = TriggerStateMachine()
        for input in inputs { _ = machine.handle(input) }
        return machine
    }

    var testDescription: String { rawValue }
}

struct TriggerTransition: Sendable, CustomTestStringConvertible {
    let setup: TriggerSetup
    let input: TriggerStateMachine.Input
    let action: TriggerStateMachine.Action
    let phase: TriggerStateMachine.Phase

    init(
        _ setup: TriggerSetup,
        _ input: TriggerStateMachine.Input,
        _ action: TriggerStateMachine.Action,
        _ phase: TriggerStateMachine.Phase
    ) {
        self.setup = setup
        self.input = input
        self.action = action
        self.phase = phase
    }

    var testDescription: String { "\(setup) + \(input) → \(action), \(phase)" }
}

/// Every configuration × every input. Presses land at t = 20, so a held key has been down for 10 s.
private let transitions: [TriggerTransition] = [
    .init(.idle, .hotkeyDown(at: 20), .startRecording, .recording),
    .init(.idle, .hotkeyUp(at: 20), .none, .idle),
    .init(.idle, .escape, .none, .idle),
    .init(.idle, .stopButton, .none, .idle),
    .init(.idle, .cancelButton, .none, .idle),
    .init(.idle, .cleanupStarted, .none, .idle),
    .init(.idle, .sessionFinished, .none, .idle),

    .init(.idleKeyStillDown, .hotkeyDown(at: 20), .none, .idle),
    .init(.idleKeyStillDown, .hotkeyUp(at: 20), .none, .idle),
    .init(.idleKeyStillDown, .escape, .none, .idle),
    .init(.idleKeyStillDown, .stopButton, .none, .idle),
    .init(.idleKeyStillDown, .cancelButton, .none, .idle),
    .init(.idleKeyStillDown, .cleanupStarted, .none, .idle),
    .init(.idleKeyStillDown, .sessionFinished, .none, .idle),

    .init(.recordingKeyDown, .hotkeyDown(at: 20), .none, .recording),
    .init(.recordingKeyDown, .hotkeyUp(at: 20), .stopRecording, .processing),
    .init(.recordingKeyDown, .escape, .cancelRecording, .idle),
    .init(.recordingKeyDown, .stopButton, .stopRecording, .processing),
    .init(.recordingKeyDown, .cancelButton, .cancelRecording, .idle),
    .init(.recordingKeyDown, .cleanupStarted, .none, .recording),
    .init(.recordingKeyDown, .sessionFinished, .none, .idle),

    .init(.recordingLatched, .hotkeyDown(at: 20), .stopRecording, .processing),
    .init(.recordingLatched, .hotkeyUp(at: 20), .none, .recording),
    .init(.recordingLatched, .escape, .cancelRecording, .idle),
    .init(.recordingLatched, .stopButton, .stopRecording, .processing),
    .init(.recordingLatched, .cancelButton, .cancelRecording, .idle),
    .init(.recordingLatched, .cleanupStarted, .none, .recording),
    .init(.recordingLatched, .sessionFinished, .none, .idle),

    .init(.processing, .hotkeyDown(at: 20), .none, .processing),
    .init(.processing, .hotkeyUp(at: 20), .none, .processing),
    .init(.processing, .escape, .skipPaste, .processing),
    .init(.processing, .stopButton, .none, .processing),
    .init(.processing, .cancelButton, .none, .processing),
    .init(.processing, .cleanupStarted, .none, .cleaning),
    .init(.processing, .sessionFinished, .none, .idle),

    .init(.processingKeyDown, .hotkeyDown(at: 20), .none, .processing),
    .init(.processingKeyDown, .hotkeyUp(at: 20), .none, .processing),
    .init(.processingKeyDown, .escape, .skipPaste, .processing),
    .init(.processingKeyDown, .stopButton, .none, .processing),
    .init(.processingKeyDown, .cancelButton, .none, .processing),
    .init(.processingKeyDown, .cleanupStarted, .none, .cleaning),
    .init(.processingKeyDown, .sessionFinished, .none, .idle),

    .init(.cleaning, .hotkeyDown(at: 20), .skipCleanup, .cleaning),
    .init(.cleaning, .hotkeyUp(at: 20), .none, .cleaning),
    .init(.cleaning, .escape, .skipPaste, .cleaning),
    .init(.cleaning, .stopButton, .none, .cleaning),
    .init(.cleaning, .cancelButton, .none, .cleaning),
    .init(.cleaning, .cleanupStarted, .none, .cleaning),
    .init(.cleaning, .sessionFinished, .none, .idle),

    .init(.cleaningKeyDown, .hotkeyDown(at: 20), .none, .cleaning),
    .init(.cleaningKeyDown, .hotkeyUp(at: 20), .none, .cleaning),
    .init(.cleaningKeyDown, .escape, .skipPaste, .cleaning),
    .init(.cleaningKeyDown, .stopButton, .none, .cleaning),
    .init(.cleaningKeyDown, .cancelButton, .none, .cleaning),
    .init(.cleaningKeyDown, .cleanupStarted, .none, .cleaning),
    .init(.cleaningKeyDown, .sessionFinished, .none, .idle),
]

/// Feeds `inputs` in order and returns the actions the machine asked for.
private func feed(_ machine: inout Machine, _ inputs: Input...) -> [Action] {
    inputs.map { machine.handle($0) }
}

@Suite("TriggerStateMachine")
struct TriggerStateMachineTests {
    @Test func startsIdleWithTheDefaultHoldThreshold() {
        let machine = Machine()
        #expect(machine.phase == .idle)
        #expect(machine.holdThreshold == 0.35)
    }

    @Test(arguments: TriggerSetup.allCases)
    func setupsReachTheirPhase(_ setup: TriggerSetup) {
        #expect(setup.machine().phase == setup.phase)
    }

    @Test("Every phase handles every input", arguments: transitions)
    func everyPhaseHandlesEveryInput(_ transition: TriggerTransition) {
        var machine = transition.setup.machine()
        #expect(machine.handle(transition.input) == transition.action)
        #expect(machine.phase == transition.phase)
    }

    @Test func tapLatchesRecordingAndTheNextPressStopsIt() {
        var machine = Machine()
        #expect(machine.handle(.hotkeyDown(at: 1.0)) == .startRecording)
        #expect(machine.handle(.hotkeyUp(at: 1.1)) == Action.none)
        #expect(machine.phase == .recording)

        #expect(machine.handle(.hotkeyDown(at: 6.0)) == .stopRecording)
        #expect(machine.phase == .processing)
        // The stopping press's release is ignored.
        #expect(machine.handle(.hotkeyUp(at: 6.1)) == Action.none)
        #expect(machine.phase == .processing)
    }

    @Test func releasingAHeldKeyStopsRecording() {
        var machine = Machine()
        #expect(machine.handle(.hotkeyDown(at: 1.0)) == .startRecording)
        #expect(machine.handle(.hotkeyUp(at: 4.0)) == .stopRecording)
        #expect(machine.phase == .processing)
    }

    @Test(arguments: [0.0, 10.0, 1234.567])
    func releaseExactlyAtTheThresholdCountsAsHold(_ downAt: Double) {
        var machine = Machine()
        _ = machine.handle(.hotkeyDown(at: downAt))
        // 10.35 - 10.0 is 0.34999999999999964 in binary floating point; it must still count as a hold.
        #expect(machine.handle(.hotkeyUp(at: downAt + 0.35)) == .stopRecording)
        #expect(machine.phase == .processing)
    }

    @Test func releaseJustBeforeTheThresholdLatches() {
        var machine = Machine()
        _ = machine.handle(.hotkeyDown(at: 0))
        #expect(machine.handle(.hotkeyUp(at: 0.349)) == Action.none)
        #expect(machine.phase == .recording)
    }

    @Test func customThresholdIsHonoured() {
        var tapped = Machine(holdThreshold: 0.5)
        #expect(tapped.holdThreshold == 0.5)
        _ = tapped.handle(.hotkeyDown(at: 2.0))
        #expect(tapped.handle(.hotkeyUp(at: 2.4)) == Action.none)
        #expect(tapped.phase == .recording)

        var held = Machine(holdThreshold: 0.5)
        _ = held.handle(.hotkeyDown(at: 2.0))
        #expect(held.handle(.hotkeyUp(at: 2.5)) == .stopRecording)
    }

    @Test func zeroThresholdIsPurePushToTalkAndInfiniteThresholdIsPureToggle() {
        var pushToTalk = Machine(holdThreshold: 0)
        _ = pushToTalk.handle(.hotkeyDown(at: 5))
        #expect(pushToTalk.handle(.hotkeyUp(at: 5)) == .stopRecording)

        var toggle = Machine(holdThreshold: .infinity)
        _ = toggle.handle(.hotkeyDown(at: 5))
        #expect(toggle.handle(.hotkeyUp(at: 500)) == Action.none)
        #expect(toggle.phase == .recording)
        #expect(toggle.handle(.hotkeyDown(at: 600)) == .stopRecording)
    }

    @Test func keyRepeatDownsAreIgnoredAndTheHoldIsTimedFromTheFirstDown() {
        var machine = Machine()
        let expected: [Action] = [.startRecording, .none, .none, .none, .stopRecording]
        // Repeats arrive after the hold threshold, but the release is what matters.
        let actions = feed(
            &machine,
            .hotkeyDown(at: 0), .hotkeyDown(at: 0.5), .hotkeyDown(at: 0.53), .hotkeyDown(at: 0.56),
            .hotkeyUp(at: 0.6)
        )
        #expect(actions == expected)
        #expect(machine.phase == .processing)
    }

    @Test func keyRepeatsOfAShortPressDoNotStopTheLatchedRecording() {
        var machine = Machine()
        let expected: [Action] = [.startRecording, .none, .none]
        #expect(feed(&machine, .hotkeyDown(at: 0), .hotkeyDown(at: 0.1), .hotkeyUp(at: 0.2)) == expected)
        #expect(machine.phase == .recording)
    }

    @Test func keyRepeatsOfTheStoppingPressAreIgnored() {
        var machine = Machine()
        let expected: [Action] = [.startRecording, .none, .stopRecording, .none, .none, .none]
        let actions = feed(
            &machine,
            .hotkeyDown(at: 0), .hotkeyUp(at: 0.1),
            .hotkeyDown(at: 3), .hotkeyDown(at: 3.5), .hotkeyDown(at: 3.53), .hotkeyUp(at: 4)
        )
        #expect(actions == expected)
        #expect(machine.phase == .processing)
    }

    @Test func releaseWithoutATrackedPressIsIgnored() {
        var idle = Machine()
        #expect(idle.handle(.hotkeyUp(at: 1)) == Action.none)
        #expect(idle == Machine())

        var latched = Machine()
        _ = feed(&latched, .hotkeyDown(at: 0), .hotkeyUp(at: 0.1))
        #expect(latched.handle(.hotkeyUp(at: 9)) == Action.none)
        #expect(latched.phase == .recording)
    }

    @Test(
        arguments: [TriggerStateMachine.Input.escape, .cancelButton],
        [TriggerSetup.recordingKeyDown, .recordingLatched]
    )
    func escapeAndTheCancelButtonCancelRecording(_ input: TriggerStateMachine.Input, _ setup: TriggerSetup) {
        var machine = setup.machine()
        #expect(machine.handle(input) == .cancelRecording)
        #expect(machine.phase == .idle)
    }

    @Test func cancellingWhileTheKeyIsHeldIgnoresItsRepeatsAndRelease() {
        var machine = Machine()
        let expected: [Action] = [.startRecording, .cancelRecording, .none, .none, .none, .startRecording]
        let actions = feed(
            &machine,
            .hotkeyDown(at: 0), .escape,
            .hotkeyDown(at: 0.5), .hotkeyDown(at: 0.53), .hotkeyUp(at: 1),
            .hotkeyDown(at: 2)
        )
        #expect(actions == expected)
        #expect(machine.phase == .recording)
    }

    @Test func stopButtonStopsRecordingAndTheHeldKeysReleaseIsIgnored() {
        var machine = Machine()
        let expected: [Action] = [.startRecording, .stopRecording, .none, .none]
        #expect(feed(&machine, .hotkeyDown(at: 0), .stopButton, .hotkeyDown(at: 0.5), .hotkeyUp(at: 2)) == expected)
        #expect(machine.phase == .processing)
    }

    @Test func escapeSkipsThePasteWithoutChangingPhase() {
        var processing = TriggerSetup.processing.machine()
        #expect(processing.handle(.escape) == .skipPaste)
        #expect(processing.handle(.escape) == .skipPaste)
        #expect(processing.phase == .processing)

        var cleaning = TriggerSetup.cleaning.machine()
        #expect(cleaning.handle(.escape) == .skipPaste)
        #expect(cleaning.phase == .cleaning)
    }

    @Test(arguments: [TriggerSetup.idle, .recordingKeyDown, .recordingLatched, .cleaning])
    func cleanupStartedOnlyMovesProcessingToCleaning(_ setup: TriggerSetup) {
        var machine = setup.machine()
        #expect(machine.handle(.cleanupStarted) == Action.none)
        #expect(machine == setup.machine())
    }

    @Test func eachPressDuringCleanupSkipsItOnce() {
        var machine = TriggerSetup.cleaning.machine()
        let expected: [Action] = [.skipCleanup, .none, .none, .skipCleanup, .none]
        let actions = feed(
            &machine,
            .hotkeyDown(at: 20), .hotkeyDown(at: 20.5), .hotkeyUp(at: 21),
            .hotkeyDown(at: 22), .hotkeyUp(at: 22.1)
        )
        #expect(actions == expected)
        #expect(machine.phase == .cleaning)
    }

    @Test func aPressDuringProcessingIsIgnoredEvenWhenHeldIntoCleanup() {
        var machine = TriggerSetup.processing.machine()
        let expected: [Action] = [.none, .none, .none, .none, .skipCleanup]
        let actions = feed(
            &machine,
            .hotkeyDown(at: 20), .cleanupStarted, .hotkeyDown(at: 20.5), .hotkeyUp(at: 21),
            .hotkeyDown(at: 22)
        )
        #expect(actions == expected)
        #expect(machine.phase == .cleaning)
    }

    @Test(arguments: TriggerSetup.allCases)
    func sessionFinishedResetsEverything(_ setup: TriggerSetup) {
        var machine = setup.machine()
        #expect(machine.handle(.sessionFinished) == Action.none)
        #expect(machine == Machine())
    }

    @Test func sessionFinishedForgetsAKeyStillHeldSoTheNextPressStartsRecording() {
        var machine = Machine()
        let expected: [Action] = [.startRecording, .none, .startRecording]
        // The key-up after the first press was lost; the session still ends and the hotkey keeps working.
        #expect(feed(&machine, .hotkeyDown(at: 0), .sessionFinished, .hotkeyDown(at: 5)) == expected)
        #expect(machine.phase == .recording)
    }

    @Test func fullToggleCycleThenASecondSession() {
        var machine = Machine()
        let firstSession: [Action] = [.startRecording, .none, .stopRecording, .none, .none, .none]
        let first = feed(
            &machine,
            .hotkeyDown(at: 100.0), .hotkeyUp(at: 100.12),   // tap: latch on
            .hotkeyDown(at: 104.0), .hotkeyUp(at: 104.08),   // tap: stop
            .cleanupStarted, .sessionFinished
        )
        #expect(first == firstSession)
        #expect(machine == Machine())

        let secondSession: [Action] = [.startRecording, .none, .stopRecording, .skipPaste, .none]
        let second = feed(
            &machine,
            .hotkeyDown(at: 110.0), .hotkeyDown(at: 110.6),  // hold, with a key repeat
            .hotkeyUp(at: 112.0),                            // release: push-to-talk stop
            .escape, .sessionFinished
        )
        #expect(second == secondSession)
        #expect(machine == Machine())
    }
}
