import FluidAudio
import Foundation

/// The Parakeet Unified EN streaming model as stored by FluidAudio.
///
/// Models live in FluidAudio's default cache (`~/Library/Application Support/FluidAudio/Models/`)
/// because its vocabulary-boosting code resolves the CTC tokenizer from that location.
public enum SpeechModel {
    public static let displayName = "Parakeet Unified EN 0.6B"
    public static let identifier = "parakeet-unified-en-0.6b"

    /// Streaming context [70, 13, 13]: 5.6 s left, 1.04 s chunk, 1.04 s right — the best-WER streaming mode.
    public static let config = UnifiedConfig()
    public static let precision: UnifiedEncoderPrecision = .int8

    public static var directory: URL {
        cacheRoot.appendingPathComponent(Repo.parakeetUnified.folderName, isDirectory: true)
    }

    static var cacheRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    static var requiredFiles: [String] {
        [
            ModelNames.ParakeetUnified.streamingEncoderFile(precision: precision, contextSuffix: config.contextSuffix),
            ModelNames.ParakeetUnified.decoderFile,
            ModelNames.ParakeetUnified.jointDecisionFile,
            ModelNames.ParakeetUnified.vocab,
        ]
    }

    public static var isDownloaded: Bool {
        let fm = FileManager.default
        return requiredFiles.allSatisfy { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// Downloads (if needed) and loads the model once, which also triggers the first Neural Engine
    /// compile, then releases it. This is the only code path that touches the network.
    public static func download(progress: (@Sendable (ModelDownloadProgress) -> Void)? = nil) async throws {
        let manager = StreamingUnifiedAsrManager(config: config, encoderPrecision: precision)
        try await manager.loadModels(to: nil, configuration: nil) { update in
            progress?(ModelDownloadProgress(update))
        }
        await manager.cleanup()
    }

    public static func delete() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

/// Vocabulary-boosting CTC model (parakeet-ctc-110m), downloaded only when the dictionary asks for boosting.
public enum BoostModel {
    public static var directory: URL { CtcModels.defaultCacheDirectory(for: .ctc110m) }
    public static var isDownloaded: Bool { CtcModels.modelsExist(at: directory) }

    public static func download() async throws {
        _ = try await CtcModels.download(variant: .ctc110m)
    }
}

public struct ModelDownloadProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case listing
        case downloading(completedFiles: Int, totalFiles: Int)
        case compiling(String)
    }

    public let fraction: Double
    public let phase: Phase

    init(_ progress: DownloadProgress) {
        fraction = progress.fractionCompleted
        switch progress.phase {
        case .listing: phase = .listing
        case .downloading(let done, let total): phase = .downloading(completedFiles: done, totalFiles: total)
        case .compiling(let name): phase = .compiling(name)
        }
    }

    public var label: String {
        switch phase {
        case .listing: "Preparing download…"
        case .downloading(let done, let total): "Downloading \(done)/\(total) files — \(Int(fraction * 100))%"
        case .compiling: "Optimizing for the Neural Engine (first time only)…"
        }
    }
}
