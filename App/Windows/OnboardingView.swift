import AppKit
import KeyboardShortcuts
import SwiftUI
import ApenEngines

/// First-run checklist: permissions, models, shortcut, and a place to try it.
struct OnboardingView: View {
    let model: AppModel
    @State private var hasMicrophone = Permissions.hasMicrophone
    @State private var canPaste = Permissions.canPostEvents
    @State private var superwhisperRunning = false
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var tryText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Welcome to Apen").font(.largeTitle.bold())
                        Text("Dictate anywhere with ⌥Space. Everything runs on this Mac with open-weight models.")
                            .foregroundStyle(.secondary)
                    }
                }

                Step(number: 1, title: "Microphone", done: hasMicrophone) {
                    Text("Apen only listens while you dictate.")
                    if !hasMicrophone {
                        Button("Allow Microphone") {
                            Task {
                                hasMicrophone = await Permissions.requestMicrophone()
                                if !hasMicrophone { Permissions.openMicrophoneSettings() }
                            }
                        }
                    }
                }

                Step(number: 2, title: "Accessibility (to paste for you)", done: canPaste) {
                    Text("Lets Apen press ⌘V in the app you're typing in. Turn Apen on under Privacy & Security › Accessibility.")
                    if !canPaste {
                        Button("Open Accessibility Settings") { Permissions.requestPostEvents() }
                    }
                }

                Step(number: 3, title: "Speech model", done: model.models.speech == .ready) {
                    Text("\(SpeechModel.displayName) — about 600 MB, downloaded once. The first setup takes about 20 seconds.")
                    downloadControls(model.models.speech, action: model.models.downloadSpeech)
                }

                Step(number: 4, title: "Cleanup model (optional)", done: model.models.cleanup == .ready) {
                    Text("\(CleanupModel.displayName) — 2.5 GB. Tidies filler words and punctuation when cleanup is on.")
                    downloadControls(model.models.cleanup, action: model.models.downloadCleanup)
                }

                Step(number: 5, title: "Shortcut", done: !superwhisperRunning) {
                    KeyboardShortcuts.Recorder("Start / stop:", name: .toggleRecording)
                    Text("Tap to toggle, or hold while you talk. Esc cancels.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #if !APPSTORE
                    if superwhisperRunning {
                        HStack {
                            Label("Superwhisper is running and also uses ⌥Space.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Button("Quit Superwhisper") { quitSuperwhisper() }
                        }
                    }
                    #endif
                    Toggle("Open Apen at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in
                            try? LoginItem.set(enabled)
                            launchAtLogin = LoginItem.isEnabled
                        }
                }

                Step(number: 6, title: "Try it", done: !tryText.isEmpty) {
                    Text("Click in the box, press ⌥Space, say a sentence, and press ⌥Space again.")
                    TextEditor(text: $tryText)
                        .font(.body)
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack {
                    Spacer()
                    Button("Done") { model.windows.close(.onboarding) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(28)
        }
        .task {
            while !Task.isCancelled {
                hasMicrophone = Permissions.hasMicrophone
                canPaste = Permissions.canPostEvents
                superwhisperRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.superduper.superwhisper").isEmpty
                model.models.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private func downloadControls(_ status: ModelManager.Status, action: @escaping () -> Void) -> some View {
        switch status {
        case .ready:
            EmptyView()
        case .missing:
            Button("Download", action: action)
        case .downloading(let fraction, let label):
            ProgressView(value: fraction) { Text(label).font(.caption) }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
            Button("Retry", action: action)
        }
    }

    private func quitSuperwhisper() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.superduper.superwhisper") {
            app.terminate()
        }
    }
}

private struct Step<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.25)).frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption.bold())
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content
            }
            Spacer(minLength: 0)
        }
    }
}
