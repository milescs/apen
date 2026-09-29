import Foundation
import UtterEngines

/// `utter transcribe <file>`: runs a file through the same live pipeline the app uses.
enum Transcribe {
    static func run(_ arguments: [String]) async throws {
        guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else {
            UtterCLI.printUsage()
            exit(64)
        }
        let realtime = arguments.contains("--realtime")
        let reportMemory = arguments.contains("--memory")
        let url = URL(fileURLWithPath: path)

        let baseline = MemoryFootprint.current()
        let samples = try await AudioFileDecoder.decode(url)
        let audioSeconds = Double(samples.count) / LiveTranscriber.sampleRate
        let afterDecode = MemoryFootprint.current()

        let start = Date()
        let transcriber = LiveTranscriber()
        await transcriber.start()
        try await transcriber.waitUntilReady()
        let loadSeconds = Date().timeIntervalSince(start)
        let loaded = MemoryFootprint.current()

        // Feed 100 ms buffers, like the microphone does; `--realtime` paces them at wall-clock speed.
        let chunk = Int(LiveTranscriber.sampleRate / 10)
        var offset = 0
        let feedStart = Date()
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            try await transcriber.append(Array(samples[offset..<end]))
            offset = end
            if realtime {
                let target = Double(offset) / LiveTranscriber.sampleRate
                let elapsed = Date().timeIntervalSince(feedStart)
                if target > elapsed { try await Task.sleep(for: .seconds(target - elapsed)) }
            }
        }
        let peak = MemoryFootprint.current()
        let finishStart = Date()
        let text = try await transcriber.finish()
        let finishSeconds = Date().timeIntervalSince(finishStart)
        let totalSeconds = Date().timeIntervalSince(start)
        // Give Core ML a moment to tear down before measuring.
        try await Task.sleep(for: .milliseconds(500))
        let afterUnload = MemoryFootprint.current()

        print(text)
        FileHandle.standardError.write(Data("""

            audio \(String(format: "%.1f", audioSeconds)) s · model load \(String(format: "%.2f", loadSeconds)) s · \
            finish \(String(format: "%.2f", finishSeconds)) s · total \(String(format: "%.1f", totalSeconds)) s\
            \(realtime ? "" : " (\(String(format: "%.0f", audioSeconds / max(totalSeconds - loadSeconds, 0.001)))× real time)")

            """.utf8))
        if reportMemory {
            FileHandle.standardError.write(Data("""
                memory: baseline \(MemoryFootprint.formatted(baseline)) · decoded \(MemoryFootprint.formatted(afterDecode)) · \
                model loaded \(MemoryFootprint.formatted(loaded)) · peak \(MemoryFootprint.formatted(peak)) · \
                after unload \(MemoryFootprint.formatted(afterUnload))

                """.utf8))
        }
    }
}
