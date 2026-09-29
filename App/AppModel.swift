import AppKit
import KeyboardShortcuts
import Observation
import UtterCore
import UtterEngines

/// Root controller: turns hotkey presses into dictation sessions, runs the text pipeline
/// (dictionary → optional cleanup → dictionary), delivers the result and saves it to History.
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
    private(set) var recents: [TranscriptRecord] = []
    private(set) var dictionary: [DictionaryEntry] = []
    private(set) var databaseError: String?
    /// The mode used for the current (or last) dictation, and whether it was picked by the app being dictated into.
    private(set) var activeMode: DictationMode = .coding
    private(set) var activeModeIsAutomatic = false
    private(set) var cleanupProgress: Double = 0
    /// Drives the menu-bar popover (MenuBarExtraAccess binding).
    var isMenuPresented = false

    let settings = AppSettings()
    let models = ModelManager()
    let files: FileTranscriptionModel

    // MARK: Services

    @ObservationIgnored let history: HistoryStore?
    @ObservationIgnored let dictionaryStore: DictionaryStore?
    @ObservationIgnored let windows = WindowCoordinator()
    @ObservationIgnored private let paster = Paster()
    @ObservationIgnored private lazy var hud = HUDController(model: self)

    // MARK: Session plumbing

    @ObservationIgnored private var trigger = TriggerStateMachine()
    @ObservationIgnored private var session: DictationSession?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var sessionTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var cleanupTask: Task<CleanupEngine.Result, Never>?
    @ObservationIgnored private var cleanupCheckedOut = false
    @ObservationIgnored private var escapeTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSource: DictationSession.AudioSource?
    @ObservationIgnored private var skipPaste = false
    @ObservationIgnored private var startedFromMenu = false
    @ObservationIgnored private var lastExternalApp: NSRunningApplication?

    static let supportDirectory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Utter", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let recordingsDirectory = supportDirectory.appendingPathComponent("Recordings", isDirectory: true)

    init() {
        var databaseError: String?
        var database: AppDatabase?
        do {
            database = try AppDatabase(fileURL: Self.supportDirectory.appendingPathComponent("utter.sqlite"))
        } catch {
            databaseError = error.localizedDescription
        }
        history = database.map { HistoryStore(database: $0) }
        dictionaryStore = database.map { DictionaryStore(database: $0) }
        self.databaseError = databaseError
        files = FileTranscriptionModel(history: database.map { HistoryStore(database: $0) })
    }

    /// Level of the live microphone, polled by the HUD.
    var currentLevel: Float { session?.level ?? 0 }

    var matcher: DictionaryMatcher { DictionaryMatcher(entries: dictionary) }

    var boostTerms: [BoostTerm] {
        dictionary.filter { $0.enabled && $0.boost }.map { BoostTerm(text: $0.trigger, aliases: $0.aliases) }
    }

    // MARK: Lifecycle

    func launch() {
        files.owner = self
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
        applyKeepWarm()
        observeStores()
        pruneHistory()
        recoverOrphanedRecordings()
        if needsOnboarding { showOnboarding() }
    }

    var needsOnboarding: Bool {
        !SpeechModel.isDownloaded || !Permissions.hasMicrophone || !Permissions.canPostEvents
    }

    func applyKeepWarm() {
        let seconds = settings.keepWarmSeconds
        Task {
            await SpeechModelHost.shared.setKeepWarm(.seconds(seconds))
            await CleanupHost.shared.setKeepWarm(.seconds(seconds))
        }
    }

    func open(_ url: URL) {
        #if DEBUG
        if url.scheme == "utter", url.host == "debug" {
            handleDebugURL(url)
            return
        }
        #endif
        if url.isFileURL {
            showFileTranscription()
            files.transcribe(url)
        }
    }

    #if DEBUG
    /// `utter://debug/dictate?file=/path/to/audio.wav&speed=4` runs a full dictation with the file standing in
    /// for the microphone, then pastes into the frontmost app. Used by scripts/e2e-paste.sh.
    private func handleDebugURL(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if url.path == "/snapshot" {
            let directory = URL(fileURLWithPath: items.first(where: { $0.name == "dir" })?.value ?? NSTemporaryDirectory())
            Task { await DebugSnapshots.capture(model: self, into: directory) }
            return
        }
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

    // MARK: Windows

    func showHistory() { windows.show(.history) { HistoryView(model: self) } }
    func showDictionary() { windows.show(.dictionary) { DictionaryView(model: self) } }
    func showSettings() { windows.show(.settings) { SettingsView(model: self) } }
    func showFileTranscription() { windows.show(.fileTranscription) { FileTranscriptionView(model: self) } }
    func showOnboarding() { windows.show(.onboarding) { OnboardingView(model: self) } }
    func showAbout() { windows.show(.about) { AboutView() } }

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

    func copy(_ text: String) {
        paster.copy(text)
    }

    /// Re-transcribes a failed dictation from its saved audio.
    func retry(_ record: TranscriptRecord) {
        guard let path = record.audioPath, let history else { return }
        let url = URL(fileURLWithPath: path)
        let terms = boostTerms
        let matcher = matcher
        Task {
            do {
                let result = try await FileTranscriptionJob.run(url: url, boostTerms: terms)
                var updated = record
                updated.rawText = result.text
                updated.finalText = TextFinisher.finish(matcher.expand(result.text), trailingSpace: false)
                updated.status = .completed
                updated.error = nil
                updated.durationSeconds = result.audioSeconds
                if !settings.keepRecordings {
                    try? FileManager.default.removeItem(at: url)
                    updated.audioPath = nil
                }
                try history.update(updated)
                show(Notice(kind: .success, text: "Retried — the transcript is in History"), for: .seconds(2))
            } catch {
                show(Notice(kind: .error, text: "Retry failed: \(error.localizedDescription)"), for: .seconds(4))
            }
        }
    }

    // MARK: Dictionary

    func saveDictionaryEntry(_ entry: DictionaryEntry) throws {
        guard let dictionaryStore else { return }
        _ = try dictionaryStore.save(entry)
    }

    func deleteDictionaryEntry(_ entry: DictionaryEntry) {
        guard let id = entry.id else { return }
        try? dictionaryStore?.delete(id: id)
    }

    func replaceDictionary(_ entries: [DictionaryEntry]) throws {
        try dictionaryStore?.replaceAll(entries)
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
            Task { await CleanupHost.shared.cancelInFlight() }
            cleanupTask?.cancel()
        case .skipPaste:
            skipPaste = true
            show(Notice(kind: .info, text: "Won't paste — the text will be saved to History"), for: .seconds(2))
        }
    }

    // MARK: Recording

    private func startRecording() async {
        guard SpeechModel.isDownloaded else {
            showOnboarding()
            return abortStart("Download the speech model first (Utter › Settings › Models).")
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

        let recordingURL = Self.recordingsDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        let session = DictationSession(recordingURL: recordingURL, boostTerms: boostTerms)
        self.session = session
        self.recordingURL = recordingURL
        phase = .recording
        recordingStartedAt = Date()
        hud.show()
        Sounds.play("Tink", enabled: settings.playSounds)

        resolveMode()
        // Load the cleanup model while the user talks, so it's ready when they stop.
        if settings.cleanupEnabled, activeMode.cleans, CleanupModel.isDownloaded {
            checkOutCleanupModel()
        }

        do {
            let info = try await session.start(source: source)
            deviceName = info.deviceName
            if info.usedFallbackDevice {
                show(Notice(kind: .info, text: "Selected microphone unavailable — using \(info.deviceName)"), for: .seconds(3))
            }
        } catch {
            self.session = nil
            try? FileManager.default.removeItem(at: recordingURL)
            releaseCleanupModel()
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
                let clock = ContinuousClock()
                let start = clock.now
                do {
                    try await session.waitUntilModelReady()
                    self?.isModelReady = true
                    self?.learnLoadTime(clock.now - start)
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
                self?.show(Notice(kind: .info, text: "Reached the \(minutes)-minute limit"), for: .seconds(3))
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
        let started = recordingStartedAt ?? Date()

        let result: DictationSession.Result
        do {
            result = try await session.stop()
            Log.session.notice(
                "Transcribed \(result.audioSeconds, format: .fixed(precision: 1)) s of audio; final text \(result.finishSeconds, format: .fixed(precision: 2)) s after stop"
            )
        } catch {
            Log.session.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            releaseCleanupModel()
            saveFailure(error: error, audioURL: recordingURL, seconds: Date().timeIntervalSince(started))
            finishSession()
            show(Notice(kind: .error, text: "Transcription failed: \(error.localizedDescription). The audio is saved — retry from History."), for: .seconds(6))
            return
        }

        if TextFinisher.isEffectivelyEmpty(result.text) {
            releaseCleanupModel()
            deleteRecording(result.recordingURL)
            finishSession()
            show(Notice(kind: .info, text: "No speech detected"), for: .seconds(2))
            return
        }

        // Dictionary aliases → triggers, optional LLM cleanup, then triggers → replacements.
        let matcher = matcher
        var working = matcher.normalize(result.text)
        var cleanedText: String?
        var cleanupModel: String?
        // The paste goes to whichever window is selected now, so pick the mode for that app.
        resolveMode()
        if settings.cleanupEnabled, activeMode.cleans, CleanupModel.isDownloaded, !cleanupCheckedOut {
            checkOutCleanupModel()
        }
        if cleanupCheckedOut, activeMode.cleans {
            phase = .cleaning
            cleanupProgress = 0
            _ = trigger.handle(.cleanupStarted)
            let input = working
            let terms = matcher.keepVerbatimTerms
            let mode = activeMode
            let instructions = settings.instructions(for: mode)
            let task = Task {
                await CleanupEngine().clean(input, keepVerbatim: terms, extraInstructions: instructions, mode: mode) { fraction in
                    Task { @MainActor in
                        if self.phase == .cleaning { self.cleanupProgress = max(self.cleanupProgress, fraction) }
                    }
                }
            }
            cleanupTask = task
            let cleaned = await task.value
            cleanupTask = nil
            if !cleaned.fellBack {
                working = cleaned.text
                cleanedText = cleaned.text
                cleanupModel = "\(CleanupModel.displayName) · \(mode.name)"
            }
        }
        releaseCleanupModel()
        let finalText = TextFinisher.finish(matcher.expand(working), trailingSpace: false)
        let pasteText = settings.trailingSpace ? finalText + " " : finalText

        var outcomeNotice = Notice(kind: .success, text: "Saved to History")
        var pasted = false
        var destination: NSRunningApplication?
        if !skipPaste {
            await returnFocusIfNeeded()
            destination = NSWorkspace.shared.frontmostApplication
            switch await paster.deliver(pasteText, autoPaste: settings.autoPaste, restoreClipboard: settings.restoreClipboard) {
            case .pasted:
                pasted = true
                outcomeNotice = Notice(kind: .success, text: "Pasted")
            case .copiedOnly(let reason):
                outcomeNotice = Notice(kind: .info, text: "Copied to clipboard — \(reason)")
            }
        }

        let keepAudio = settings.keepRecordings
        if !keepAudio { deleteRecording(result.recordingURL) }
        saveRecord(
            TranscriptRecord(
                kind: .dictation,
                sourceName: destination?.localizedName,
                sourceBundleID: destination?.bundleIdentifier,
                durationSeconds: result.audioSeconds,
                rawText: result.text,
                cleanedText: cleanedText,
                finalText: finalText,
                asrModel: SpeechModel.displayName,
                cleanupModel: cleanupModel,
                processingMilliseconds: Int(Date().timeIntervalSince(started) * 1000 - result.audioSeconds * 1000),
                audioPath: keepAudio ? result.recordingURL?.path : nil,
                pasted: pasted
            )
        )
        finishSession()
        show(outcomeNotice, for: outcomeNotice.kind == .success ? .milliseconds(900) : .seconds(4))
    }

    private func cancelRecording() async {
        await startTask?.value
        guard let session else { return }
        cancelSessionTasks()
        await session.cancel()
        releaseCleanupModel()
        deleteRecording(recordingURL)
        finishSession()
        Sounds.play("Funk", enabled: settings.playSounds)
        show(Notice(kind: .info, text: "Cancelled"), for: .milliseconds(800))
    }

    private func checkOutCleanupModel() {
        guard !cleanupCheckedOut else { return }
        cleanupCheckedOut = true
        Task { try? await CleanupHost.shared.checkout() }
    }

    /// Picks the mode for the app that will receive the paste (see `returnFocusIfNeeded`).
    private func resolveMode() {
        let destination: NSRunningApplication?
        if NSApp.isActive, !windows.hasKeyWindow {
            destination = lastExternalApp
        } else {
            destination = NSWorkspace.shared.frontmostApplication
        }
        let resolved = DictationMode.resolve(
            bundleID: destination?.bundleIdentifier, selectedID: settings.selectedModeID, apps: settings.modeApps
        )
        activeMode = resolved.mode
        activeModeIsAutomatic = resolved.automatic
    }

    func selectMode(_ mode: DictationMode) {
        settings.selectedModeID = mode.id
        if phase == .idle { activeMode = mode; activeModeIsAutomatic = false }
    }

    var selectedMode: DictationMode {
        DictationMode.mode(id: settings.selectedModeID) ?? .coding
    }

    // MARK: Progress indicators

    /// Estimated model-loading progress while recording, or nil once loaded (or for loads too quick to show).
    func modelLoadProgress(at now: Date) -> Double? {
        guard phase == .recording, !isModelReady, let start = recordingStartedAt else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > max(0.4, settings.warmLoadSeconds * 1.5) else { return nil }
        // Core ML doesn't report load progress; approach 100% over the last measured slow load.
        let tau = max(settings.coldLoadSeconds, 2) / 2.5
        return min(1 - exp(-elapsed / tau), 0.99)
    }

    /// Share of the captured audio that has been transcribed.
    func transcriptionProgress() -> Double? {
        guard let session else { return nil }
        let captured = session.capturedSeconds
        guard captured > 0.5 else { return nil }
        return min(session.transcribedSeconds / captured, 1)
    }

    private func learnLoadTime(_ duration: Duration) {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        if seconds < 3 {
            settings.warmLoadSeconds = settings.warmLoadSeconds * 0.7 + seconds * 0.3
        } else {
            settings.coldLoadSeconds = seconds
        }
    }

    private func releaseCleanupModel() {
        guard cleanupCheckedOut else { return }
        cleanupCheckedOut = false
        Task { await CleanupHost.shared.checkin() }
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

    // MARK: History

    private func saveRecord(_ record: TranscriptRecord) {
        do {
            _ = try history?.insert(record)
        } catch {
            show(Notice(kind: .error, text: "Couldn't save to History: \(error.localizedDescription)"), for: .seconds(4))
        }
    }

    private func saveFailure(error: Error, audioURL: URL?, seconds: Double) {
        let keptAudio = audioURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil }
        saveRecord(
            TranscriptRecord(
                kind: .dictation,
                sourceName: lastExternalApp?.localizedName,
                sourceBundleID: lastExternalApp?.bundleIdentifier,
                durationSeconds: seconds,
                rawText: "",
                finalText: "",
                asrModel: SpeechModel.displayName,
                status: .failed,
                error: error.localizedDescription,
                audioPath: keptAudio
            )
        )
    }

    private func observeStores() {
        if let history {
            Task { [weak self] in
                for await records in history.observeRecent(limit: 8) {
                    self?.recents = records
                }
            }
        }
        if let dictionaryStore {
            Task { [weak self] in
                for await entries in dictionaryStore.observeAll() {
                    self?.dictionary = entries
                }
            }
        }
    }

    private func pruneHistory() {
        let days = settings.historyRetentionDays
        guard days > 0, let history else { return }
        let now = Date()
        let paths = (try? history.audioPathsOlderThan(days: days, now: now)) ?? []
        _ = try? history.prune(olderThan: days, now: now)
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
    }

    /// Recordings left behind by a crash become failed History entries that can be retried.
    private func recoverOrphanedRecordings() {
        let fm = FileManager.default
        guard let history,
            let files = try? fm.contentsOfDirectory(at: Self.recordingsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let known = Set(((try? history.search("", limit: 10_000, offset: 0)) ?? []).compactMap(\.audioPath))
        for file in files where file.pathExtension == "caf" && !known.contains(file.path) {
            let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 16_000 else {
                try? fm.removeItem(at: file)
                continue
            }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            _ = try? history.insert(
                TranscriptRecord(
                    createdAt: date,
                    kind: .dictation,
                    durationSeconds: Double(size) / 32_000,
                    rawText: "",
                    finalText: "",
                    asrModel: SpeechModel.displayName,
                    status: .failed,
                    error: "Utter quit before this dictation was transcribed. Use Retry to transcribe the saved audio.",
                    audioPath: file.path
                )
            )
        }
    }

    private func deleteRecording(_ url: URL?) {
        guard let url, url.pathExtension == "caf" else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Notices and HUD

    func show(_ notice: Notice, for duration: Duration) {
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
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApp = app
        }
        Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: NSWorkspace.didActivateApplicationNotification) {
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    app.bundleIdentifier != Bundle.main.bundleIdentifier
                else { continue }
                self?.lastExternalApp = app
            }
        }
    }

    /// The paste goes to whichever window is selected when the text is ready. The one exception: if Utter is
    /// only active because its menu-bar popover was used (no Utter window selected), hand focus back to the app
    /// the user was working in so ⌘V doesn't land nowhere.
    private func returnFocusIfNeeded() async {
        guard NSApp.isActive, !windows.hasKeyWindow, let target = lastExternalApp, !target.isTerminated else { return }
        NSApp.yieldActivation(to: target)
        target.activate(from: .current, options: [])
        try? await Task.sleep(for: .milliseconds(200))
    }
}
