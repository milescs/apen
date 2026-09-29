/// Decides whether an LLM cleanup of dictated text can be trusted. When it cannot, the app falls back to
/// the raw transcript.
public enum FaithfulnessGuard {
    public enum Verdict: Sendable, Equatable {
        /// The cleanup is trustworthy. The associated text has its wrappers stripped.
        case accept(String)
        case reject(Reason)
    }

    public enum Reason: String, Sendable, Equatable {
        /// Nothing with a letter or digit is left after stripping wrappers.
        case empty
        /// The word count changed more than a cleanup plausibly would.
        case lengthRatio
        /// The model answered as an assistant instead of cleaning the text.
        case assistantBoilerplate
    }

    /// Evaluates a cleanup `output` against the dictated `input`.
    ///
    /// 1. Wrappers are stripped as in ``stripWrappers(_:)``. A wrapper that the dictation itself has,
    ///    such as a quotation the speaker dictated, is kept.
    /// 2. If no letter or digit is left, the output is rejected as ``Reason/empty``.
    /// 3. The ratio of output words to input words must be within 0.5…1.3 when the input has at least 12
    ///    words, and within 0.3…2.0 for shorter input; otherwise ``Reason/lengthRatio``. Words are
    ///    whitespace-separated tokens that contain a letter or digit.
    /// 4. If the output opens like an assistant ("Sure", "Certainly", "Of course", "Here's", "Here is",
    ///    "Here are", "I'd be happy", "I can help", "As an AI", "Absolutely", or a refusal such as "I'm
    ///    sorry") and the dictation does not open with the same words, the output is rejected as
    ///    ``Reason/assistantBoilerplate``. The comparison ignores case, punctuation, contractions
    ///    ("here's" matches "here is") and leading fillers ("um", "okay so"). It repeats while both texts
    ///    share an opener, so "Sure! Here's a function" is still caught when the dictation starts with
    ///    "sure".
    ///
    /// - Parameter condensing: For modes that turn speech into notes, long inputs may shrink to 0.3 of
    ///   their words instead of 0.5.
    public static func evaluate(input: String, output: String, condensing: Bool = false) -> Verdict {
        let dictatedWrappers = unwrap(input).removed
        let cleaned = unwrap(output, keeping: dictatedWrappers).text
        guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { return .reject(.empty) }
        guard hasPlausibleLength(inputWords: wordCount(input), outputWords: wordCount(cleaned), condensing: condensing) else {
            return .reject(.lengthRatio)
        }
        guard !opensLikeAnAssistant(output: cleaned, input: input) else { return .reject(.assistantBoilerplate) }
        return .accept(cleaned)
    }

    /// Trims the output and removes the wrappers models put around a cleanup: surrounding ``` fences
    /// (with an optional language tag), one pair of surrounding straight or curly quotes, surrounding
    /// `<transcript>…</transcript>` or `<cleaned>…</cleaned>` tags, and a leading label line such as
    /// "Cleaned text:" or "Here is the cleaned text:" (only when a colon or newline follows it).
    ///
    /// Wrappers may be nested in any order. Each kind is removed at most once, and a pair is removed only
    /// when it encloses the whole text (so `"A" and "B"` keeps its quotes).
    public static func stripWrappers(_ output: String) -> String {
        unwrap(output).text
    }

    // MARK: - Wrappers

    private enum Wrapper: CaseIterable {
        case codeFence, transcriptTags, cleanedTags, labelLine, quotes

        func remove(from text: String) -> String? {
            switch self {
            case .codeFence: FaithfulnessGuard.removeCodeFence(from: text)
            case .transcriptTags: FaithfulnessGuard.removeTags(named: "transcript", from: text)
            case .cleanedTags: FaithfulnessGuard.removeTags(named: "cleaned", from: text)
            case .labelLine: FaithfulnessGuard.removeLabelLine(from: text)
            case .quotes: FaithfulnessGuard.removeQuotes(from: text)
            }
        }
    }

    /// Strips wrappers until none is left, skipping the kinds in `kept`.
    private static func unwrap(
        _ text: String,
        keeping kept: Set<Wrapper> = []
    ) -> (text: String, removed: Set<Wrapper>) {
        var text = trimmed(text)
        var removed: Set<Wrapper> = []
        var changed = true
        while changed {
            changed = false
            for wrapper in Wrapper.allCases where !removed.contains(wrapper) && !kept.contains(wrapper) {
                guard let inner = wrapper.remove(from: text) else { continue }
                text = trimmed(inner)
                removed.insert(wrapper)
                changed = true
            }
        }
        return (text, removed)
    }

    private static func removeCodeFence(from text: String) -> String? {
        let fence = "```"
        guard text.count >= 2 * fence.count, text.hasPrefix(fence), text.hasSuffix(fence) else { return nil }
        var inner = text.dropFirst(fence.count).dropLast(fence.count)
        guard !inner.contains(fence) else { return nil }
        // Text on the opening line without spaces is a language tag ("```text"). With spaces, it is content.
        if let newline = inner.firstIndex(where: \.isNewline), !inner[..<newline].contains(where: \.isWhitespace) {
            inner = inner[inner.index(after: newline)...]
        }
        return String(inner)
    }

    private static func removeTags(named name: String, from text: String) -> String? {
        let open = "<\(name)>"
        let close = "</\(name)>"
        guard text.count >= open.count + close.count,
              text.prefix(open.count).lowercased() == open,
              text.suffix(close.count).lowercased() == close
        else { return nil }
        let inner = text.dropFirst(open.count).dropLast(close.count)
        let lowercasedInner = inner.lowercased()
        guard !lowercasedInner.contains(open), !lowercasedInner.contains(close) else { return nil }
        return String(inner)
    }

    private static func removeLabelLine(from text: String) -> String? {
        let label = #/
            (?: \*\* )?
            (?: (?: sure | okay | ok | alright ) [,!.]? \s+ )?
            (?:
                here (?: 's | ’s | \s+ is | \s+ are ) \s+ (?: (?: the | your ) \s+ )?
                (?: (?: cleaned (?: [\h\-]? up )? | corrected | edited | polished | revised | fixed | final
                      | formatted | proofread ) \s+ )?
                (?: text | transcript | transcription | version | message | output | result | dictation )
            |
                (?: (?: the | your ) \s+ )?
                (?: cleaned (?: [\h\-]? up )? | corrected | edited | polished | revised | fixed | final
                  | formatted | proofread ) \s+
                (?: text | transcript | transcription | version | message | output | result | dictation )
            |
                (?: transcript | transcription | output )
            )
            (?: \s+ of \s+ (?: the | your ) \s+ (?: text | transcript | transcription | message | dictation ) )?
            \h* (?: \*\* )? \h* (?: : (?: \*\* )? | \R )
            /#.ignoresCase()
        guard let match = text.prefixMatch(of: label) else { return nil }
        return String(text[match.range.upperBound...])
    }

    private static let doubleQuotes: Set<Character> = ["\"", "“", "”", "„"]
    private static let openingDoubleQuotes: Set<Character> = ["\"", "“", "„"]
    private static let closingDoubleQuotes: Set<Character> = ["\"", "”", "“"]
    private static let singleQuotes: Set<Character> = ["'", "‘", "’"]
    private static let openingSingleQuotes: Set<Character> = ["'", "‘"]
    private static let closingSingleQuotes: Set<Character> = ["'", "’"]

    private static func removeQuotes(from text: String) -> String? {
        guard text.count >= 2, let first = text.first, let last = text.last else { return nil }
        let inner = Array(text.dropFirst().dropLast())
        if openingDoubleQuotes.contains(first), closingDoubleQuotes.contains(last) {
            return inner.contains(where: doubleQuotes.contains) ? nil : String(inner)
        }
        if openingSingleQuotes.contains(first), closingSingleQuotes.contains(last) {
            // An apostrophe inside a word ("it's") is not a quote.
            for (offset, character) in inner.enumerated() where singleQuotes.contains(character) {
                let insideWord = offset > 0 && offset < inner.count - 1
                    && inner[offset - 1].isLetter && inner[offset + 1].isLetter
                if !insideWord { return nil }
            }
            return String(inner)
        }
        return nil
    }

    // MARK: - Length

    private static func hasPlausibleLength(inputWords: Int, outputWords: Int, condensing: Bool) -> Bool {
        guard inputWords > 0 else { return outputWords == 0 }
        // Bounds in tenths, compared with integers so the boundaries are exact.
        let (lower, upper) = inputWords >= 12 ? (condensing ? 3 : 5, 13) : (3, 20)
        return outputWords * 10 >= inputWords * lower && outputWords * 10 <= inputWords * upper
    }

    /// Whitespace-separated tokens that contain a letter or digit, so a bullet or dash is not a word.
    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace)
            .count { token in token.contains { $0.isLetter || $0.isNumber } }
    }

    // MARK: - Assistant boilerplate

    private static let assistantOpeners: [[String]] = [
        "sure", "certainly", "of course", "here's", "here is", "here are", "i'd be happy", "i can help",
        "as an ai", "absolutely",
        // Refusals would otherwise be pasted in place of the dictation.
        "i'm sorry", "i apologize", "i'm unable", "i can't help", "i can't assist", "as a language model",
        "great question",
    ].map { openingWords(of: $0) }

    private static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "eh", "hmm", "hm", "mm", "mhm", "oh", "so",
        "okay", "ok", "well", "like", "yeah", "yes", "alright",
    ]
    private static let twoWordFillers: [[String]] = [["you", "know"], ["all", "right"]]

    private static func opensLikeAnAssistant(output: String, input: String) -> Bool {
        var outputWords = droppingFillers(openingWords(of: output)[...])
        var inputWords = droppingFillers(openingWords(of: input)[...])
        while let opener = assistantOpeners.first(where: { outputWords.starts(with: $0) }) {
            guard inputWords.starts(with: opener) else { return true }
            outputWords = droppingFillers(outputWords.dropFirst(opener.count))
            inputWords = droppingFillers(inputWords.dropFirst(opener.count))
        }
        return false
    }

    /// The first words of `text`, lowercased, without surrounding punctuation, with curly apostrophes
    /// straightened and a few contractions expanded.
    private static func openingWords(of text: String) -> [String] {
        var words: [String] = []
        for token in text.split(maxSplits: 40, whereSeparator: \.isWhitespace).prefix(40) {
            let characters = token.lowercased().map { $0 == "’" || $0 == "‘" ? "'" : $0 }
            guard let first = characters.firstIndex(where: { $0.isLetter || $0.isNumber }),
                  let last = characters.lastIndex(where: { $0.isLetter || $0.isNumber })
            else { continue }
            let word = String(characters[first...last])
            switch word {
            case "here's": words += ["here", "is"]
            case "i'd": words += ["i", "would"]
            case "i'm": words += ["i", "am"]
            case "can't": words += ["cannot"]
            default: words.append(word)
            }
        }
        return words
    }

    private static func droppingFillers(_ words: ArraySlice<String>) -> ArraySlice<String> {
        var words = words
        while let first = words.first {
            if fillers.contains(first) {
                words = words.dropFirst()
            } else if let filler = twoWordFillers.first(where: { words.starts(with: $0) }) {
                words = words.dropFirst(filler.count)
            } else {
                break
            }
        }
        return words
    }

    // MARK: - Helpers

    private static func trimmed(_ text: some StringProtocol) -> String {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
              let last = text.lastIndex(where: { !$0.isWhitespace })
        else { return "" }
        return String(text[first...last])
    }
}
