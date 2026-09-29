import Foundation
import UtterCore

/// Optional LLM pass that removes fillers and false starts and fixes punctuation, without changing meaning.
///
/// Long transcripts are cleaned in sentence-aligned pieces. Every piece goes through `FaithfulnessGuard`;
/// a rejected, failed or timed-out piece falls back to its raw text, so cleanup can never lose words.
public struct CleanupEngine: Sendable {
    public struct Result: Sendable {
        public let text: String
        public let piecesCleaned: Int
        public let piecesKept: Int
        /// True when cleanup produced nothing usable and the raw text was returned unchanged.
        public var fellBack: Bool { piecesCleaned == 0 }
    }

    /// Pieces are measured in words; ~700 words stays well inside the 4K-token context with the prompt.
    public static let maxWordsPerPiece = 700

    private let host: CleanupHost

    public init(host: CleanupHost = .shared) {
        self.host = host
    }

    /// Cleans `text`. Cancel the calling task (after `host.cancelInFlight()`) to stop early; the raw text
    /// is returned for anything not yet cleaned.
    public func clean(
        _ text: String,
        keepVerbatim: [String],
        extraInstructions: String?,
        mode: DictationMode = .general,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> Result {
        let pieces = TextSplitter.split(text, maxUnits: Self.maxWordsPerPiece) { TextSplitter.wordCount($0) }
        var output = ""
        var cleaned = 0
        var kept = 0
        for (index, piece) in pieces.enumerated() {
            let pieceCount = Double(pieces.count)
            progress?(Double(index) / pieceCount)
            let body = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            let trailing = String(piece.reversed().prefix { $0.isWhitespace }.reversed())
            guard !body.isEmpty else {
                output += piece
                continue
            }
            if Task.isCancelled {
                output += piece
                kept += 1
                continue
            }
            let messages = CleanupPrompt.messages(
                transcript: body, keepVerbatim: keepVerbatim, extraInstructions: extraInstructions, mode: mode
            )
            .map { LlamaRuntime.Message(role: $0.role.rawValue, content: $0.content) }
            let words = TextSplitter.wordCount(Substring(body))
            do {
                let reply = try await host.generate(
                    messages: messages,
                    maxTokens: Int(Double(words) * 2.2) + 48,
                    expectedTokens: Int(Double(words) * 1.3) + 4,
                    timeout: .seconds(max(10, Double(words) / 8))
                ) { fraction in
                    progress?((Double(index) + fraction) / pieceCount)
                }
                switch FaithfulnessGuard.evaluate(input: body, output: reply, condensing: mode.condenses) {
                case .accept(let accepted):
                    output += accepted + trailing
                    cleaned += 1
                case .reject:
                    output += piece
                    kept += 1
                }
            } catch {
                output += piece
                kept += 1
            }
        }
        progress?(1)
        return Result(text: output, piecesCleaned: cleaned, piecesKept: kept)
    }
}
