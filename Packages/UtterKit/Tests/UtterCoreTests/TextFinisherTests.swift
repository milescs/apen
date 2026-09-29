import Testing
import UtterCore

struct FinishCase: Sendable, CustomTestStringConvertible {
    let input: String
    let expected: String

    init(_ input: String, _ expected: String) {
        self.input = input
        self.expected = expected
    }

    var testDescription: String { input.debugDescription }
}

private let finishCases: [FinishCase] = [
    // Trimming and collapsing.
    .init("  hello   world  ", "hello world"),
    .init("a\t\tb \t c", "a b c"),
    .init("\n\n  Hello\n\n", "Hello"),
    .init("already tidy.", "already tidy."),
    // Spaces before closing punctuation.
    .init("Hello , world .", "Hello, world."),
    .init("Wait ... what ?!", "Wait... what?!"),
    .init("(like this )", "(like this)"),
    .init("a ; b : c", "a; b: c"),
    .init("He said \"hi\" .", "He said \"hi\"."),
    .init("Really \t!", "Really!"),
    // Newlines.
    .init("one\ntwo", "one\ntwo"),
    .init("one\n\ntwo", "one\n\ntwo"),
    .init("one\n\n\n\ntwo", "one\n\ntwo"),
    .init("one  \n  two", "one\ntwo"),
    .init("one\n \n \n two", "one\n\ntwo"),
    .init("one\r\n\r\n\r\ntwo", "one\r\n\r\ntwo"),
    .init("- milk\n  - eggs", "- milk\n- eggs"),
    // Things that must survive untouched.
    .init("See https://example.com/a?b=1&c=2#top , thanks", "See https://example.com/a?b=1&c=2#top, thanks"),
    .init("Visit https://example.com/path.html?q=a,b:c today.", "Visit https://example.com/path.html?q=a,b:c today."),
    .init("Bring snacks, e.g. chips and dip, i.e. the usual.", "Bring snacks, e.g. chips and dip, i.e. the usual."),
    .init("Update the .env file and .gitignore", "Update the .env file and .gitignore"),
    .init("Take .5 mg on port :8080", "Take .5 mg on port :8080"),
    .init("Nice work :tada: team", "Nice work :tada: team"),
    .init("Great job :) and ;-) too", "Great job :) and ;-) too"),
    .init("Is 3.5 > 2.5? Yes.", "Is 3.5 > 2.5? Yes."),
    // Emoji and other scripts.
    .init("Great job 👍🏽  thanks 🎉 !", "Great job 👍🏽 thanks 🎉!"),
    .init("👨‍👩‍👧‍👦   family   time", "👨‍👩‍👧‍👦 family time"),
    .init("Café  naïve , résumé", "Café naïve, résumé"),
    .init("日本語  のテキスト", "日本語 のテキスト"),
    // Nothing left.
    .init("", ""),
    .init("   \n\t \n ", ""),
]

@Suite("TextFinisher")
struct TextFinisherTests {
    @Test(arguments: finishCases)
    func finishesText(_ testCase: FinishCase) {
        #expect(TextFinisher.finish(testCase.input, trailingSpace: false) == testCase.expected)
    }

    @Test(arguments: finishCases)
    func trailingSpaceIsAppendedOnlyToNonEmptyResults(_ testCase: FinishCase) {
        let expected = testCase.expected.isEmpty ? "" : testCase.expected + " "
        #expect(TextFinisher.finish(testCase.input, trailingSpace: true) == expected)
    }

    @Test func trailingSpaceIsASingleSpace() {
        #expect(TextFinisher.finish("Done.   \n\n", trailingSpace: true) == "Done. ")
        #expect(TextFinisher.finish("  ", trailingSpace: true) == "")
    }

    @Test(arguments: finishCases)
    func finishingIsIdempotent(_ testCase: FinishCase) {
        for trailingSpace in [false, true] {
            let once = TextFinisher.finish(testCase.input, trailingSpace: trailingSpace)
            #expect(TextFinisher.finish(once, trailingSpace: trailingSpace) == once)
        }
    }

    @Test(arguments: ["", "   ", "\n\t", "...", "?!", "— –", "👍🏽", "🎉 🎉"])
    func textWithoutLettersOrDigitsIsEffectivelyEmpty(_ text: String) {
        #expect(TextFinisher.isEffectivelyEmpty(text))
    }

    @Test(arguments: ["a", "  7 ", "é", "日本", "ok 👍🏽", "...x"])
    func textWithALetterOrDigitIsNotEffectivelyEmpty(_ text: String) {
        #expect(!TextFinisher.isEffectivelyEmpty(text))
    }
}
