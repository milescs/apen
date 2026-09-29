import KeyboardShortcuts
import SwiftUI
import ApenCore
import ApenEngines

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModesSettings(model: model)
                .tabItem { Label("Modes", systemImage: "square.stack.3d.up") }
            ModelsSettings(model: model)
                .tabItem { Label("Models", systemImage: "cpu") }
            CleanupSettings(model: model)
                .tabItem { Label("Cleanup", systemImage: "sparkles") }
        }
        .padding(.top, 8)
        .frame(minWidth: 620, minHeight: 500)
    }
}

private struct GeneralSettings: View {
    let model: AppModel
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var canPaste = Permissions.canPostEvents

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Dictation") {
                KeyboardShortcuts.Recorder("Start / stop dictation:", name: .toggleRecording)
                Text("Tap to start and tap again to stop, or hold while you talk and release to stop. Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                MicrophonePicker(model: model)
                Toggle("Show live transcript in the recording panel", isOn: $settings.showLiveText)
                Toggle("Play start and stop sounds", isOn: $settings.playSounds)
                Picker("Stop automatically after", selection: $settings.maxRecordingMinutes) {
                    ForEach([10, 30, 60, 120], id: \.self) { Text("\($0) minutes").tag($0) }
                }
            }
            Section("Pasting") {
                Toggle("Paste into the focused text field", isOn: $settings.autoPaste)
                Toggle("Restore my clipboard afterwards", isOn: $settings.restoreClipboard)
                    .disabled(!settings.autoPaste)
                Toggle("Add a space after the text", isOn: $settings.trailingSpace)
                HStack {
                    Label(
                        canPaste ? "Accessibility allowed" : "Accessibility needed to paste automatically",
                        systemImage: canPaste ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(canPaste ? .green : .orange)
                    Spacer()
                    if !canPaste {
                        Button("Open Accessibility Settings") { Permissions.requestPostEvents() }
                    }
                }
            }
            Section("History") {
                Picker("Keep transcripts", selection: $settings.historyRetentionDays) {
                    Text("Forever").tag(0)
                    Text("90 days").tag(90)
                    Text("30 days").tag(30)
                    Text("7 days").tag(7)
                }
                Toggle("Keep audio recordings", isOn: $settings.keepRecordings)
                    .help("Recordings are always kept when a transcription fails, so it can be retried")
            }
            Section {
                Toggle("Open Apen at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LoginItem.set(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                canPaste = Permissions.canPostEvents
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct ModelsSettings: View {
    let model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Speech recognition") {
                ModelRow(
                    title: SpeechModel.displayName,
                    detail: "NVIDIA open weights · ≈600 MB · runs on the Neural Engine",
                    status: model.models.speech,
                    download: model.models.downloadSpeech,
                    delete: model.models.deleteSpeech
                )
                ModelRow(
                    title: "Vocabulary boost (Parakeet CTC 110M)",
                    detail: "≈100 MB · helps with dictionary names and jargon",
                    status: model.models.boost,
                    download: model.models.downloadSpeech,
                    delete: nil
                )
            }
            Section("Cleanup (optional)") {
                ModelRow(
                    title: CleanupModel.displayName,
                    detail: "Apache-2.0 open weights · 2.5 GB · runs on the GPU",
                    status: model.models.cleanup,
                    download: model.models.downloadCleanup,
                    delete: model.models.deleteCleanup
                )
            }
            Section {
                Picker("Keep models in memory after a dictation", selection: $settings.keepWarmSeconds) {
                    Text("No — free memory right away").tag(0)
                    Text("30 seconds").tag(30)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
                .onChange(of: settings.keepWarmSeconds) { model.applyKeepWarm() }
                Text("Models load when you start talking and are released when the text is delivered. Keeping them warm only speeds up back-to-back dictations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Memory")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.models.refresh() }
    }
}

private struct ModelRow: View {
    let title: String
    let detail: String
    let status: ModelManager.Status
    let download: () -> Void
    let delete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch status {
                case .ready:
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    if let delete {
                        Button("Delete", role: .destructive, action: delete).buttonStyle(.borderless)
                    }
                case .missing:
                    Button("Download", action: download)
                case .downloading:
                    ProgressView().controlSize(.small)
                case .failed:
                    Button("Retry Download", action: download)
                }
            }
            if case .downloading(let fraction, let label) = status {
                ProgressView(value: fraction) { Text(label).font(.caption) }
            }
            if case .failed(let message) = status {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

private struct CleanupSettings: View {
    let model: AppModel
    @State private var sample = "um so I was thinking that uh we should probably like refactor the login flow because you know it keeps timing out"
    @State private var output = ""
    @State private var isRunning = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Clean up dictations with the local LLM", isOn: $settings.cleanupEnabled)
                    .disabled(model.models.cleanup != .ready)
                Text("Removes filler words and false starts and fixes punctuation, without changing what you said. Adds about a second for short dictations; press ⌥Space while it runs to paste the text as is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.models.cleanup != .ready {
                    Text("Download the cleanup model in the Models tab first.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("Extra instructions for every mode") {
                TextField("Optional", text: $settings.cleanupInstructions, prompt: Text("e.g. Use American spelling."), axis: .vertical)
                    .lineLimit(2...5)
                Text("Mode-specific instructions are in the Modes tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Test") {
                TextField("Sample dictation", text: $sample, axis: .vertical)
                    .lineLimit(2...5)
                HStack {
                    Button(isRunning ? "Cleaning…" : "Clean Up Sample (\(model.selectedMode.cleans ? model.selectedMode.name : "General") mode)") { runTest() }
                        .disabled(isRunning || model.models.cleanup != .ready)
                    if isRunning { ProgressView().controlSize(.small) }
                }
                if !output.isEmpty {
                    Text(output).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func runTest() {
        isRunning = true
        output = ""
        let text = model.matcher.normalize(sample)
        let terms = model.matcher.keepVerbatimTerms
        let mode = model.selectedMode.cleans ? model.selectedMode : .general
        let instructions = model.settings.instructions(for: mode)
        let matcher = model.matcher
        Task {
            do {
                try await CleanupHost.shared.checkout()
                let result = await CleanupEngine().clean(text, keepVerbatim: terms, extraInstructions: instructions, mode: mode)
                await CleanupHost.shared.checkin()
                output = matcher.expand(result.text) + (result.fellBack ? "\n\n(Cleanup was rejected by the safety check; this is the original text.)" : "")
            } catch {
                output = error.localizedDescription
            }
            isRunning = false
        }
    }
}

private struct ModesSettings: View {
    let model: AppModel
    @State private var selectedID: String? = DictationMode.defaultModeID

    private var selected: DictationMode {
        DictationMode.mode(id: selectedID ?? "") ?? model.selectedMode
    }

    var body: some View {
        HStack(spacing: 0) {
            List(DictationMode.builtIn, selection: $selectedID) { mode in
                HStack {
                    Label(mode.name, systemImage: mode.symbol)
                    Spacer()
                    if mode.id == model.settings.selectedModeID {
                        Text("Default").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(mode.id)
            }
            .frame(width: 180)
            ModeDetail(model: model, mode: selected)
        }
        .onAppear { selectedID = model.settings.selectedModeID }
    }
}

private struct ModeDetail: View {
    let model: AppModel
    let mode: DictationMode
    @State private var selectedApp: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Text(mode.summary)
                if mode.id == settings.selectedModeID {
                    Label("Default mode", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Use as Default Mode") { model.selectMode(mode) }
                }
                if !mode.cleans {
                    Text("Raw mode never runs the cleanup model; only your dictionary is applied.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Switch to \(mode.name) automatically in") {
                let apps = settings.apps(for: mode)
                if apps.isEmpty {
                    Text("No apps").foregroundStyle(.secondary)
                }
                List(apps, id: \.self, selection: $selectedApp) { bundleID in
                    AppRow(bundleID: bundleID)
                }
                .frame(minHeight: 120)
                HStack {
                    Button("Add App…") { addApp() }
                    Button("Remove") {
                        if let selectedApp { setApps(apps.filter { $0 != selectedApp }) }
                        selectedApp = nil
                    }
                    .disabled(selectedApp == nil)
                    Spacer()
                    Button("Restore Defaults") { settings.modeApps[mode.id] = nil }
                        .disabled(settings.modeApps[mode.id] == nil)
                }
            }
            if mode.cleans {
                Section("Extra instructions for \(mode.name)") {
                    TextField(
                        "Optional",
                        text: Binding(
                            get: { settings.modeInstructions[mode.id] ?? "" },
                            set: { settings.modeInstructions[mode.id] = $0 }
                        ),
                        prompt: Text(mode.id == "coding" ? "e.g. My stack is Swift and TypeScript." : "Optional"),
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setApps(_ apps: [String]) {
        model.settings.modeApps[mode.id] = apps
    }

    /// Adds an app to this mode and removes it from any other mode, so each app has one mode.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose an app that should use \(mode.name) mode"
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        for other in DictationMode.builtIn where other.id != mode.id {
            let otherApps = model.settings.apps(for: other)
            if otherApps.contains(bundleID) {
                model.settings.modeApps[other.id] = otherApps.filter { $0 != bundleID }
            }
        }
        let apps = model.settings.apps(for: mode)
        if !apps.contains(bundleID) { setApps(apps + [bundleID]) }
    }
}

private struct AppRow: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            } else {
                Image(systemName: "app.dashed").frame(width: 18, height: 18)
                Text(bundleID).foregroundStyle(.secondary)
            }
        }
        .tag(bundleID)
    }
}
