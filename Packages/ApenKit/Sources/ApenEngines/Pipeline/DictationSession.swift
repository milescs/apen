import Foundation

import Synchronization

/// One dictation: microphone capture feeding the live transcriber until `stop()` or `cancel()`.
///
/// The speech model starts loading the moment the session starts and is released as soon as the
/// session ends, so it only occupies memory while you are dictating.
public actor DictationSession {
    public enum AudioSource: Sendable {
        case microphone(deviceUID: String?)
        /// Plays a file into the session as if it were the microphone, at `speed`× real time
        /// (used by the automated end-to-end paste test).
        case file(URL, speed: Double)
    }

    public struct StartInfo: Sendable {
        public let deviceName: String
        public let usedFallbackDevice: Bool
    }

    public struct Result: Sendable {
        public let text: String
        public let recordingURL: URL?
        public let audioSeconds: Double
        /// Time from stop to final text.
        public let finishSeconds: Double
    }

    private let recorder = MicrophoneRecorder()
    private let fileFeeder = FileAudioFeeder()
    private nonisolated let transcriber: LiveTranscriber
    private let recordingURL: URL?
    private var consumer: Task<Void, Error>?
    private var interruptionWatcher: Task<Void, Never>?
    private var isRunning = false

    /// Running transcript for the HUD.
    public nonisolated let partials: AsyncStream<String>
    /// Fires once if the microphone disappears or reconfigures mid-recording.
    public nonisolated let interruptions: AsyncStream<Void>
    private let interruptionContinuation: AsyncStream<Void>.Continuation

    public init(recordingURL: URL?, boostTerms: [BoostTerm] = [], host: SpeechModelHost = .shared) {
        self.recordingURL = recordingURL
        transcriber = LiveTranscriber(host: host, boostTerms: boostTerms)
        partials = transcriber.partials
        (interruptions, interruptionContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Current input level in 0...1; callable from any thread.
    public nonisolated var level: Float { max(recorder.level, fileFeeder.level) }

    /// Seconds captured so far; callable from any thread.
    public nonisolated var capturedSeconds: Double { recorder.capturedSeconds + fileFeeder.capturedSeconds }

    /// Seconds already transcribed; with `capturedSeconds` this gives the catch-up percentage.
    public nonisolated var transcribedSeconds: Double { transcriber.transcribedSeconds }

    public func start(deviceUID: String?) async throws -> StartInfo {
        try await start(source: .microphone(deviceUID: deviceUID))
    }

    public func start(source: AudioSource) async throws -> StartInfo {
        await transcriber.start()
        let started: MicrophoneRecorder.Started
        do {
            switch source {
            case .microphone(let deviceUID):
                started = try recorder.start(deviceUID: deviceUID, recordingURL: recordingURL)
            case .file(let url, let speed):
                started = try await fileFeeder.start(url: url, speed: speed)
            }
        } catch {
            await transcriber.cancel()
            throw error
        }
        isRunning = true

        let transcriber = transcriber
        consumer = Task {
            for await chunk in started.chunks {
                try await transcriber.append(chunk)
            }
        }
        let interruptionContinuation = interruptionContinuation
        interruptionWatcher = Task {
            for await _ in started.interruptions {
                interruptionContinuation.yield()
                break
            }
        }
        return StartInfo(deviceName: started.deviceName, usedFallbackDevice: started.usedFallbackDevice)
    }

    /// For `.file` sources: resolves once the whole file has been fed.
    public func waitForFileSourceToFinish() async {
        await fileFeeder.waitUntilFinished()
    }

    /// Resolves once the model is loaded (immediately when it was kept warm).
    public func waitUntilModelReady() async throws {
        try await transcriber.waitUntilReady()
    }

    /// Stops the microphone, transcribes the remaining audio and releases the model.
    public func stop() async throws -> Result {
        guard isRunning else { throw SpeechEngineError.notStarted }
        isRunning = false
        let audioSeconds = capturedSeconds
        recorder.stop()
        fileFeeder.stop()
        interruptionWatcher?.cancel()
        interruptionContinuation.finish()
        let stopTime = Date()
        do {
            try await consumer?.value
        } catch {
            await transcriber.cancel()
            throw error
        }
        let text = try await transcriber.finish()
        return Result(
            text: text,
            recordingURL: recordingURL,
            audioSeconds: audioSeconds,
            finishSeconds: Date().timeIntervalSince(stopTime)
        )
    }

    /// Stops the microphone, discards the transcript and releases the model.
    public func cancel() async {
        isRunning = false
        recorder.stop()
        fileFeeder.stop()
        interruptionWatcher?.cancel()
        interruptionContinuation.finish()
        consumer?.cancel()
        await transcriber.cancel()
    }
}

/// Streams a decoded file in 100 ms chunks at a chosen speed, like a microphone would.
final class FileAudioFeeder: @unchecked Sendable {
    private let levelBits = Atomic<UInt32>(0)
    private let frames = Atomic<Int>(0)
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<[Float]>.Continuation?

    var level: Float { Float(bitPattern: levelBits.load(ordering: .relaxed)) }
    var capturedSeconds: Double { Double(frames.load(ordering: .relaxed)) / LiveTranscriber.sampleRate }

    func start(url: URL, speed: Double) async throws -> MicrophoneRecorder.Started {
        let samples = try await AudioFileDecoder.decode(url)
        let (chunks, continuation) = AsyncStream.makeStream(of: [Float].self)
        let (interruptions, interruptionContinuation) = AsyncStream.makeStream(of: Void.self)
        interruptionContinuation.finish()
        lock.withLock { self.continuation = continuation }
        let chunkSize = Int(LiveTranscriber.sampleRate / 10)
        task = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            var offset = 0
            while offset < samples.count, !Task.isCancelled {
                let end = min(offset + chunkSize, samples.count)
                let chunk = Array(samples[offset..<end])
                let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
                self?.levelBits.store(min(max((20 * log10(max(rms, 0.000_01)) + 50) / 50, 0), 1).bitPattern, ordering: .relaxed)
                self?.frames.add(chunk.count, ordering: .relaxed)
                continuation.yield(chunk)
                offset = end
                let due = Double(offset) / LiveTranscriber.sampleRate / max(speed, 0.01)
                try? await Task.sleep(until: start + .seconds(due), clock: clock)
            }
            self?.levelBits.store(0, ordering: .relaxed)
        }
        return MicrophoneRecorder.Started(
            chunks: chunks, interruptions: interruptions, deviceName: url.lastPathComponent, usedFallbackDevice: false
        )
    }

    func waitUntilFinished() async {
        await task?.value
    }

    func stop() {
        task?.cancel()
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }
}
