@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Captures microphone audio as 16 kHz mono Float32 chunks and writes it to a crash-safe file.
///
/// A fresh record-only `AVAudioEngine` is built for every recording and discarded on stop, so the
/// system's microphone indicator turns off as soon as the recording ends.
public final class MicrophoneRecorder: @unchecked Sendable {
    public struct Started: Sendable {
        /// Converted audio, in capture order.
        public let chunks: AsyncStream<[Float]>
        /// Fires when the input device disappears or changes configuration mid-recording.
        public let interruptions: AsyncStream<Void>
        public let deviceName: String
        /// True when the chosen device wasn't available and the system default was used instead.
        public let usedFallbackDevice: Bool
    }

    public static let sampleRate: Double = 16_000

    // start()/stop() are called serially by the owning session.
    private var engine: AVAudioEngine?
    private var processor: TapProcessor?
    private var observer: NSObjectProtocol?
    private var interruptionContinuation: AsyncStream<Void>.Continuation?
    private let meters = RecorderMeters()

    public init() {}

    /// Input level in 0...1 (-50 dBFS…0 dBFS), safe to read from any thread.
    public var level: Float { Float(bitPattern: meters.levelBits.load(ordering: .relaxed)) }

    /// Seconds of audio captured so far.
    public var capturedSeconds: Double { Double(meters.frames.load(ordering: .relaxed)) / Self.sampleRate }

    public func start(deviceUID: String?, recordingURL: URL?) throws -> Started {
        stop()
        meters.frames.store(0, ordering: .relaxed)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        var usedFallback = false
        var deviceName = AudioInputDevices.defaultInput()?.name ?? "Default input"

        if let deviceUID {
            if let device = AudioInputDevices.all().first(where: { $0.uid == deviceUID }), let unit = input.audioUnit {
                var deviceID = device.id
                let status = AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)
                )
                if status == noErr {
                    deviceName = device.name
                } else {
                    usedFallback = true
                }
            } else {
                usedFallback = true
            }
        }

        let tapFormat = input.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw MicrophoneRecorderError.noInput
        }
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false
        )!
        guard let converter = AVAudioConverter(from: tapFormat, to: outputFormat) else {
            throw MicrophoneRecorderError.unsupportedFormat
        }
        converter.downmix = true

        var file: AVAudioFile?
        if let recordingURL {
            try FileManager.default.createDirectory(
                at: recordingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            file = try AVAudioFile(
                forWriting: recordingURL,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: Self.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        }

        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: [Float].self)
        let (interruptions, interruptionContinuation) = AsyncStream.makeStream(of: Void.self)
        let processor = TapProcessor(
            converter: converter, outputFormat: outputFormat, file: file,
            continuation: chunkContinuation, meters: meters
        )
        installTap(on: input, format: tapFormat, processor: processor)

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            interruptionContinuation.yield()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            chunkContinuation.finish()
            interruptionContinuation.finish()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            throw error
        }

        self.engine = engine
        self.processor = processor
        self.interruptionContinuation = interruptionContinuation
        return Started(
            chunks: chunks, interruptions: interruptions,
            deviceName: deviceName, usedFallbackDevice: usedFallback
        )
    }

    /// Stops capture, closes the file and finishes the chunk stream. Idempotent.
    public func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        processor?.finish()
        processor = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        interruptionContinuation?.finish()
        interruptionContinuation = nil
        meters.levelBits.store(0, ordering: .relaxed)
    }

    /// Built here (nonisolated) so the tap closure never inherits main-actor isolation, which would trap
    /// at runtime on the audio thread under Swift 6.
    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat, processor: TapProcessor) {
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            processor.process(buffer)
        }
    }
}

public enum MicrophoneRecorderError: LocalizedError {
    case noInput
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .noInput: "No microphone is available."
        case .unsupportedFormat: "The microphone's audio format isn't supported."
        }
    }
}

/// Level and progress shared between the tap thread and readers on any thread.
private final class RecorderMeters: Sendable {
    let levelBits = Atomic<UInt32>(0)
    let frames = Atomic<Int>(0)
}

/// Runs on the tap thread only (plus `finish()` after the tap is removed).
private final class TapProcessor: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private var file: AVAudioFile?
    private let continuation: AsyncStream<[Float]>.Continuation
    private let meters: RecorderMeters
    private let lock = NSLock()
    private var finished = false

    init(
        converter: AVAudioConverter, outputFormat: AVAudioFormat, file: AVAudioFile?,
        continuation: AsyncStream<[Float]>.Continuation, meters: RecorderMeters
    ) {
        self.converter = converter
        self.outputFormat = outputFormat
        self.file = file
        self.continuation = continuation
        self.meters = meters
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, converted.frameLength > 0, let channel = converted.floatChannelData?[0] else { return }

        let count = Int(converted.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channel, count: count))
        try? file?.write(from: converted)

        var sumSquares: Float = 0
        for sample in samples { sumSquares += sample * sample }
        let rms = (sumSquares / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        let level = min(max((decibels + 50) / 50, 0), 1)
        meters.levelBits.store(level.bitPattern, ordering: .relaxed)
        meters.frames.add(count, ordering: .relaxed)
        continuation.yield(samples)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        file?.close()
        file = nil
        continuation.finish()
    }
}
