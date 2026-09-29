import KeyboardShortcuts
import SwiftUI
import UtterEngines

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel("Utter")
    }

    private var symbol: String {
        switch model.phase {
        case .idle: "waveform"
        case .recording: "waveform.circle.fill"
        case .processing, .cleaning: "ellipsis.circle"
        }
    }
}

struct MenuBarView: View {
    let model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            recordButton
            MicrophonePicker(model: model)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("Utter").font(.headline)
            Spacer()
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var recordButton: some View {
        Button {
            isPresented = false
            model.toggleFromMenu()
        } label: {
            HStack {
                Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                Text(model.phase == .recording ? "Stop Dictation" : "Start Dictation")
                Spacer()
                Text(shortcutText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(model.phase == .processing || model.phase == .cleaning)
    }

    private var footer: some View {
        HStack {
            Text(SpeechModel.isDownloaded ? "\(SpeechModel.displayName) · loads only while dictating" : "Speech model not downloaded")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
    }

    private var statusText: String {
        switch model.phase {
        case .idle: "Ready"
        case .recording: "Recording"
        case .processing: "Transcribing"
        case .cleaning: "Cleaning up"
        }
    }

    private var shortcutText: String {
        KeyboardShortcuts.getShortcut(for: .toggleRecording)?.description ?? ""
    }
}

struct MicrophonePicker: View {
    let model: AppModel

    var body: some View {
        Menu {
            Button {
                model.selectMicrophone(uid: nil)
            } label: {
                checkmarked("System Default (\(model.defaultInputName))", model.settings.microphoneUID == nil)
            }
            if !model.inputDevices.isEmpty { Divider() }
            ForEach(model.inputDevices) { device in
                Button {
                    model.selectMicrophone(uid: device.uid)
                } label: {
                    checkmarked(device.name, model.settings.microphoneUID == device.uid)
                }
            }
        } label: {
            Label(model.selectedMicrophoneName, systemImage: "mic")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .help("Microphone used for dictation (doesn't change the Mac's input for other apps)")
    }

    @ViewBuilder
    private func checkmarked(_ title: String, _ isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}
