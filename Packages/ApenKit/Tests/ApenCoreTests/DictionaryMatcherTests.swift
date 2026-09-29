import Foundation
import Testing
import ApenCore

private let rls = DictionaryEntry(trigger: "RLS", aliases: ["our LS"], replacement: "row-level security")
private let rlsMatcher = DictionaryMatcher(entries: [rls])
private let api = DictionaryEntry(trigger: "API", replacement: "application programming interface")
private let apiKey = DictionaryEntry(trigger: "API key", replacement: "API key (secret)")

// MARK: - Acronyms and word boundaries

@Suite("Acronym matching")
struct AcronymMatchingTests {
    @Test("Spellings of RLS expand to the replacement", arguments: [
        ("enable RLS now", "enable row-level security now"),
        ("enable rls now", "enable row-level security now"),
        ("enable Rls now", "enable row-level security now"),
        ("enable R.L.S. now", "enable row-level security now"),
        ("enable R. L. S. now", "enable row-level security now"),
        ("enable R.L.S now", "enable row-level security now"),
        ("enable R L S now", "enable row-level security now"),
        ("enable RLS, then test", "enable row-level security, then test"),
        ("check (RLS) first", "check (row-level security) first"),
        ("enable RLS's policies", "enable row-level security's policies"),
        ("enable RLS\u{2019}s policies", "enable row-level security\u{2019}s policies"),
        ("enable our LS", "enable row-level security"),
        ("enable our LS now", "enable row-level security now"),
        ("enable Our ls now", "enable row-level security now"),
        ("RLS-based access", "Row-level security-based access"),
    ])
    func expandsSpellings(input: String, expected: String) {
        #expect(rlsMatcher.expand(input) == expected)
    }

    @Test("Spellings and aliases of RLS normalize to the trigger", arguments: [
        ("enable rls now", "enable RLS now"),
        ("enable R.L.S. now", "enable RLS now"),
        ("enable R. L. S. now", "enable RLS now"),
        ("enable R L S now", "enable RLS now"),
        ("enable our LS", "enable RLS"),
        ("enable RLS's policies", "enable RLS's policies"),
        ("R.L.S. policies are on", "RLS policies are on"),
    ])
    func normalizesSpellings(input: String, expected: String) {
        #expect(rlsMatcher.normalize(input) == expected)
    }

    @Test("A dotted acronym that ends the sentence keeps the period", arguments: [
        ("We need R.L.S.", "We need RLS.", "We need row-level security."),
        ("We need R.L.S.  ", "We need RLS.  ", "We need row-level security.  "),
        ("We need R.L.S.\nThen ship", "We need RLS.\nThen ship", "We need row-level security.\nThen ship"),
        ("We need R.L.S. Then ship", "We need RLS. Then ship", "We need row-level security. Then ship"),
        ("The R.L.S. policies are on", "The RLS policies are on", "The row-level security policies are on"),
        ("Did we ship R.L.S.? Yes", "Did we ship RLS? Yes", "Did we ship row-level security? Yes"),
        ("After R.L.S., ship", "After RLS, ship", "After row-level security, ship"),
        ("We need RLS.", "We need RLS.", "We need row-level security."),
        ("We need R.L.S", "We need RLS", "We need row-level security"),
    ])
    func sentencePeriod(input: String, normalized: String, expanded: String) {
        #expect(rlsMatcher.normalize(input) == normalized)
        #expect(rlsMatcher.expand(input) == expanded)
    }

    @Test("A dotted acronym at the start of text is capitalized without a stray dot")
    func dottedAcronymAtStart() {
        #expect(rlsMatcher.expand("R.L.S. policies are on") == "Row-level security policies are on")
    }

    @Test("Partial words and longer acronyms are left alone", arguments: [
        "check the URLS list",
        "XRLS", "RLSX", "RLS2", "2RLS", "_RLS", "RLS_x", "cafeRLS", "RLSé",
        "U.R.L.S.", "R.L.S.X.", "r.l.s.", "our LSD", "hour LS",
        "日本語RLS",
    ])
    func leavesPartialWordsAlone(input: String) {
        #expect(rlsMatcher.expand(input) == input)
        #expect(rlsMatcher.normalize(input) == input)
    }

    @Test("Lowercase dotted abbreviations are not acronym spellings")
    func lowercaseDottedAbbreviations() {
        let matcher = DictionaryMatcher(entries: [DictionaryEntry(trigger: "PM", replacement: "product manager")])
        #expect(matcher.expand("at 3 p.m. the PM left") == "at 3 p.m. the product manager left")
        #expect(matcher.expand("ask the P.M. today") == "ask the product manager today")
    }

    @Test("Acronyms with digits")
    func acronymsWithDigits() {
        let matcher = DictionaryMatcher(entries: [
            DictionaryEntry(trigger: "K8S", replacement: "Kubernetes"),
            DictionaryEntry(trigger: "GPT4", aliases: ["GPT four"]),
        ])
        #expect(matcher.expand("the k8s cluster") == "the Kubernetes cluster")
        #expect(matcher.normalize("ask gpt four or G.P.T.4. today") == "ask GPT4 or GPT4 today")
    }
}

// MARK: - Overlaps, recursion and literal output

@Suite("Match selection")
struct MatchSelectionTests {
    @Test("Longest form wins regardless of entry order", arguments: [[api, apiKey], [apiKey, api]])
    func longestFormWins(entries: [DictionaryEntry]) {
        let matcher = DictionaryMatcher(entries: entries)
        #expect(matcher.expand("my API key") == "my API key (secret)")
        #expect(matcher.expand("my api-key") == "my API key (secret)")
        #expect(matcher.expand("my API docs") == "my application programming interface docs")
        // "API key" cannot end inside "keys", so the shorter form takes over.
        #expect(matcher.expand("my API keys") == "my application programming interface keys")
    }

    @Test("Replacements are not expanded again")
    func noRecursion() {
        let matcher = DictionaryMatcher(entries: [
            DictionaryEntry(trigger: "A1", replacement: "B2"),
            DictionaryEntry(trigger: "B2", replacement: "C3"),
        ])
        #expect(matcher.expand("A1") == "B2")
        #expect(matcher.expand("A1 B2") == "B2 C3")
    }

    @Test("The earlier entry wins when two entries share a form")
    func earlierEntryWins() {
        let matcher = DictionaryMatcher(entries: [
            DictionaryEntry(trigger: "RLS", replacement: "first"),
            DictionaryEntry(trigger: "rls", replacement: "second"),
        ])
        #expect(matcher.expand("use rls") == "use first")
    }

    @Test("Forms that differ only in case or separators map to their own entries")
    func similarFormsStayDistinct() {
        let matcher = DictionaryMatcher(entries: [
            DictionaryEntry(trigger: "US", replacement: "United States", caseSensitive: true),
            DictionaryEntry(trigger: "us", replacement: "microseconds", caseSensitive: true),
            DictionaryEntry(trigger: "pullrequest", replacement: "one word"),
            DictionaryEntry(trigger: "pull request", replacement: "two words"),
        ])
        #expect(matcher.expand("the US took 5 us") == "the United States took 5 microseconds")
        #expect(matcher.expand("a pullrequest or a pull-request") == "a one word or a two words")
    }

    @Test("Replacement text is inserted literally")
    func literalReplacement() {
        let template = #"$1 \ \\ \1 $0 ${name} &"#
        let matcher = DictionaryMatcher(entries: [DictionaryEntry(trigger: "price tag", replacement: template)])
        #expect(matcher.expand("the price tag here") == "the \(template) here")
        #expect(matcher.expand("price tag") == template)
    }

    @Test("Multi-line replacements are inserted as-is")
    func multiLineReplacement() {
        let signature = "Best regards,\nMiles\n\n\u{2014} sent by voice"
        let matcher = DictionaryMatcher(entries: [DictionaryEntry(trigger: "sign off", replacement: signature)])
        #expect(matcher.expand("Thanks! sign off") == "Thanks! \(signature)")
        #expect(matcher.expand("sign off") == signature)
    }

    @Test("A replacement ending in a period absorbs the sentence's period")
    func replacementEndingInPeriod() {
        let matcher = DictionaryMatcher(entries: [DictionaryEntry(trigger: "and so on", replacement: "etc.")])
        #expect(matcher.expand("apples, pears and so on.") == "apples, pears etc.")
        #expect(matcher.expand("apples and so on, pears") == "apples etc., pears")
    }

    @Test("Regex metacharacters in forms match literally", arguments: [
        ("a.b", "AB", "use a.b now", "use AB now", "use axb now"),
        ("(beta)", "[beta]", "the (beta) build", "the [beta] build", "the beta build"),
        ("x|y", "either", "pick x|y", "pick either", "pick x"),
        ("1+1", "two", "is 1+1 hard", "is two hard", "is 11 hard"),
        ("[wip]", "WIP", "a [wip] fix", "a WIP fix", "a w fix"),
        ("^_^", "smile", "ok ^_^ bye", "ok smile bye", "ok ^^ bye"),
    ])
    func metacharacters(trigger: String, replacement: String, input: String, expected: String, untouched: String) {
        let matcher = DictionaryMatcher(entries: [DictionaryEntry(trigger: trigger, replacement: replacement)])
        #expect(matcher.expand(input) == expected)
        #expect(matcher.expand(untouched) == untouched)
    }
}

// MARK: - Forms and entry options

@Suite("Entry options")
struct EntryOptionTests {
    @Test("Whitespace and hyphen runs inside a form are interchangeable", arguments: [
        ("open a pull request", "open a PR"),
        ("open a pull-request", "open a PR"),
        ("open a pull  request", "open a PR"),
        ("open a pull - request", "open a PR"),
        ("open a Pull Request", "open a PR"),
        ("open a pull\nrequest", "open a PR"),
        ("open a pullrequest", "open a pullrequest"),
        ("open pull requests", "open pull requests"),
    ])
    func separatorRuns(input: String, expected: String) {
        let matcher = DictionaryMatcher(entries: [DictionaryEntry(trigger: "pull request", replacement: "PR")])
        #expect(matcher.expand(input) == expected)
    }

    @Test("A hyphenated trigger matches spaced speech")
    func hyphenatedTrigger() {
        let matcher = DictionaryMatcher(entries: [DictionaryEntry(trigger: "row-level", aliases: ["roll level"])])
        #expect(matcher.normalize("a row level policy and a roll-level one") == "a row-level policy and a row-level one")
    }

    @Test("Case-sensitive entries only match the typed casing")
    func caseSensitive() {
        let matcher = DictionaryMatcher(entries: [
            DictionaryEntry(trigger: "US", replacement: "United States", caseSensitive: true),
        ])
        #expect(matcher.expand("the US and us") == "the United States and us")
        #expect(matcher.expand("tell us") == "tell us")
        #expect(matcher.expand("Us too") == "Us too")
        #expect(matcher.expand("the U.S. market") == "the United States market")
        #expect(matcher.normalize("the U.S. market") == "the US market")
    }

    @Test("Vocabulary-only entries write the trigger spelling in both passes")
    func vocabularyOnly() {
        let matcher = DictionaryMatcher(entries: [DictionaryEntry(trigger: "Supabase", aliases: ["super base"])])
        let input = "we use super base and supabase"
        #expect(matcher.normalize(input) == "we use Supabase and Supabase")
        #expect(matcher.expand(input) == "we use Supabase and Supabase")
        #expect(matcher.expand("SUPABASE rocks. super-base too.") == "Supabase rocks. Supabase too.")
    }

    @Test("Disabled entries and blank triggers are ignored")
    func disabledAndBlank() {
        let ignored = DictionaryMatcher(entries: [
            DictionaryEntry(trigger: "RLS", replacement: "row-level security", enabled: false),
            DictionaryEntry(trigger: "   ", aliases: ["blank"], replacement: "nothing"),
            DictionaryEntry(trigger: "", replacement: "nothing"),
        ])
        #expect(ignored.isEmpty)
        #expect(ignored.keepVerbatimTerms.isEmpty)
        #expect(ignored.expand("RLS blank") == "RLS blank")

        let mixed = DictionaryMatcher(entries: [
            DictionaryEntry(trigger: "RLS", replacement: "disabled", enabled: false),
            DictionaryEntry(trigger: "RLS", replacement: "enabled"),
        ])
        #expect(!mixed.isEmpty)
        #expect(mixed.expand("use RLS") == "use enabled")
    }

    @Test("Blank aliases are ignored and forms are trimmed")
    func trimmedForms() {
        let matcher = DictionaryMatcher(entries: [
            DictionaryEntry(trigger: "  Supabase ", aliases: ["", "   ", " super base "]),
        ])
        #expect(matcher.normalize("super base") == "Supabase")
        #expect(matcher.keepVerbatimTerms == ["Supabase"])
    }

    @Test("Triggers that start or end with symbols")
    func symbolTriggers() {
        let matcher = DictionaryMatcher(entries: [
            DictionaryEntry(trigger: "C++", aliases: ["C plus plus"]),
            DictionaryEntry(trigger: ".NET", replacement: "dotnet"),
            DictionaryEntry(trigger: "C#", replacement: "C sharp"),
        ])
        #expect(matcher.expand("I love C++ code") == "I love C++ code")
        #expect(matcher.normalize("I love c plus plus code") == "I love C++ code")
        #expect(matcher.normalize("I love c++.") == "I love C++.")
        #expect(matcher.expand("we ship .NET apps in C#") == "we ship dotnet apps in C sharp")
        #expect(matcher.expand(".NET first") == "Dotnet first")
        #expect(matcher.expand("ABC++ and .NETCore stay") == "ABC++ and .NETCore stay")
    }

    @Test("C++ with a replacement")
    func cPlusPlusReplacement() {
        let matcher = DictionaryMatcher(entries: [DictionaryEntry(trigger: "C++", replacement: "C plus plus")])
        #expect(matcher.expand("I love C++ code") == "I love C plus plus code")
        #expect(matcher.expand("I love c++.") == "I love C plus plus.")
    }
}

// MARK: - Capitalization

@Suite("Sentence-start capitalization")
struct CapitalizationTests {
    @Test("Lowercase replacements are capitalized at the start of a sentence", arguments: [
        ("RLS is on.", "Row-level security is on."),
        ("  RLS is on", "  Row-level security is on"),
        ("It works. RLS is on.", "It works. Row-level security is on."),
        ("Is it on? RLS is on.", "Is it on? Row-level security is on."),
        ("Yes! RLS is on.", "Yes! Row-level security is on."),
        ("First line\nRLS is on", "First line\nRow-level security is on"),
        ("First line\n  RLS is on", "First line\n  Row-level security is on"),
        ("He said \"stop.\" RLS is on", "He said \"stop.\" Row-level security is on"),
        ("RLS. RLS again", "Row-level security. Row-level security again"),
    ])
    func capitalizesAtSentenceStart(input: String, expected: String) {
        #expect(rlsMatcher.expand(input) == expected)
    }

    @Test("Mid-sentence replacements stay lowercase", arguments: [
        ("we enable RLS today", "we enable row-level security today"),
        ("It works.RLS is on", "It works.row-level security is on"),
        ("so, RLS is on", "so, row-level security is on"),
        // The earlier dot was consumed and not re-added, so the second match is mid-sentence.
        ("R.L.S. rls is on", "Row-level security row-level security is on"),
    ])
    func staysLowercaseMidSentence(input: String, expected: String) {
        #expect(rlsMatcher.expand(input) == expected)
    }

    @Test("Replacements whose first word is not all lowercase are never changed")
    func mixedCaseReplacement() {
        let matcher = DictionaryMatcher(entries: [
            DictionaryEntry(trigger: "eye oh ess", replacement: "iOS"),
            DictionaryEntry(trigger: "e g", replacement: "e.g. this"),
        ])
        #expect(matcher.expand("eye oh ess is great. eye oh ess rocks") == "iOS is great. iOS rocks")
        #expect(matcher.expand("e g works") == "e.g. this works")
    }

    @Test("Vocabulary-only entries and normalize never change capitalization")
    func noCapitalizationChanges() {
        let matcher = DictionaryMatcher(entries: [
            DictionaryEntry(trigger: "kubectl", aliases: ["cube control"]),
            DictionaryEntry(trigger: "rls", replacement: "row-level security"),
        ])
        #expect(matcher.expand("cube control works. Kubectl too") == "kubectl works. kubectl too")
        #expect(matcher.normalize("RLS is on. cube control too") == "rls is on. kubectl too")
        #expect(matcher.expand("RLS is on") == "Row-level security is on")
    }
}

// MARK: - Unicode

@Suite("Unicode text")
struct UnicodeTests {
    @Test("Matches next to emoji, accents and other scripts", arguments: [
        ("caf\u{E9} \u{1F680} RLS \u{2705}", "caf\u{E9} \u{1F680} row-level security \u{2705}"),
        ("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} RLS \u{65E5}\u{672C}\u{8A9E} RLS \u{D55C}\u{AD6D}\u{C5B4}",
         "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} row-level security \u{65E5}\u{672C}\u{8A9E} row-level security \u{D55C}\u{AD6D}\u{C5B4}"),
        ("na\u{EF}ve RLS\u{2014}done \u{1F389}", "na\u{EF}ve row-level security\u{2014}done \u{1F389}"),
        ("\u{1F680}RLS\u{1F680}", "\u{1F680}row-level security\u{1F680}"),
        ("caf\u{E9} \u{1F680} R.L.S.", "caf\u{E9} \u{1F680} row-level security."),
    ])
    func matchesAroundUnicode(input: String, expected: String) {
        #expect(rlsMatcher.expand(input) == expected)
    }

    @Test("Normalize preserves surrounding Unicode")
    func normalizeAroundUnicode() {
        #expect(rlsMatcher.normalize("caf\u{E9} \u{1F680} R.L.S. \u{2705} our LS \u{1F1FA}\u{1F1F8}")
            == "caf\u{E9} \u{1F680} RLS \u{2705} RLS \u{1F1FA}\u{1F1F8}")
    }

    @Test("Accented triggers match case-insensitively, including decomposed spellings")
    func accentedTriggers() {
        let matcher = DictionaryMatcher(entries: [
            DictionaryEntry(trigger: "Zo\u{EB}", aliases: ["zoe"]),
            DictionaryEntry(trigger: "creme brulee", replacement: "cr\u{E8}me br\u{FB}l\u{E9}e"),
            DictionaryEntry(trigger: "Ame\u{301}lie", replacement: "Am\u{E9}lie Poulain"),
        ])
        #expect(matcher.normalize("zoe and ZO\u{CB} said hi") == "Zo\u{EB} and Zo\u{EB} said hi")
        #expect(matcher.expand("I ordered creme brulee \u{1F36E}") == "I ordered cr\u{E8}me br\u{FB}l\u{E9}e \u{1F36E}")
        #expect(matcher.expand("ask am\u{E9}lie") == "ask Am\u{E9}lie Poulain")
        // A decomposed accent continues the word, so "cafe" does not match inside "cafe\u{301}".
        let cafe = DictionaryMatcher(entries: [DictionaryEntry(trigger: "cafe", replacement: "coffee shop")])
        #expect(cafe.expand("the cafe\u{301} opens").unicodeScalars.elementsEqual("the cafe\u{301} opens".unicodeScalars))
        #expect(cafe.expand("the cafe opens") == "the coffee shop opens")
    }

    @Test("Triggers containing emoji")
    func emojiTrigger() {
        let matcher = DictionaryMatcher(entries: [DictionaryEntry(trigger: "ship it \u{1F680}", replacement: "deploy")])
        #expect(matcher.expand("time to ship it \u{1F680} now") == "time to deploy now")
    }
}

// MARK: - Matcher surface

@Suite("Matcher surface")
struct MatcherSurfaceTests {
    @Test("An empty matcher returns text unchanged")
    func emptyMatcher() {
        let matcher = DictionaryMatcher(entries: [])
        let text = "We need R.L.S. \u{1F680}\nOK"
        #expect(matcher.isEmpty)
        #expect(matcher.keepVerbatimTerms.isEmpty)
        #expect(matcher.normalize(text) == text)
        #expect(matcher.expand(text) == text)
        #expect(matcher.expand("") == "")
    }

    @Test("A matcher can be shared across concurrent tasks")
    func concurrentUse() async {
        let results = await withTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask { rlsMatcher.expand("We need R.L.S.") }
            }
            var collected: [String] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        #expect(results == Array(repeating: "We need row-level security.", count: 8))
    }

    @Test("Text without matches comes back unchanged")
    func noMatches() {
        let text = "Nothing to see \u{1F440} here.\n"
        #expect(rlsMatcher.expand(text) == text)
        #expect(rlsMatcher.normalize(text) == text)
        #expect(rlsMatcher.expand("") == "")
    }

    @Test("keepVerbatimTerms lists enabled triggers once, in entry order")
    func keepVerbatimTerms() {
        let matcher = DictionaryMatcher(entries: [
            DictionaryEntry(trigger: " RLS ", replacement: "row-level security"),
            DictionaryEntry(trigger: "Supabase", aliases: ["super base"]),
            DictionaryEntry(trigger: "RLS", replacement: "something else"),
            DictionaryEntry(trigger: "Disabled", enabled: false),
            DictionaryEntry(trigger: "  "),
            DictionaryEntry(trigger: "pull request", replacement: "PR"),
            DictionaryEntry(trigger: "rls"),
        ])
        #expect(matcher.keepVerbatimTerms == ["RLS", "Supabase", "pull request", "rls"])
    }
}

// MARK: - DictionaryEntry

@Suite("DictionaryEntry")
struct DictionaryEntryTests {
    @Test("boost defaults to long or multi-word triggers", arguments: [
        ("RLS", false), ("API", false), ("US", false), ("K8S", false), ("  RLS  ", false),
        ("GPT4", true), ("Supabase", true), ("pull request", true), ("a b", true),
    ])
    func boostDefault(trigger: String, expected: Bool) {
        #expect(DictionaryEntry(trigger: trigger).boost == expected)
    }

    @Test("An explicit boost wins")
    func explicitBoost() {
        #expect(DictionaryEntry(trigger: "RLS", boost: true).boost)
        #expect(!DictionaryEntry(trigger: "Supabase", boost: false).boost)
    }

    @Test("Defaults")
    func defaults() {
        let entry = DictionaryEntry(trigger: "RLS")
        #expect(entry.id == nil)
        #expect(entry.aliases.isEmpty)
        #expect(entry.replacement.isEmpty)
        #expect(!entry.caseSensitive)
        #expect(entry.enabled)
    }

    @Test("isVocabularyOnly means the replacement is blank", arguments: [
        ("", true), ("   ", true), ("\n\t", true), ("row-level security", false), (" x ", false),
    ])
    func vocabularyOnly(replacement: String, expected: Bool) {
        #expect(DictionaryEntry(trigger: "RLS", replacement: replacement).isVocabularyOnly == expected)
    }

    @Test("Codable round trip", arguments: [
        DictionaryEntry(id: 42, trigger: "RLS", aliases: ["our LS", "are L S"], replacement: "row-level security",
                        caseSensitive: true, boost: true, enabled: false),
        DictionaryEntry(trigger: "Supabase", aliases: ["super base"]),
        DictionaryEntry(trigger: "sign off", replacement: "Best,\nMiles \u{1F680}"),
    ])
    func codableRoundTrip(entry: DictionaryEntry) throws {
        let data = try JSONEncoder().encode(entry)
        #expect(try JSONDecoder().decode(DictionaryEntry.self, from: data) == entry)
    }

    @Test("Decoding fills in missing fields with the usual defaults")
    func decodesMinimalJSON() throws {
        let short = try JSONDecoder().decode(DictionaryEntry.self, from: Data(#"{"trigger":"RLS"}"#.utf8))
        #expect(short == DictionaryEntry(trigger: "RLS"))
        #expect(!short.boost)
        let long = try JSONDecoder().decode(DictionaryEntry.self, from: Data(#"{"id":7,"trigger":"Supabase"}"#.utf8))
        #expect(long == DictionaryEntry(id: 7, trigger: "Supabase"))
        #expect(long.boost)
    }
}

// MARK: - Scale

@Suite("Scale")
struct ScaleTests {
    /// Deterministic filler and triggers that cannot collide: filler words have at most five letters, triggers six
    /// or more.
    private static let filler = ["the", "and", "we", "need", "to", "ship", "it", "now", "with", "data", "plan", "team",
                                 "caf\u{E9}", "\u{1F680}", "that", "is", "fine.", "Then", "move", "on,", "done!"]

    private static func word(_ seed: Int, length: Int) -> String {
        var state = UInt64(truncatingIfNeeded: seed) &* 6364136223846793005 &+ 1442695040888963407
        var letters = ""
        for _ in 0..<length {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            letters.unicodeScalars.append(Unicode.Scalar(UInt8(97 + (state >> 33) % 26)))
        }
        return letters
    }

    @Test("Large dictionaries over long texts replace every occurrence",
          .timeLimit(.minutes(1)),
          arguments: [(300, 10_000), (500, 8_000)])
    func largeInputs(entryCount: Int, wordCount: Int) {
        var entries: [DictionaryEntry] = []
        var spoken: [String] = []
        for index in 0..<entryCount {
            let marker = "\u{27E6}\(index)\u{27E7}"
            switch index % 3 {
            case 0:
                let acronym = Self.word(index, length: 4).uppercased() + "\(index % 10)"
                entries.append(DictionaryEntry(trigger: acronym, replacement: marker))
                spoken.append(acronym.map(String.init).joined(separator: ".") + ".")
            case 1:
                let phrase = Self.word(index, length: 6) + " " + Self.word(index + 7_919, length: 7)
                entries.append(DictionaryEntry(trigger: Self.word(index, length: 9), aliases: [phrase],
                                               replacement: marker))
                spoken.append(phrase.replacingOccurrences(of: " ", with: "-"))
            default:
                let trigger = Self.word(index, length: 8)
                entries.append(DictionaryEntry(trigger: trigger, replacement: marker))
                spoken.append(trigger.uppercased())
            }
        }
        let matcher = DictionaryMatcher(entries: entries)

        var words: [String] = []
        var inserted = 0
        for position in 0..<wordCount {
            if position % 10 == 5 {
                words.append(spoken[inserted % spoken.count])
                inserted += 1
            } else {
                words.append(Self.filler[position % Self.filler.count])
            }
        }
        let text = words.joined(separator: " ")

        let expanded = matcher.expand(text)
        #expect(expanded.unicodeScalars.filter { $0 == "\u{27E6}" }.count == inserted)
        #expect(!expanded.contains(spoken[0]))

        let normalized = matcher.normalize(text)
        #expect(normalized.contains(entries[0].trigger))
        #expect(!normalized.contains(spoken[0]))
        #expect(matcher.normalize(normalized) == normalized)
    }

    @Test("Dictionaries whose triggers start with hundreds of different characters", .timeLimit(.minutes(1)))
    func manyFirstCharacters() {
        var entries: [DictionaryEntry] = []
        var spoken: [String] = []
        for index in 0..<400 {
            var trigger = String.UnicodeScalarView()
            trigger.append(Unicode.Scalar(0x4E00 + UInt32(index))!)
            trigger.append(Unicode.Scalar(0x5E00 + UInt32(index))!)
            entries.append(DictionaryEntry(trigger: String(trigger), replacement: "\u{27E6}\(index)\u{27E7}"))
            spoken.append(String(trigger))
        }
        entries += [
            DictionaryEntry(trigger: "\u{41F}\u{440}\u{438}\u{432}\u{435}\u{442}", replacement: "\u{27E6}hello\u{27E7}"),
            DictionaryEntry(trigger: "\u{3A3}\u{3BF}\u{3C6}\u{3AF}\u{3B1}", replacement: "\u{27E6}sofia\u{27E7}"),
            DictionaryEntry(trigger: "RLS", replacement: "\u{27E6}rls\u{27E7}"),
        ]
        // Lowercase Cyrillic, uppercase Greek and a dotted acronym.
        spoken += ["\u{43F}\u{440}\u{438}\u{432}\u{435}\u{442}", "\u{3A3}\u{39F}\u{3A6}\u{38A}\u{391}", "R.L.S."]
        let matcher = DictionaryMatcher(entries: entries)

        let text = spoken.enumerated().map { $0.offset.isMultiple(of: 2) ? $0.element + "\u{3001}" : $0.element }
            .joined(separator: " ")
        let expanded = matcher.expand(text)
        #expect(expanded.unicodeScalars.filter { $0 == "\u{27E6}" }.count == spoken.count)
        #expect(expanded.contains("\u{27E6}hello\u{27E7}") && expanded.contains("\u{27E6}sofia\u{27E7}"))
        // The last item is "R.L.S.、": the dotted acronym's dot is consumed, and "、" does not end a sentence.
        #expect(matcher.normalize(text).hasSuffix("\u{3A3}\u{3BF}\u{3C6}\u{3AF}\u{3B1} RLS\u{3001}"))
    }
}
