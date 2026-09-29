import Foundation

/// Transcribes an audio or video file with the same model and pipeline as live dictation.
public enum FileTranscriptionJob {
    public struct Result: Sendable {
        public let text: String
        public let audioSeconds: Double
        public let processingSeconds: Double
    }

    /// Feeds the decoded file as fast as the model allows. `progress` reports 0...1 (decoding counts as the first 5%).
    public static func run(
        url: URL,
        boostTerms: [BoostTerm] = [],
        host: SpeechModelHost = .shared,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Result {
        let start = ContinuousClock.now
        progress(0)
        let samples = try await AudioFileDecoder.decode(url)
        try Task.checkCancellation()
        progress(0.05)

        let transcriber = LiveTranscriber(host: host, boostTerms: boostTerms)
        await transcriber.start()
        do {
            // Larger chunks than the microphone's 100 ms: fewer actor hops, same windows.
            let chunk = Int(LiveTranscriber.sampleRate * 2)
            var offset = 0
            while offset < samples.count {
                try Task.checkCancellation()
                let end = min(offset + chunk, samples.count)
                try await transcriber.append(Array(samples[offset..<end]))
                offset = end
                progress(0.05 + 0.95 * Double(offset) / Double(max(samples.count, 1)))
            }
            let text = try await transcriber.finish()
            progress(1)
            let elapsed = ContinuousClock.now - start
            return Result(
                text: text,
                audioSeconds: Double(samples.count) / LiveTranscriber.sampleRate,
                processingSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            )
        } catch {
            await transcriber.cancel()
            throw error
        }
    }
}
