@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// One transcription session: feed 16 kHz mono audio as it arrives, then `finish()`.
///
/// The model loads in the background as soon as the session starts; audio that arrives first is
/// buffered and processed once the model is ready. All Core ML work goes through `CoreMLGate`.
public actor LiveTranscriber {
    public static let sampleRate: Double = 16_000

    private let host: SpeechModelHost
    private let gate: CoreMLGate
    private let boostTerms: [BoostTerm]
    private var loadTask: Task<StreamingUnifiedAsrManager, Error>?
    private var manager: StreamingUnifiedAsrManager?
    private var lastPartial = ""
    private var isClosed = false
    private var isPrimed = false
    private let partialContinuation: AsyncStream<String>.Continuation

    /// Running transcript, published after each processing step while audio streams in.
    public nonisolated let partials: AsyncStream<String>

    public init(host: SpeechModelHost = .shared, gate: CoreMLGate = .shared, boostTerms: [BoostTerm] = []) {
        self.host = host
        self.gate = gate
        self.boostTerms = boostTerms
        (partials, partialContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Starts loading the model. Safe to call more than once.
    public func start() {
        guard loadTask == nil else { return }
        let host = host
        let terms = boostTerms
        loadTask = Task { try await host.checkout(boostTerms: terms) }
    }

    /// Waits for the model, e.g. to report "Preparing model…" separately from streaming.
    public func waitUntilReady() async throws {
        _ = try await readyManager()
    }

    /// Appends audio and transcribes every complete chunk it makes available.
    public func append(_ samples: [Float]) async throws {
        guard !samples.isEmpty, !isClosed else { return }
        let manager = try await readyManager()
        if !isPrimed {
            // The streaming model drops a word that starts on the very first sample; a short lead-in of
            // silence (≥ 0.1 s measured) avoids that.
            isPrimed = true
            try await manager.appendAudio(Self.makeBuffer([Float](repeating: 0, count: Int(Self.sampleRate * 0.3))))
        }
        try await manager.appendAudio(Self.makeBuffer(samples))
        await gate.acquire()
        do {
            try await manager.processBufferedAudio()
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
        let partial = await manager.getPartialTranscript()
        if partial != lastPartial {
            lastPartial = partial
            partialContinuation.yield(partial)
        }
    }

    /// Flushes the remaining audio and returns the final transcript, then releases the model.
    public func finish() async throws -> String {
        let manager = try await readyManager()
        isClosed = true
        partialContinuation.finish()
        await gate.acquire()
        let text: String
        do {
            text = try await manager.finish()
            await gate.release()
        } catch {
            await gate.release()
            await release()
            throw error
        }
        await release()
        return text
    }

    /// Discards the session and releases the model.
    public func cancel() async {
        isClosed = true
        partialContinuation.finish()
        if manager == nil, let loadTask {
            // Let an in-flight load finish so its model is released rather than leaked.
            manager = try? await loadTask.value
        }
        await release()
    }

    private func readyManager() async throws -> StreamingUnifiedAsrManager {
        if let manager { return manager }
        guard let loadTask else { throw SpeechEngineError.notStarted }
        let loaded = try await loadTask.value
        manager = loaded
        return loaded
    }

    private func release() async {
        loadTask = nil
        guard let manager else { return }
        self.manager = nil
        await host.checkin(manager, boostTerms: boostTerms)
    }

    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
    )!

    private static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
