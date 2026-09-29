import Foundation
import Observation
import UtterEngines

/// Download state for the three models, shared by onboarding and Settings.
@MainActor
@Observable
final class ModelManager {
    enum Status: Equatable {
        case missing
        case downloading(Double, String)
        case ready
        case failed(String)

        var isBusy: Bool {
            if case .downloading = self { return true }
            return false
        }
    }

    private(set) var speech: Status = SpeechModel.isDownloaded ? .ready : .missing
    private(set) var boost: Status = BoostModel.isDownloaded ? .ready : .missing
    private(set) var cleanup: Status = CleanupModel.isDownloaded ? .ready : .missing

    @ObservationIgnored private var cleanupTask: Task<Void, Never>?

    func refresh() {
        if !speech.isBusy { speech = SpeechModel.isDownloaded ? .ready : .missing }
        if !boost.isBusy { boost = BoostModel.isDownloaded ? .ready : .missing }
        if !cleanup.isBusy { cleanup = CleanupModel.isDownloaded ? .ready : .missing }
    }

    /// Downloads Parakeet (≈600 MB) and compiles it for the Neural Engine, then the vocabulary model (≈100 MB).
    func downloadSpeech() {
        guard !speech.isBusy else { return }
        speech = .downloading(0, "Starting…")
        Task {
            do {
                try await SpeechModel.download { progress in
                    Task { @MainActor in if self.speech.isBusy { self.speech = .downloading(progress.fraction, progress.label) } }
                }
                speech = .ready
                boost = .downloading(0, "Downloading vocabulary model…")
                try await BoostModel.download()
                boost = .ready
            } catch {
                if !SpeechModel.isDownloaded { speech = .failed(error.localizedDescription) }
                if !BoostModel.isDownloaded { boost = .failed(error.localizedDescription) }
            }
        }
    }

    /// Downloads the 2.5 GB cleanup model, verifies it, and warms it up once so the first real cleanup is fast.
    func downloadCleanup() {
        guard !cleanup.isBusy else { return }
        cleanup = .downloading(0, "Starting…")
        cleanupTask = Task {
            do {
                try await CleanupModel.download { fraction in
                    Task { @MainActor in
                        if self.cleanup.isBusy { self.cleanup = .downloading(fraction, "Downloading \(Int(fraction * 100))% of 2.5 GB") }
                    }
                }
                cleanup = .downloading(1, "Preparing the model (first time only)…")
                try? await CleanupHost.shared.checkout()
                await CleanupHost.shared.checkin()
                cleanup = .ready
            } catch is CancellationError {
                cleanup = CleanupModel.isDownloaded ? .ready : .missing
            } catch {
                cleanup = .failed(error.localizedDescription)
            }
        }
    }

    func cancelCleanupDownload() {
        cleanupTask?.cancel()
    }

    func deleteSpeech() {
        try? SpeechModel.delete()
        refresh()
    }

    func deleteCleanup() {
        try? CleanupModel.delete()
        refresh()
    }
}
