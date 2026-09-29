import Foundation
import Testing
@testable import UtterEngines

/// Model-backed tests. Run with `make integration` (needs `make models` once); skipped otherwise.
/// Everything runs locally with the open-weight models — no network, no cloud APIs.
@Suite(.enabled(if: Fixtures.isEnabled, "Set UTTER_INTEGRATION=1 and UTTER_FIXTURES to run"), .serialized)
struct EngineIntegrationTests {
    @Test("Short fixtures transcribe with ≤ 8% word error rate", arguments: ["short", "acronyms", "instruction", "ramble"])
    func shortFixtures(name: String) async throws {
        let result = try await Fixtures.transcribe(name)
        let reference = try Fixtures.reference(name)
        let wer = WordErrorRate.compute(reference: reference, hypothesis: result.text)
        #expect(wer <= 0.08, "WER \(wer) for \(name): \(result.text)")
    }

    @Test("Five-minute recording keeps every paragraph, in order")
    func longForm() async throws {
        let result = try await Fixtures.transcribe("long")
        let keywords = try Fixtures.lines("long-keywords")
        let lower = result.text.lowercased()
        let positions = keywords.map { lower.range(of: $0)?.lowerBound }
        #expect(positions.allSatisfy { $0 != nil }, "missing keywords: \(zip(keywords, positions).filter { $0.1 == nil }.map(\.0))")
        let found = positions.compactMap { $0 }
        #expect(found == found.sorted(), "keywords out of order")
        let wer = WordErrorRate.compute(reference: try Fixtures.reference("long"), hypothesis: result.text)
        #expect(wer <= 0.08, "WER \(wer)")
    }

    @Test("Silence produces no text")
    func silence() async throws {
        let result = try await Fixtures.transcribe("silence")
        #expect(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "got: \(result.text)")
    }

    @Test("m4a and mp4 decode to the same audio as the wav", arguments: ["m4a", "mp4"])
    func containers(ext: String) async throws {
        let wav = try await AudioFileDecoder.decode(Fixtures.url("short", "wav"))
        let other = try await AudioFileDecoder.decode(Fixtures.url("short", ext))
        let seconds = { (samples: [Float]) in Double(samples.count) / AudioFileDecoder.sampleRate }
        #expect(abs(seconds(wav) - seconds(other)) < 0.25, "wav \(seconds(wav)) s vs \(ext) \(seconds(other)) s")
        let text = try await Fixtures.transcribe(samples: other).text
        let wer = WordErrorRate.compute(reference: try Fixtures.reference("short"), hypothesis: text)
        #expect(wer <= 0.1, "\(ext): \(text)")
    }

    @Test("Final text arrives within a second of the end of real-time audio")
    func finishLatency() async throws {
        let result = try await Fixtures.transcribe("acronyms", realtime: true)
        #expect(result.finishSeconds < 1.0, "finish took \(result.finishSeconds) s")
    }

    @Test("Vocabulary boosting keeps made-up terms")
    func boosting() async throws {
        try #require(BoostModel.isDownloaded, "run `utter models download --boost`")
        let samples = try await Fixtures.say("Please ask Zorblax to review the Quibbleton rollout before Friday.")
        let terms = [BoostTerm(text: "Zorblax"), BoostTerm(text: "Quibbleton")]
        let boosted = try await Fixtures.transcribe(samples: samples, boostTerms: terms).text
        #expect(boosted.contains("Zorblax") && boosted.contains("Quibbleton"), "boosted: \(boosted)")
    }

    @Test("The model is released after a session")
    func releasesModel() async throws {
        _ = try await Fixtures.transcribe("short")
        try await Task.sleep(for: .milliseconds(200))
        #expect(await SpeechModelHost.shared.isLoaded == false)
    }
}

enum Fixtures {
    static let isEnabled = ProcessInfo.processInfo.environment["UTTER_INTEGRATION"] == "1"
    static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["UTTER_FIXTURES"] ?? "Fixtures/generated")
    }

    struct Transcription {
        let text: String
        let finishSeconds: Double
    }

    static func url(_ name: String, _ ext: String) -> URL {
        directory.appendingPathComponent("\(name).\(ext)")
    }

    static func reference(_ name: String) throws -> String {
        try String(contentsOf: url(name, "txt"), encoding: .utf8)
    }

    static func lines(_ name: String) throws -> [String] {
        try reference(name).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func transcribe(_ name: String, realtime: Bool = false) async throws -> Transcription {
        try await transcribe(samples: AudioFileDecoder.decode(url(name, "wav")), realtime: realtime)
    }

    /// Feeds 100 ms chunks like the microphone does.
    static func transcribe(samples: [Float], realtime: Bool = false, boostTerms: [BoostTerm] = []) async throws -> Transcription {
        let transcriber = LiveTranscriber(boostTerms: boostTerms)
        await transcriber.start()
        try await transcriber.waitUntilReady()
        let chunk = Int(LiveTranscriber.sampleRate / 10)
        let clock = ContinuousClock()
        let start = clock.now
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            try await transcriber.append(Array(samples[offset..<end]))
            offset = end
            if realtime {
                try await Task.sleep(until: start + .seconds(Double(offset) / LiveTranscriber.sampleRate), clock: clock)
            }
        }
        let finishStart = clock.now
        let text = try await transcriber.finish()
        let elapsed = clock.now - finishStart
        return Transcription(text: text, finishSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    /// Speaks `text` with the system voice into a temporary file and decodes it.
    static func say(_ text: String) async throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("utter-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Samantha", "-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        return try await AudioFileDecoder.decode(url)
    }
}

enum WordErrorRate {
    static func compute(reference: String, hypothesis: String) -> Double {
        let ref = words(reference)
        let hyp = words(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        var row = Array(0...hyp.count)
        for (i, refWord) in ref.enumerated() {
            var previous = row[0]
            row[0] = i + 1
            for (j, hypWord) in hyp.enumerated() {
                let current = min(row[j + 1] + 1, row[j] + 1, previous + (refWord == hypWord ? 0 : 1))
                previous = row[j + 1]
                row[j + 1] = current
            }
        }
        return Double(row[hyp.count]) / Double(ref.count)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .map(String.init)
    }
}
