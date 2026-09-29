@preconcurrency import AVFoundation
import Foundation

/// Decodes audio or video files to 16 kHz mono Float32 samples.
///
/// Audio containers go through AVAudioFile; video containers (and anything AVAudioFile rejects) go
/// through AVAssetReader. Formats AVFoundation can't read (ogg, opus, webm, mkv) fall back to ffmpeg
/// when it is installed.
public enum AudioFileDecoder {
    public static let sampleRate: Double = 16_000

    public static func decode(_ url: URL) async throws -> [Float] {
        if let samples = try? decodeWithAudioFile(url) { return samples }
        if let samples = try? await decodeWithAssetReader(url), !samples.isEmpty { return samples }
        if let samples = try decodeWithFFmpeg(url) { return samples }
        throw AudioFileDecoderError.unsupported(url.lastPathComponent)
    }

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
    )!

    static func decodeWithAudioFile(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioFileDecoderError.unsupported(url.lastPathComponent)
        }
        converter.downmix = true

        var output: [Float] = []
        output.reserveCapacity(Int(Double(file.length) * sampleRate / sourceFormat.sampleRate) + 1024)
        let chunkFrames: AVAudioFrameCount = 65_536
        let outCapacity = AVAudioFrameCount(Double(chunkFrames) * sampleRate / sourceFormat.sampleRate) + 1024
        var reachedEnd = false

        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { break }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                if reachedEnd {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuffer, frameCount: chunkFrames)
                } catch {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let conversionError { throw conversionError }
            if outBuffer.frameLength > 0, let channel = outBuffer.floatChannelData?[0] {
                output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
            if status == .inputRanDry && reachedEnd { break }
        }
        return output
    }

    static func decodeWithAssetReader(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioFileDecoderError.noAudioTrack(url.lastPathComponent)
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? AudioFileDecoderError.unsupported(url.lastPathComponent)
        }
        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            samples.append(contentsOf: chunk)
        }
        if reader.status == .failed { throw reader.error ?? AudioFileDecoderError.unsupported(url.lastPathComponent) }
        return samples
    }

    static let ffmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]

    static func decodeWithFFmpeg(_ url: URL) throws -> [Float]? {
        guard let ffmpeg = ffmpegCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-nostdin", "-v", "error", "-i", url.path, "-ac", "1", "-ar", "16000", "-f", "f32le", "-"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

public enum AudioFileDecoderError: LocalizedError {
    case unsupported(String)
    case noAudioTrack(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let name): "Apen can't read audio from \(name)."
        case .noAudioTrack(let name): "\(name) has no audio track."
        }
    }
}
