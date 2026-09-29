import Foundation
import Testing
@testable import ApenEngines

extension ModelBackedTests {
@Suite(.serialized)
struct LevelProbeTests {
    @Test("A file played as the microphone reports input levels for the HUD meter")
    func fileSourceReportsLevel() async throws {
        let session = DictationSession(recordingURL: nil)
        _ = try await session.start(source: .file(Fixtures.url("ramble", "wav"), speed: 1))
        var samples: [Float] = []
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            samples.append(session.level)
        }
        await session.cancel()
        #expect(samples.contains { $0 > 0.2 })
    }
}
}
