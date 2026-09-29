import Foundation
import Testing
@testable import UtterEngines

@Suite(.enabled(if: Fixtures.isEnabled && CleanupModel.isDownloaded, "Needs UTTER_INTEGRATION=1 and the cleanup model"), .serialized)
struct LlamaRuntimeTests {
    @Test("Loads, rewrites a sentence and frees memory on unload")
    func loadGenerateUnload() async throws {
        let runtime = LlamaRuntime(modelURL: CleanupModel.fileURL)
        let before = MemoryFootprint.current()
        let clock = ContinuousClock()
        let loadStart = clock.now
        try await runtime.load()
        let loadTime = clock.now - loadStart
        let loaded = MemoryFootprint.current()

        let generateStart = clock.now
        let output = try await runtime.generate(
            messages: [
                .init(role: "system", content: "Rewrite the user's text with correct punctuation and capitalization. Output only the rewritten text."),
                .init(role: "user", content: "um so i think we should uh ship it on friday"),
            ],
            maxTokens: 64
        )
        let generateTime = clock.now - generateStart
        await runtime.unload()
        try await Task.sleep(for: .milliseconds(300))
        let after = MemoryFootprint.current()

        print("llama: load \(loadTime), generate \(generateTime), memory before \(MemoryFootprint.formatted(before)) loaded \(MemoryFootprint.formatted(loaded)) after \(MemoryFootprint.formatted(after)): \(output)")
        #expect(output.lowercased().contains("friday"))
        #expect(!(await runtime.isLoaded))
        #expect(after < loaded, "memory should drop after unload")
    }
}
