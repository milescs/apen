import KeyboardShortcuts
import SwiftUI
import UtterCore
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
            HStack {
                MicrophonePicker(model: model)
                Spacer()
                Button("Change shortcut…") { open(model.showSettings) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            HStack {
                ModePicker(model: model)
                Spacer()
                cleanupToggle
            }
            Divider()
            RecentList(model: model, isPresented: $isPresented)
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 360)
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
                Text(KeyboardShortcuts.getShortcut(for: .toggleRecording)?.description ?? "")
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

    private var cleanupToggle: some View {
        @Bindable var settings = model.settings
        return Toggle(isOn: $settings.cleanupEnabled) {
            Label("Clean up", systemImage: "sparkles")
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .disabled(model.models.cleanup != .ready)
        .help(model.models.cleanup == .ready
            ? "Tidy filler words and punctuation with the local LLM"
            : "Download the cleanup model in Settings › Models to enable")
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuRow(title: "Transcribe File…", symbol: "doc.badge.plus") { open(model.showFileTranscription) }
            MenuRow(title: "History…", symbol: "clock.arrow.circlepath") { open(model.showHistory) }
            MenuRow(title: "Dictionary…", symbol: "character.book.closed") { open(model.showDictionary) }
            MenuRow(title: "Settings…", symbol: "gearshape", shortcut: ",") { open(model.showSettings) }
            HStack {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Button("About") { open(model.showAbout) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .keyboardShortcut("q")
            }
            .padding(.top, 6)
        }
    }

    private func open(_ show: @escaping () -> Void) {
        isPresented = false
        show()
    }

    private var footer: String {
        guard SpeechModel.isDownloaded else { return "Speech model not downloaded" }
        return model.phase == .idle ? "Models load only while you dictate" : "\(SpeechModel.displayName) in use"
    }

    private var statusText: String {
        switch model.phase {
        case .idle: "Ready"
        case .recording: "Recording"
        case .processing: "Transcribing"
        case .cleaning: "Cleaning up"
        }
    }
}

private struct MenuRow: View {
    let title: String
    let symbol: String
    var shortcut: KeyEquivalent?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .modifier(OptionalShortcut(key: shortcut))
    }
}

private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key)
        } else {
            content
        }
    }
}

/// The most recent transcripts, each with a one-click Copy.
private struct RecentList: View {
    let model: AppModel
    @Binding var isPresented: Bool
    @State private var copiedID: Int64?
    @State private var expandedID: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
            }
            if model.recents.isEmpty {
                Text("Your dictations will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                // Only scroll when the list doesn't fit; otherwise the popover hugs its content.
                ViewThatFits(in: .vertical) {
                    rows
                    ScrollView { rows }
                }
                .frame(maxHeight: 320)
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 4) {
            ForEach(model.recents) { record in
                row(record)
            }
        }
    }

    private func row(_ record: TranscriptRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.status == .failed ? "Transcription failed — open History to retry" : record.finalText)
                    .font(.callout)
                    .lineLimit(expandedID == record.id ? 12 : 2)
                    .foregroundStyle(record.status == .failed ? .orange : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Text(record.createdAt, style: .relative)
                    Text("ago")
                    if let source = record.sourceName { Text("· \(source)").lineLimit(1) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy) { expandedID = expandedID == record.id ? nil : record.id }
            }
            Button {
                model.copy(record.finalText)
                copiedID = record.id
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    if copiedID == record.id { copiedID = nil }
                }
            } label: {
                Image(systemName: copiedID == record.id ? "checkmark" : "doc.on.doc")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .disabled(record.finalText.isEmpty)
        }
        .padding(6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Picks the default dictation mode; apps assigned to a mode switch to it automatically.
struct ModePicker: View {
    let model: AppModel

    var body: some View {
        Menu {
            ForEach(DictationMode.builtIn) { mode in
                Button {
                    model.selectMode(mode)
                } label: {
                    if mode.id == model.settings.selectedModeID {
                        Label(mode.name, systemImage: "checkmark")
                    } else {
                        Label(mode.name, systemImage: mode.symbol)
                    }
                }
                .help(mode.summary)
            }
            Divider()
            Text("Apps you assign to a mode switch to it automatically (Settings › Modes)")
        } label: {
            Label("Mode: \(model.selectedMode.name)", systemImage: model.selectedMode.symbol)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(model.selectedMode.summary)
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
        .fixedSize()
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
