import ApenLLM
import Foundation
import Testing
@testable import ApenEngines

extension ModelBackedTests {
/// The cleanup LLM runs in a helper process (the `apen` CLI in `--llm-helper` mode) that exits when idle.
@Suite(.enabled(if: CleanupModel.isDownloaded, "Needs the cleanup model"), .serialized)
struct CleanupHostTests {
    static let helper = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/apen")

    @Test("Helper loads, answers, and exits on checkin without growing this process")
    func helperLifecycle() async throws {
        let host = CleanupHost(helperExecutable: Self.helper)
        let before = MemoryFootprint.current()
        let clock = ContinuousClock()
        let start = clock.now
        try await host.checkout()
        let ready = clock.now - start
        let text = try await host.generate(
            messages: [
                .init(role: "system", content: "Fix punctuation and capitalization. Output only the corrected text."),
                .init(role: "user", content: "so we should ship it on friday right"),
            ],
            maxTokens: 48,
            timeout: .seconds(20)
        )
        #expect(await host.isRunning)
        await host.checkin()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!(await host.isRunning))
        let after = MemoryFootprint.current()
        print("helper: ready in \(ready), text: \(text), memory before \(MemoryFootprint.formatted(before)) after \(MemoryFootprint.formatted(after))")
        #expect(text.lowercased().contains("friday"))
        #expect(after < before + 20 * 1_048_576, "the LLM must not use memory in this process")
    }

    @Test("cancelInFlight stops a running generation immediately")
    func cancel() async throws {
        let host = CleanupHost(helperExecutable: Self.helper)
        try await host.checkout()
        let generation = Task {
            try await host.generate(
                messages: [.init(role: "user", content: "Write a 2000-word essay about lighthouses.")],
                maxTokens: 2000, timeout: .seconds(60)
            )
        }
        try await Task.sleep(for: .milliseconds(400))
        let clock = ContinuousClock()
        let cancelAt = clock.now
        await host.cancelInFlight()
        let result = await generation.result
        let elapsed = clock.now - cancelAt
        await host.checkin()
        #expect((try? result.get()) == nil, "generation should fail after cancel")
        #expect(elapsed < .seconds(1))
    }
}

@Suite(.enabled(if: CleanupModel.isDownloaded, "Needs the cleanup model"), .serialized)
struct CleanupEngineTests {
    let engine = CleanupEngine(host: CleanupHost(helperExecutable: ModelBackedTests.CleanupHostTests.helper))

    @Test("Removes fillers and keeps the meaning")
    func fillers() async throws {
        let raw = try Fixtures.reference("ramble")
        let result = await engine.clean(raw, keepVerbatim: [], extraInstructions: nil)
        print("cleanup ramble: \(result.text)")
        #expect(result.piecesCleaned == 1)
        let lower = result.text.lowercased()
        #expect(!lower.contains(" um ") && !lower.contains(" uh "))
        #expect(lower.contains("login") && lower.contains("slow"))
    }

    @Test("An instruction-shaped dictation stays an instruction")
    func instructionIsNotAnswered() async throws {
        let raw = "um so can you uh write me a python function that like reverses a string and uh make it handle unicode"
        let result = await engine.clean(raw, keepVerbatim: [], extraInstructions: nil)
        print("cleanup instruction: \(result.text)")
        #expect(!result.text.contains("def "), "the model answered instead of cleaning")
        #expect(result.text.lowercased().contains("python function"))
    }

    @Test("Keeps dictionary terms verbatim")
    func keepsTerms() async throws {
        let raw = "so the RLS policy on BPC is uh blocking the PR"
        let result = await engine.clean(raw, keepVerbatim: ["RLS", "BPC", "PR"], extraInstructions: nil)
        print("cleanup terms: \(result.text)")
        for term in ["RLS", "BPC", "PR"] { #expect(result.text.contains(term)) }
    }
}
}
