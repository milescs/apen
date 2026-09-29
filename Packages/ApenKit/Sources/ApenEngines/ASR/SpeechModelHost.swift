import FluidAudio
import Foundation

/// A dictionary term the speech model should be biased toward.
public struct BoostTerm: Sendable, Hashable {
    public let text: String
    public let aliases: [String]

    public init(text: String, aliases: [String] = []) {
        self.text = text
        self.aliases = aliases
    }
}

/// Owns loaded speech models so they exist only while a session needs them.
///
/// `checkout` loads a model at the start of a recording or file job; `checkin` frees it right away,
/// or keeps one idle copy for `keepWarm` so back-to-back dictations skip the load.
public actor SpeechModelHost {
    public static let shared = SpeechModelHost()

    private var idle: StreamingUnifiedAsrManager?
    private var idleTerms: [BoostTerm] = []
    private var unloadTask: Task<Void, Never>?
    private var activeCount = 0
    private var keepWarm: Duration = .zero

    public init() {}

    /// True while any model is in memory (active or kept warm).
    public var isLoaded: Bool { activeCount > 0 || idle != nil }

    public func setKeepWarm(_ duration: Duration) {
        keepWarm = max(.zero, duration)
        if keepWarm == .zero { unloadIdle() }
    }

    public func checkout(boostTerms: [BoostTerm]) async throws -> StreamingUnifiedAsrManager {
        unloadTask?.cancel()
        unloadTask = nil
        activeCount += 1

        if let warm = idle {
            idle = nil
            if idleTerms == boostTerms {
                try? await warm.reset()
                return warm
            }
            await warm.cleanup()
        }

        let manager = StreamingUnifiedAsrManager(config: SpeechModel.config, encoderPrecision: SpeechModel.precision)
        do {
            guard SpeechModel.isDownloaded else { throw SpeechEngineError.modelMissing }
            try await manager.loadModels(from: SpeechModel.directory)
            if !boostTerms.isEmpty, BoostModel.isDownloaded {
                let ctcModels = try await CtcModels.loadDirect(from: BoostModel.directory)
                let context = CustomVocabularyContext(
                    terms: boostTerms.map { CustomVocabularyTerm(text: $0.text, aliases: $0.aliases.isEmpty ? nil : $0.aliases) }
                )
                // Parakeet Unified writes inverse-text-normalized output, so keep FluidAudio's ITN
                // similarity floors, and turn the spotter rescue off: it over-fires on short acronyms.
                let rescorer = VocabularyRescorer.Config(
                    spotterRescueMinSimilarity: 0.30,
                    spotterRescueMultiWordMinSimilarity: 0.50,
                    spotterRescueEnabled: false
                )
                try await manager.configureVocabularyBoosting(vocabulary: context, ctcModels: ctcModels, config: rescorer)
            }
        } catch {
            activeCount -= 1
            await manager.cleanup()
            throw error
        }
        return manager
    }

    public func checkin(_ manager: StreamingUnifiedAsrManager, boostTerms: [BoostTerm]) async {
        activeCount = max(0, activeCount - 1)
        guard keepWarm > .zero, idle == nil else {
            await manager.cleanup()
            return
        }
        try? await manager.reset()
        idle = manager
        idleTerms = boostTerms
        let delay = keepWarm
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.unloadIdle()
        }
    }

    public func unloadIdle() {
        unloadTask?.cancel()
        unloadTask = nil
        guard let warm = idle else { return }
        idle = nil
        Task { await warm.cleanup() }
    }
}

public enum SpeechEngineError: LocalizedError {
    case modelMissing
    case notStarted

    public var errorDescription: String? {
        switch self {
        case .modelMissing: "The speech model isn't downloaded yet. Open Apen's Settings › Models to download it."
        case .notStarted: "The transcriber was used before it started."
        }
    }
}
