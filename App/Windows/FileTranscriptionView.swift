import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ApenCore
import ApenEngines

/// Runs file transcriptions and keeps the latest result for the window.
@MainActor
@Observable
final class FileTranscriptionModel {
    enum State: Equatable {
        case idle
        case working(fileName: String, progress: Double, stage: String)
        case done(TranscriptRecord)
        case failed(String)
    }

    var state: State = .idle
    var cleanWithLLM = false
    @ObservationIgnored weak var owner: AppModel?
    @ObservationIgnored private let history: HistoryStore?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(history: HistoryStore?) {
        self.history = history
    }

    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio or video file to transcribe"
        if panel.runModal() == .OK, let url = panel.url {
            transcribe(url)
        }
    }

    func transcribe(_ url: URL) {
        guard !isWorking else { return }
        guard SpeechModel.isDownloaded else {
            state = .failed("Download the speech model first (Settings › Models).")
            return
        }
        let name = url.lastPathComponent
        let terms = owner?.boostTerms ?? []
        let matcher = owner?.matcher ?? DictionaryMatcher(entries: [])
        let mode = owner.map { $0.selectedMode.cleans ? $0.selectedMode : .general } ?? .general
        let wantsCleanup = cleanWithLLM && CleanupModel.isDownloaded
        let instructions = owner?.settings.instructions(for: mode)
        let history = history
        state = .working(fileName: name, progress: 0, stage: "Reading audio…")

        // The model lives as long as the app, so strong captures are fine here.
        task = Task {
            let started = Date()
            do {
                let result = try await FileTranscriptionJob.run(url: url, boostTerms: terms) { fraction in
                    Task { @MainActor in
                        guard case .working = self.state else { return }
                        self.state = .working(fileName: name, progress: fraction, stage: "Transcribing…")
                    }
                }
                try Task.checkCancellation()
                var working = matcher.normalize(result.text)
                var cleaned: String?
                if wantsCleanup, !TextFinisher.isEffectivelyEmpty(working) {
                    self.state = .working(fileName: name, progress: 0, stage: "Cleaning up with the local LLM…")
                    try await CleanupHost.shared.checkout()
                    let output = await CleanupEngine().clean(
                        working, keepVerbatim: matcher.keepVerbatimTerms, extraInstructions: instructions, mode: mode
                    ) { fraction in
                        Task { @MainActor in
                            if case .working = self.state {
                                self.state = .working(fileName: name, progress: fraction, stage: "Cleaning up with the local LLM…")
                            }
                        }
                    }
                    await CleanupHost.shared.checkin()
                    if !output.fellBack {
                        working = output.text
                        cleaned = output.text
                    }
                }
                let finalText = TextFinisher.finish(matcher.expand(working), trailingSpace: false)
                let record = TranscriptRecord(
                    kind: .file,
                    sourceName: name,
                    durationSeconds: result.audioSeconds,
                    rawText: result.text,
                    cleanedText: cleaned,
                    finalText: finalText,
                    asrModel: SpeechModel.displayName,
                    cleanupModel: cleaned == nil ? nil : CleanupModel.displayName,
                    processingMilliseconds: Int(Date().timeIntervalSince(started) * 1000)
                )
                let saved = (try? history?.insert(record)) ?? record
                self.state = .done(saved)
            } catch is CancellationError {
                self.state = .idle
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        Task { await CleanupHost.shared.cancelInFlight() }
    }
}

struct FileTranscriptionView: View {
    let model: AppModel
    @State private var isTargeted = false
    @State private var copied = false

    private var files: FileTranscriptionModel { model.files }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            dropZone
            Toggle("Clean up with the local LLM in \(model.selectedMode.cleans ? model.selectedMode.name : "General") mode (slower for long files)", isOn: Binding(
                get: { files.cleanWithLLM },
                set: { files.cleanWithLLM = $0 }
            ))
            .disabled(!CleanupModel.isDownloaded || files.isWorking)
            content
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Drop an audio or video file here")
                .font(.headline)
            Text("m4a, mp3, wav, aiff, caf, flac, mp4, mov — and ogg/webm when ffmpeg is installed")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Choose File…") { files.chooseFile() }
                .disabled(files.isWorking)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary.opacity(0.5))
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            files.transcribe(url)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    @ViewBuilder
    private var content: some View {
        switch files.state {
        case .idle:
            Spacer()
        case .working(let name, let progress, let stage):
            VStack(alignment: .leading, spacing: 8) {
                Text(name).font(.headline)
                ProgressView(value: progress) {
                    HStack {
                        Text(stage)
                        Spacer()
                        Text("\(Int(progress * 100))%").monospacedDigit()
                    }
                }
                Button("Cancel") { files.cancel() }
            }
            Spacer()
        case .done(let record):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(record.sourceName ?? "Transcript").font(.headline)
                    Text("\(Duration.seconds(record.durationSeconds).formatted(.time(pattern: .hourMinuteSecond))) of audio")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.copy(record.finalText)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button("Save as Text…") { save(record) }
                    Button("Open History") { model.showHistory() }
                }
                ScrollView {
                    Text(record.finalText.isEmpty ? "No speech found in this file." : record.finalText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Spacer()
        }
    }

    private func save(_ record: TranscriptRecord) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let base = (record.sourceName as NSString?)?.deletingPathExtension ?? "Transcript"
        panel.nameFieldStringValue = "\(base).txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? record.finalText.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
