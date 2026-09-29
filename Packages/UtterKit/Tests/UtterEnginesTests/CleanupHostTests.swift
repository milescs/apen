import Foundation
import Testing
@testable import UtterEngines

/// The cleanup LLM runs in a helper process (the `utter` CLI in `--llm-helper` mode) that exits when idle.
@Suite(.enabled(if: Fixtures.isEnabled && CleanupModel.isDownloaded, "Needs UTTER_INTEGRATION=1 and the cleanup model"), .serialized)
struct CleanupHostTests {
    static let helper = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/utter")

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
