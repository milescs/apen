import AppKit
import KeyboardShortcuts
import Observation
import UtterCore
import UtterEngines

/// Root controller: turns hotkey presses into dictation sessions and delivers the text.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle, recording, processing, cleaning
    }

    struct Notice: Equatable {
        enum Kind { case success, info, error }
        let kind: Kind
        let text: String
    }

    // MARK: Observable state

    private(set) var phase: Phase = .idle
    private(set) var partialText = ""
    private(set) var deviceName = ""
    private(set) var recordingStartedAt: Date?
    private(set) var isModelReady = false
    private(set) var notice: Notice?
    private(set) var inputDevices: [AudioInputDevice] = []
    private(set) var defaultInputName = "Default input"

    let settings = AppSettings()

    // MARK: Session plumbing

    @ObservationIgnored private var trigger = TriggerStateMachine()
    @ObservationIgnored private var session: DictationSession?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var sessionTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var escapeTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSource: DictationSession.AudioSource?
    @ObservationIgnored private var skipPaste = false
    @ObservationIgnored private var startedFromMenu = false
    @ObservationIgnored private var lastExternalApp: NSRunningApplication?
    @ObservationIgnored private let paster = Paster()
    @ObservationIgnored private lazy var hud = HUDController(model: self)

    static let supportDirectory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Utter", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let recordingsDirectory = supportDirectory.appendingPathComponent("Recordings", isDirectory: true)

    /// Level of the live microphone, polled by the HUD.
    var currentLevel: Float { session?.level ?? 0 }

    // MARK: Lifecycle

    func launch() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            self?.handle(.hotkeyDown(at: ProcessInfo.processInfo.systemUptime))
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.handle(.hotkeyUp(at: ProcessInfo.processInfo.systemUptime))
        }
        refreshDevices()
        Task { [weak self] in
            for await _ in AudioInputDevices.changes() {
                self?.refreshDevices()
            }
        }
        trackFrontmostApp()
        Task { await SpeechModelHost.shared.setKeepWarm(.seconds(settings.keepWarmSeconds)) }
    }

    func open(_ url: URL) {
        #if DEBUG
        if url.scheme == "utter", url.host == "debug" {
            handleDebugURL(url)
            return
        }
        #endif
        // File transcription is wired in a later milestone.
    }

    #if DEBUG
    /// `utter://debug/dictate?file=/path/to/audio.wav&speed=4` runs a full dictation with the file standing in
    /// for the microphone, then pastes into the frontmost app. Used by scripts/e2e-paste.sh.
    private func handleDebugURL(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard url.path == "/dictate", phase == .idle,
            let path = items.first(where: { $0.name == "file" })?.value
        else { return }
        let speed = items.first(where: { $0.name == "speed" })?.value.flatMap(Double.init) ?? 1
        pendingSource = .file(URL(fileURLWithPath: path), speed: speed)
        let now = ProcessInfo.processInfo.systemUptime
        handle(.hotkeyDown(at: now))
        handle(.hotkeyUp(at: now))
        Task { [weak self] in
            await self?.startTask?.value
            guard let session = self?.session else { return }
            await session.waitForFileSourceToFinish()
            try? await Task.sleep(for: .milliseconds(300))
            self?.handle(.stopButton)
        }
    }
    #endif

    // MARK: Menu actions

    /// The menu's Record/Stop button behaves like a quick tap on the hotkey.
    func toggleFromMenu() {
        switch phase {
        case .idle:
            startedFromMenu = true
            let now = ProcessInfo.processInfo.systemUptime
            handle(.hotkeyDown(at: now))
            handle(.hotkeyUp(at: now))
        case .recording:
            handle(.stopButton)
        case .processing, .cleaning:
            break
        }
    }

    func stopFromHUD() { handle(.stopButton) }
    func cancelFromHUD() { handle(phase == .recording ? .cancelButton : .escape) }

    func selectMicrophone(uid: String?) {
        settings.microphoneUID = uid
    }

    var selectedMicrophoneName: String {
        if let uid = settings.microphoneUID, let device = inputDevices.first(where: { $0.uid == uid }) {
            return device.name
        }
        return defaultInputName
    }

    // MARK: Trigger handling

    func handle(_ input: TriggerStateMachine.Input) {
        switch trigger.handle(input) {
        case .none:
            break
        case .startRecording:
            startTask = Task { await startRecording() }
        case .stopRecording:
            Task { await stopRecording() }
        case .cancelRecording:
            Task { await cancelRecording() }
        case .skipCleanup:
            break  // LLM cleanup arrives in a later milestone.
        case .skipPaste:
            skipPaste = true
            show(Notice(kind: .info, text: "Won't paste — the text will be saved to History"), for: .seconds(2))
        }
    }

    // MARK: Recording

    private func startRecording() async {
        guard SpeechModel.isDownloaded else {
            return abortStart("Download the speech model first: run `utter models download`.")
        }
        let source = pendingSource ?? .microphone(deviceUID: settings.microphoneUID)
        pendingSource = nil
        if case .microphone = source, await !Permissions.requestMicrophone() {
            Permissions.openMicrophoneSettings()
            return abortStart("Utter needs microphone access. Enable it in System Settings › Privacy & Security › Microphone.")
        }

        skipPaste = false
        partialText = ""
        isModelReady = false
        noticeTask?.cancel()
        notice = nil
        if !startedFromMenu, let app = NSWorkspace.shared.frontmostApplication,
            app.bundleIdentifier != Bundle.main.bundleIdentifier
        {
            lastExternalApp = app
        }

        let recordingURL = Self.recordingsDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        let session = DictationSession(recordingURL: recordingURL)
        self.session = session
        self.recordingURL = recordingURL
        phase = .recording
        recordingStartedAt = Date()
        hud.show()
        Sounds.play("Tink", enabled: settings.playSounds)

        do {
            let info = try await session.start(source: source)
            deviceName = info.deviceName
            if info.usedFallbackDevice {
                show(Notice(kind: .info, text: "Selected microphone unavailable — using \(info.deviceName)"), for: .seconds(3))
            }
        } catch {
            self.session = nil
            try? FileManager.default.removeItem(at: recordingURL)
            return abortStart("Couldn't start the microphone: \(error.localizedDescription)")
        }

        startEscapeMonitor()
        sessionTasks = [
            Task { [weak self] in
                for await text in session.partials {
                    self?.partialText = text
                }
            },
            Task { [weak self] in
                do {
                    try await session.waitUntilModelReady()
                    self?.isModelReady = true
                } catch {}
            },
            Task { [weak self] in
                for await _ in session.interruptions {
                    self?.show(Notice(kind: .info, text: "Microphone changed — finishing this dictation"), for: .seconds(3))
                    self?.handle(.stopButton)
                }
            },
            Task { [weak self, minutes = settings.maxRecordingMinutes] in
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled else { return }
                self?.handle(.stopButton)
            },
        ]
    }

    private func abortStart(_ message: String) {
        phase = .idle
        startedFromMenu = false
        _ = trigger.handle(.sessionFinished)
        Sounds.play("Basso", enabled: settings.playSounds)
        hud.show()
        show(Notice(kind: .error, text: message), for: .seconds(5))
    }

    private func stopRecording() async {
        await startTask?.value
        guard let session else { return }
        phase = .processing
        Sounds.play("Pop", enabled: settings.playSounds)
        cancelSessionTasks()

        let result: DictationSession.Result
        do {
            result = try await session.stop()
        } catch {
            finishSession()
            show(
                Notice(kind: .error, text: "Transcription failed: \(error.localizedDescription). The audio was kept."),
                for: .seconds(6)
            )
            return
        }

        if TextFinisher.isEffectivelyEmpty(result.text) {
            deleteRecording(result.recordingURL)
            finishSession()
            show(Notice(kind: .info, text: "No speech detected"), for: .seconds(2))
            return
        }

        let text = TextFinisher.finish(result.text, trailingSpace: settings.trailingSpace)
        var outcomeNotice = Notice(kind: .success, text: "Saved")
        if !skipPaste {
            await returnFocusIfNeeded()
            switch await paster.deliver(text, autoPaste: settings.autoPaste, restoreClipboard: settings.restoreClipboard) {
            case .pasted:
                outcomeNotice = Notice(kind: .success, text: "Pasted")
            case .copiedOnly(let reason):
                outcomeNotice = Notice(kind: .info, text: "Copied to clipboard — \(reason)")
            }
        }
        if !settings.keepRecordings { deleteRecording(result.recordingURL) }
        finishSession()
        show(outcomeNotice, for: outcomeNotice.kind == .success ? .milliseconds(900) : .seconds(4))
    }

    private func cancelRecording() async {
        await startTask?.value
        guard let session else { return }
        cancelSessionTasks()
        await session.cancel()
        deleteRecording(recordingURL)
        finishSession()
        Sounds.play("Funk", enabled: settings.playSounds)
        show(Notice(kind: .info, text: "Cancelled"), for: .milliseconds(800))
    }

    private func finishSession() {
        session = nil
        recordingURL = nil
        startTask = nil
        phase = .idle
        partialText = ""
        recordingStartedAt = nil
        startedFromMenu = false
        escapeTask?.cancel()
        escapeTask = nil
        _ = trigger.handle(.sessionFinished)
    }

    private func cancelSessionTasks() {
        for task in sessionTasks { task.cancel() }
        sessionTasks.removeAll()
    }

    private func startEscapeMonitor() {
        escapeTask?.cancel()
        escapeTask = Task { [weak self] in
            for await event in KeyboardShortcuts.events(for: .escape) where event == .keyDown {
                self?.handle(.escape)
            }
        }
    }

    private func deleteRecording(_ url: URL?) {
        guard let url, url.pathExtension == "caf" else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Notices and HUD

    private func show(_ notice: Notice, for duration: Duration) {
        self.notice = notice
        hud.show()
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.notice = nil
            if self.phase == .idle { self.hud.hide() }
        }
    }

    // MARK: Devices and focus

    private func refreshDevices() {
        inputDevices = AudioInputDevices.all()
        defaultInputName = AudioInputDevices.defaultInput()?.name ?? "Default input"
    }

    /// Remembers the last app that wasn't Utter, so a dictation started from the menu can paste back into it.
    private func trackFrontmostApp() {
        lastExternalApp = NSWorkspace.shared.frontmostApplication
        Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: NSWorkspace.didActivateApplicationNotification) {
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    app.bundleIdentifier != Bundle.main.bundleIdentifier
                else { continue }
                self?.lastExternalApp = app
            }
        }
    }

    private func returnFocusIfNeeded() async {
        guard NSApp.isActive, let target = lastExternalApp, !target.isTerminated else { return }
        NSApp.yieldActivation(to: target)
        target.activate(from: .current, options: [])
        try? await Task.sleep(for: .milliseconds(200))
    }
}
