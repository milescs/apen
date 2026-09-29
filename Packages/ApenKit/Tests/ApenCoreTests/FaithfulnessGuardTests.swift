import Testing
import ApenCore

/// `count` distinct plain words ("w1 w2 …").
private func plainWords(_ count: Int, prefix: String) -> String {
    (1...count).map { "\(prefix)\($0)" }.joined(separator: " ")
}

struct WrapperCase: Sendable, CustomTestStringConvertible {
    let output: String
    let stripped: String

    init(_ output: String, _ stripped: String) {
        self.output = output
        self.stripped = stripped
    }

    var testDescription: String { output.debugDescription }
}

private let wrapperCases: [WrapperCase] = [
    .init("  Hello there.  \n", "Hello there."),
    // Code fences.
    .init("```\nHello there.\n```", "Hello there."),
    .init("```text\nHello there.\n```", "Hello there."),
    .init("```markdown\nLine one.\nLine two.\n```", "Line one.\nLine two."),
    .init("```Hello there.```", "Hello there."),
    // Quotes.
    .init("\"Hello there.\"", "Hello there."),
    .init("“Hello there.”", "Hello there."),
    .init("'Hello there.'", "Hello there."),
    .init("‘It’s done.’", "It’s done."),
    .init("“He said ‘hi’ to me.”", "He said ‘hi’ to me."),
    // Tags.
    .init("<transcript>\nHello there.\n</transcript>", "Hello there."),
    .init("<cleaned>Hello there.</cleaned>", "Hello there."),
    .init("<CLEANED>Hello there.</Cleaned>", "Hello there."),
    // Label lines.
    .init("Cleaned text:\nHello there.", "Hello there."),
    .init("Cleaned text: Hello there.", "Hello there."),
    .init("Cleaned text\nHello there.", "Hello there."),
    .init("Here is the cleaned text:\n\nHello there.", "Hello there."),
    .init("Here's the cleaned-up version:\nHello there.", "Hello there."),
    .init("Here’s your corrected text: Hello there.", "Hello there."),
    .init("Sure, here is the cleaned up version of your transcript:\nHello there.", "Hello there."),
    .init("**Cleaned text:**\nHello there.", "Hello there."),
    .init("Transcript: Hello there.", "Hello there."),
    // Nested wrappers, in any order.
    .init("Here is the cleaned text:\n\"Hello there.\"", "Hello there."),
    .init("```\n<cleaned>\nHello there.\n</cleaned>\n```", "Hello there."),
    .init("\"<cleaned>Hello there.</cleaned>\"", "Hello there."),
    .init("<cleaned>Cleaned text: “Hello there.”</cleaned>", "Hello there."),
    // Not wrappers.
    .init("\"Stop\" means stop.", "\"Stop\" means stop."),
    .init("\"A\" and \"B\"", "\"A\" and \"B\""),
    .init("\"\"Double.\"\"", "\"\"Double.\"\""),
    .init("'Hello' and 'bye'", "'Hello' and 'bye'"),
    .init("Use ```code``` and ```more```", "Use ```code``` and ```more```"),
    .init("```\nunterminated fence", "```\nunterminated fence"),
    .init("<cleaned>a</cleaned> and <cleaned>b</cleaned>", "<cleaned>a</cleaned> and <cleaned>b</cleaned>"),
    .init("Here is the cleaned text we discussed.", "Here is the cleaned text we discussed."),
    .init("Text me when you land.", "Text me when you land."),
    .init("The output was fine.", "The output was fine."),
]

@Suite("FaithfulnessGuard")
struct FaithfulnessGuardTests {
    // MARK: Wrappers

    @Test(arguments: wrapperCases)
    func stripsWrappers(_ testCase: WrapperCase) {
        #expect(FaithfulnessGuard.stripWrappers(testCase.output) == testCase.stripped)
    }

    @Test func evaluateAcceptsTheStrippedText() {
        #expect(
            FaithfulnessGuard.evaluate(
                input: "hello there general kenobi",
                output: "Here is the cleaned text:\n```\n\"Hello there, General Kenobi.\"\n```"
            ) == .accept("Hello there, General Kenobi.")
        )
    }

    @Test func wrappersTheSpeakerDictatedAreKept() {
        #expect(
            FaithfulnessGuard.evaluate(input: "\"to be or not to be\"", output: "\"To be, or not to be.\"")
                == .accept("\"To be, or not to be.\"")
        )
        #expect(
            FaithfulnessGuard.evaluate(
                input: "final version: the report is attached",
                output: "<cleaned>Final version: the report is attached.</cleaned>"
            ) == .accept("Final version: the report is attached.")
        )
    }

    // MARK: Accepted cleanups

    @Test func fillerRemovalIsAccepted() {
        let input = "um so I was thinking uh we could maybe move the the meeting to Thursday you know"
        let output = "I was thinking we could maybe move the meeting to Thursday."
        #expect(FaithfulnessGuard.evaluate(input: input, output: output) == .accept(output))
    }

    @Test func anInstructionShapedTranscriptThatIsOnlyCleanedIsAccepted() {
        let input = "um so can you uh write me a python function that like reverses a string"
        let output = "Can you write me a Python function that reverses a string?"
        #expect(FaithfulnessGuard.evaluate(input: input, output: output) == .accept(output))
    }

    @Test(arguments: [
        ("Hello world.", "Hello world."),
        ("  Sure thing, see you at 5.  ", "Sure thing, see you at 5."),
        ("Here is the plan: we meet at 9.", "Here is the plan: we meet at 9."),
        ("I'm sorry I missed your call.", "I'm sorry I missed your call."),
        ("\"Quoted dictation.\"", "\"Quoted dictation.\""),
        ("um uh like whatever", "um uh like whatever"),
        ("日本語のテキスト", "日本語のテキスト"),
    ])
    func anUnchangedTranscriptIsAccepted(text: String, trimmed: String) {
        #expect(FaithfulnessGuard.evaluate(input: text, output: text) == .accept(trimmed))
    }

    // MARK: Assistant boilerplate

    @Test func anAnswerToAnInstructionShapedTranscriptIsRejected() {
        #expect(
            FaithfulnessGuard.evaluate(
                input: "write me a python function that reverses a string",
                output: "Sure! Here's a function: def reverse(s): return s[::-1]"
            ) == .reject(.assistantBoilerplate)
        )
    }

    @Test func aLongAnswerIsRejectedForItsLength() {
        let output = """
            Sure! Here's a Python function that reverses a string:

            ```python
            def reverse_string(s: str) -> str:
                return s[::-1]
            ```

            This uses slicing with a step of -1 to walk the string backwards, and it works for Unicode too.
            """
        #expect(
            FaithfulnessGuard.evaluate(input: "write me a python function that reverses a string", output: output)
                == .reject(.lengthRatio)
        )
    }

    @Test(arguments: [
        "Sure, the meeting moved to Thursday.",
        "sure — the meeting moved to Thursday.",
        "**Sure!** The meeting moved to Thursday.",
        "Certainly. The meeting moved to Thursday.",
        "Of course! The meeting moved to Thursday.",
        "Here's the thing: the meeting moved to Thursday.",
        "Here is the thing: the meeting moved to Thursday.",
        "Here are the details: the meeting moved to Thursday.",
        "I'd be happy to help: the meeting moved to Thursday.",
        "I would be happy to help: the meeting moved to Thursday.",
        "I can help: the meeting moved to Thursday.",
        "As an AI, I note the meeting moved to Thursday.",
        "Absolutely, the meeting moved to Thursday.",
        "Okay, here's the update: the meeting moved to Thursday.",
        "I’m sorry, but I can’t help with that request.",
        "I cannot help with moving the meeting to Thursday.",
    ])
    func assistantOpenersAreRejected(_ output: String) {
        let input = "the meeting moved to thursday because friday is booked"
        #expect(FaithfulnessGuard.evaluate(input: input, output: output) == .reject(.assistantBoilerplate))
    }

    @Test func anOpenerTheSpeakerSaidIsAccepted() {
        let cases: [(input: String, output: String)] = [
            ("sure let's meet at noon", "Sure, let's meet at noon."),
            ("um of course we should ship it", "Of course we should ship it."),
            ("okay so absolutely not", "Absolutely not."),
            ("here is the plan we meet at nine", "Here's the plan: we meet at nine."),
            ("here's what I think we should do", "Here is what I think we should do."),
            ("I can help with the move on Saturday", "I can help with the move on Saturday."),
            ("yeah sure here is the list", "Sure, here is the list."),
            ("certainly not before friday", "“Certainly not before Friday.”"),
        ]
        for (input, output) in cases {
            #expect(
                FaithfulnessGuard.evaluate(input: input, output: output)
                    == .accept(FaithfulnessGuard.stripWrappers(output)),
                "\(input)"
            )
        }
    }

    @Test func anOpenerAfterAnOpenerTheSpeakerSaidIsStillRejected() {
        #expect(
            FaithfulnessGuard.evaluate(
                input: "sure can you write me a function that reverses a string",
                output: "Sure! Here's a function: def reverse(s): return s[::-1]"
            ) == .reject(.assistantBoilerplate)
        )
    }

    @Test func aDifferentOpenerThanTheSpeakerUsedIsRejected() {
        #expect(
            FaithfulnessGuard.evaluate(input: "sure let's go", output: "Of course, let's go.")
                == .reject(.assistantBoilerplate)
        )
        #expect(
            FaithfulnessGuard.evaluate(input: "I need a function", output: "I can help with a function.")
                == .reject(.assistantBoilerplate)
        )
    }

    @Test func openersOnlyMatchWholeWords() {
        #expect(
            FaithfulnessGuard.evaluate(input: "surely you jest", output: "Surely you jest.") == .accept("Surely you jest.")
        )
        #expect(
            FaithfulnessGuard.evaluate(input: "hereby I resign", output: "Hereby, I resign.") == .accept("Hereby, I resign.")
        )
    }

    // MARK: Empty output

    @Test(arguments: ["", "   \n ", "```\n```", "\"\"", "<cleaned></cleaned>", "Cleaned text:", "...", "“ ”"])
    func emptyOutputIsRejected(_ output: String) {
        #expect(FaithfulnessGuard.evaluate(input: "hello there", output: output) == .reject(.empty))
    }

    // MARK: Length ratio

    @Test(arguments: [
        // Input of 12 words or more: the output must keep 0.5…1.3 of the words.
        (20, 10, true), (20, 9, false), (20, 26, true), (20, 27, false),
        (12, 6, true), (12, 5, false), (12, 15, true), (12, 16, false),
        // Shorter input: 0.3…2.0.
        (11, 4, true), (11, 3, false), (11, 22, true), (11, 23, false),
        (10, 3, true), (10, 2, false), (10, 20, true), (10, 21, false),
        (1, 1, true), (1, 2, true), (1, 3, false),
    ])
    func lengthRatioBoundaries(inputWords: Int, outputWords: Int, accepted: Bool) {
        let input = plainWords(inputWords, prefix: "in")
        let output = plainWords(outputWords, prefix: "out")
        let expected: FaithfulnessGuard.Verdict = accepted ? .accept(output) : .reject(.lengthRatio)
        #expect(FaithfulnessGuard.evaluate(input: input, output: output) == expected)
    }

    @Test func punctuationTokensAreNotWords() {
        // Three real words each way; the bullets and dash do not count.
        #expect(
            FaithfulnessGuard.evaluate(input: "milk eggs bread", output: "- Milk\n- Eggs\n- Bread —")
                == .accept("- Milk\n- Eggs\n- Bread —")
        )
    }

    @Test func outputWithWordsForAnInputWithoutWordsIsRejected() {
        #expect(FaithfulnessGuard.evaluate(input: "...", output: "Hello.") == .reject(.lengthRatio))
    }

    @Test func reasonsHaveStableRawValues() {
        #expect(FaithfulnessGuard.Reason.empty.rawValue == "empty")
        #expect(FaithfulnessGuard.Reason.lengthRatio.rawValue == "lengthRatio")
        #expect(FaithfulnessGuard.Reason.assistantBoilerplate.rawValue == "assistantBoilerplate")
    }
}
