import Testing
import ApenCore

private func characters(_ text: Substring) -> Int { text.count }
private func utf8Bytes(_ text: Substring) -> Int { text.utf8.count }
private func words(_ text: Substring) -> Int { TextSplitter.wordCount(text) }

/// A small seeded generator (SplitMix64) so the property checks are reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum SplitMeasure: String, CaseIterable, Sendable {
    case characters, utf8Bytes, words

    func callAsFunction(_ text: Substring) -> Int {
        switch self {
        case .characters: text.count
        case .utf8Bytes: text.utf8.count
        case .words: TextSplitter.wordCount(text)
        }
    }
}

private let sampleTexts: [String] = [
    "Hello world.",
    "One two. Three four. Five six.",
    "  Leading whitespace. And trailing whitespace.  \n",
    "The value is 3.5 today. Pi is 3.14159 and e is 2.71828 roughly!",
    "Use e.g. this one, or i.e. that one. Then stop.",
    "Wait… what? Really?! Yes... really.",
    "He said \"stop.\" Then he left (quietly.) The end.",
    "Line one\nLine two\n\n\nLine three\r\nLine four",
    "A supercalifragilisticexpialidocious word sits here.",
    "Emoji 👍🏽 and family 👨‍👩‍👧‍👦 and flags 🇺🇸 go here. Café naïve résumé. 日本語のテキスト。",
    "Visit https://example.com/a?b=1&c=2#top today. Then email me@example.com.",
    "no punctuation at all just a long run of words that keeps going and going without any stop",
    "   \n\t  ",
    "!!! ??? ...",
    "x",
]

@Suite("TextSplitter")
struct TextSplitterTests {
    @Test func emptyTextReturnsNoPieces() {
        #expect(TextSplitter.split("", maxUnits: 10, measure: characters) == [])
    }

    @Test func textWithinTheBudgetIsOnePiece() {
        #expect(TextSplitter.split("Hello world. Bye.", maxUnits: 100, measure: characters) == ["Hello world. Bye."])
        #expect(TextSplitter.split("Hello world. Bye.", maxUnits: 17, measure: characters) == ["Hello world. Bye."])
        #expect(TextSplitter.split("Hello world. Bye.", maxUnits: 3, measure: words) == ["Hello world. Bye."])
    }

    @Test func packsWholeSentencesGreedily() {
        #expect(
            TextSplitter.split("One two. Three four. Five six.", maxUnits: 4, measure: words)
                == ["One two. Three four. ", "Five six."]
        )
        #expect(
            TextSplitter.split("One. Two. Three.", maxUnits: 1, measure: words) == ["One. ", "Two. ", "Three."]
        )
    }

    @Test func splitsAtNewlines() {
        #expect(
            TextSplitter.split("First line\nSecond line\n\nThird", maxUnits: 2, measure: words)
                == ["First line\n", "Second line\n\n", "Third"]
        )
        #expect(
            TextSplitter.split("One\r\nTwo\r\nThree", maxUnits: 1, measure: words) == ["One\r\n", "Two\r\n", "Three"]
        )
    }

    @Test func recognisesEveryTerminatorAndClosingQuotes() {
        #expect(
            TextSplitter.split("Wait… what? Really! Yes.", maxUnits: 1, measure: words)
                == ["Wait… ", "what? ", "Really! ", "Yes."]
        )
        // The closing quote still ends the sentence, so "Then" is not packed with it.
        #expect(
            TextSplitter.split("He said \"stop.\" Then he left.", maxUnits: 4, measure: words)
                == ["He said \"stop.\" ", "Then he left."]
        )
        #expect(
            TextSplitter.split("(It worked!) Then it broke.", maxUnits: 3, measure: words)
                == ["(It worked!) ", "Then it broke."]
        )
    }

    @Test func leadingWhitespaceStaysWithTheFirstSentence() {
        #expect(
            TextSplitter.split("  Hello there. General Kenobi.", maxUnits: 2, measure: words)
                == ["  Hello there. ", "General Kenobi."]
        )
        #expect(
            TextSplitter.split("\n\nHello there. General Kenobi.", maxUnits: 2, measure: words)
                == ["\n\nHello there. ", "General Kenobi."]
        )
        // Leading newlines are not a sentence of their own, so they never become a blank piece.
        #expect(TextSplitter.split("\n\nOne two three.", maxUnits: 2, measure: words) == ["\n\nOne two ", "three."])
    }

    @Test func measuresTheWholePieceIncludingItsWhitespace() {
        #expect(TextSplitter.split("abc. def.", maxUnits: 5, measure: characters) == ["abc. ", "def."])
    }

    @Test func decimalsAreNotSentenceBoundaries() {
        #expect(
            TextSplitter.split("The value is 3.5 today. Next sentence here.", maxUnits: 5, measure: words)
                == ["The value is 3.5 today. ", "Next sentence here."]
        )
        let pieces = TextSplitter.split("Pi is about 3.14159 and e is about 2.71828 in value.", maxUnits: 6, measure: words)
        #expect(pieces == ["Pi is about 3.14159 and e ", "is about 2.71828 in value."])
    }

    @Test func abbreviationsMayEndAPiece() {
        #expect(TextSplitter.split("Use e.g. this one.", maxUnits: 3, measure: words) == ["Use e.g. ", "this one."])
    }

    @Test func oversizeSentenceSplitsAtTheLastWhitespaceThatFits() {
        #expect(
            TextSplitter.split("one two three four five six seven.", maxUnits: 3, measure: words)
                == ["one two three ", "four five six ", "seven."]
        )
        #expect(
            TextSplitter.split("alpha beta gamma delta", maxUnits: 11, measure: characters)
                == ["alpha beta ", "gamma delta"]
        )
    }

    @Test func oversizeSentenceAmongShortOnes() {
        let text = "Short one. This sentence is definitely far too long to fit. End."
        #expect(
            TextSplitter.split(text, maxUnits: 4, measure: words)
                == ["Short one. ", "This sentence is definitely ", "far too long to ", "fit. End."]
        )
    }

    @Test func aWordLongerThanTheBudgetIsSplitMidWordOnly() {
        #expect(
            TextSplitter.split("a supercalifragilistic word", maxUnits: 12, measure: characters)
                == ["a ", "supercalifra", "gilistic ", "word"]
        )
    }

    @Test func whitespaceThatDoesNotFitAfterAWordStartsTheNextPiece() {
        // "abcdefghij" fills the budget exactly, so its trailing space moves to the next piece.
        #expect(
            TextSplitter.split("abcdefghij klm", maxUnits: 10, measure: characters) == ["abcdefghij", " klm"]
        )
        // As much of a whitespace run as fits stays with the word.
        #expect(
            TextSplitter.split("abcdefghi    klm", maxUnits: 11, measure: characters) == ["abcdefghi  ", "  klm"]
        )
    }

    @Test func impossibleBudgetStillFinishesOneCharacterAtATime() {
        #expect(TextSplitter.split("ab c", maxUnits: 0, measure: characters) == ["a", "b", " ", "c"])
        // A four-byte emoji cannot fit two bytes, but it is never split inside the character.
        #expect(TextSplitter.split("👍🏽ok", maxUnits: 2, measure: utf8Bytes) == ["👍🏽", "ok"])
    }

    @Test func measuringStaysNearTheCurrentPieceInLongText() {
        let text = String(repeating: "One two three. ", count: 2_000)
        var probeLengths: [Int] = []
        let pieces = TextSplitter.split(text, maxUnits: 30) { piece in
            probeLengths.append(piece.count)
            return TextSplitter.wordCount(piece)
        }
        #expect(pieces.joined() == text)
        #expect(pieces.count == 200)
        #expect(Set(pieces).count == 1)
        // After the first call (the whole text), no probe measures more than about twice a piece.
        let pieceLength = pieces[0].count
        #expect(probeLengths.first == text.count)
        #expect(probeLengths.dropFirst().allSatisfy { $0 <= 3 * pieceLength })
        #expect(probeLengths.count < 200 * 12)
    }

    @Test("Concatenated pieces reproduce the input exactly", arguments: SplitMeasure.allCases)
    func concatenationReproducesTheInput(_ measure: SplitMeasure) {
        for text in sampleTexts {
            for budget in [1, 2, 3, 5, 8, 13, 21, 40, 1000] {
                let pieces = TextSplitter.split(text, maxUnits: budget, measure: { measure($0) })
                #expect(pieces.joined() == text, "\(measure) \(budget): \(text.debugDescription)")
                #expect(!pieces.contains(""))
                for piece in pieces {
                    #expect(measure(piece[...]) <= budget || piece.count == 1, "\(piece.debugDescription)")
                }
            }
        }
    }

    @Test func randomTextKeepsEveryInvariant() {
        var generator = SeededGenerator(state: 0x5EED)
        let fragments = [
            "Hello", "world", "3.5", "e.g.", "U.S.", "supercalifragilisticexpialidocious", "naïve", "café",
            "👍🏽", "👨‍👩‍👧‍👦", "日本語", "—", "...", "?", "!", ".", ",", "\"quoted.\"", "(paren)",
            "https://example.com/a?b=1", "x",
        ]
        let separators = [" ", " ", " ", "  ", "\n", "\n\n", "\t", ". ", "! ", "? ", "… ", " \r\n", ""]
        for _ in 0..<400 {
            var text = ""
            for _ in 0..<Int.random(in: 0...40, using: &generator) {
                text += fragments.randomElement(using: &generator)!
                text += separators.randomElement(using: &generator)!
            }
            let budget = Int.random(in: 1...60, using: &generator)
            let measure = SplitMeasure.allCases.randomElement(using: &generator)!
            let pieces = TextSplitter.split(text, maxUnits: budget, measure: { measure($0) })
            let context = "\(measure) \(budget): \(text.debugDescription)"

            #expect(pieces.joined() == text, "\(context)")
            #expect(text.isEmpty == pieces.isEmpty, "\(context)")
            #expect(!pieces.contains(""), "\(context)")
            for piece in pieces {
                #expect(measure(piece[...]) <= budget || piece.count == 1, "\(context)")
            }

            // A break falls strictly inside a word only when that word alone exceeds the budget.
            let longestWord = text.split(whereSeparator: \.isWhitespace).map { measure($0) }.max() ?? 0
            if longestWord <= budget {
                for (left, right) in zip(pieces, pieces.dropFirst()) {
                    #expect(left.last!.isWhitespace || right.first!.isWhitespace, "\(context)")
                }
            }
            // With a word budget, every piece but the last ends with whitespace.
            if measure == .words {
                for piece in pieces.dropLast() {
                    #expect(piece.last!.isWhitespace, "\(context)")
                }
            }
        }
    }

    @Test func wordCountCountsWhitespaceSeparatedWords() {
        #expect(TextSplitter.wordCount("") == 0)
        #expect(TextSplitter.wordCount(" \n\t ") == 0)
        #expect(TextSplitter.wordCount("hello") == 1)
        #expect(TextSplitter.wordCount("  hello   world\n\tagain ") == 3)
        #expect(TextSplitter.wordCount("3.5 apples, e.g. today") == 4)
        #expect(TextSplitter.wordCount("Hello — world") == 3)
        #expect(TextSplitter.wordCount("日本語 👍🏽") == 2)
        let text = "skip these words: one two three"
        #expect(TextSplitter.wordCount(text.dropFirst(18)) == 3)
    }
}
