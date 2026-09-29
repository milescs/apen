import Foundation

/// Applies the personal dictionary to transcribed text.
///
/// Both passes share one matcher and differ only in what they write for a match:
/// - ``normalize(_:)`` runs on raw recognizer output, before the LLM cleanup pass, and writes the entry's trigger
///   spelling. ``keepVerbatimTerms`` then tells the LLM to leave those spellings alone.
/// - ``expand(_:)`` runs last and writes the entry's replacement (or the trigger spelling for vocabulary-only
///   entries).
///
/// Matching rules:
/// - Each enabled entry with a non-blank trigger contributes its trimmed trigger and non-blank aliases ("forms"),
///   matched case-insensitively unless the entry is case-sensitive.
/// - Forms match whole words only. A form that begins with a letter, mark, digit or underscore must not follow one;
///   a match that ends with one must not be followed by one. "C++" and ".NET" therefore still match, "URLS" does not
///   match "RLS", and "RLS's" does.
/// - Inside a form, any run of whitespace and hyphens matches any such run ("pull request" matches "pull-request").
/// - Acronym-like forms (2–10 uppercase ASCII letters or digits, at least two letters) also match uppercase dotted
///   and spaced spellings such as "R.L.S.", "R. L. S." and "R L S". When the consumed final dot also ended the
///   sentence, the written text gets a period back.
/// - When forms overlap at the same position, the longest form wins; ties go to the earlier entry. Matching is a
///   single left-to-right pass, so written text is never matched again, and it is inserted literally.
/// - `expand` capitalizes a replacement at the start of a sentence when its first word is all lowercase letters
///   (hyphens allowed): "RLS is on." becomes "Row-level security is on.".
public struct DictionaryMatcher: Sendable {
    /// Trigger spellings of every enabled entry, trimmed and de-duplicated in entry order.
    public let keepVerbatimTerms: [String]

    /// One regular expression over every form, scanned once left to right. It has no capture groups and no per-form
    /// look-arounds: on every match attempt ICU resets all capture and look-around slots, and it copies the capture
    /// frame on every backtracking save, so one capture group per form made scanning hundreds of times slower. The
    /// form that matched is identified afterwards by `form(forMatch:)`.
    private let scanner: NSRegularExpression?
    /// Every form in priority order: longest first, then entry order, then trigger before aliases.
    private let forms: [CompiledForm]
    /// Indices into `forms`, in priority order, keyed by `identityKey(_:)`.
    private let formIndicesByKey: [String: [Int]]
    private let outputs: [EntryOutput]

    /// True when no entry can match, so both passes return their input unchanged.
    public var isEmpty: Bool { scanner == nil }

    /// Ignores disabled entries and entries whose trigger is blank.
    public init(entries: [DictionaryEntry]) {
        var outputs: [EntryOutput] = []
        var terms: [String] = []
        var seenTerms = Set<String>()
        var specs: [FormSpec] = []

        for entry in entries where entry.enabled {
            let spelling = entry.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spelling.isEmpty else { continue }
            let entryIndex = outputs.count
            outputs.append(EntryOutput(entry, spelling: spelling))
            if seenTerms.insert(spelling).inserted {
                terms.append(spelling)
            }

            var seenForms = Set<String>()
            for candidate in [spelling] + entry.aliases {
                let form = candidate.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
                let identity = entry.caseSensitive ? form : form.folding(options: .caseInsensitive, locale: nil)
                guard !form.isEmpty, seenForms.insert(identity).inserted,
                      let spec = FormSpec(form, caseSensitive: entry.caseSensitive, entry: entryIndex, rank: specs.count)
                else { continue }
                specs.append(spec)
            }
        }

        specs.sort { $0.length != $1.length ? $0.length > $1.length : $0.rank < $1.rank }

        var forms: [CompiledForm] = []
        var formIndicesByKey: [String: [Int]] = [:]
        var wordStart = BucketList()
        var otherStart = BucketList()
        for spec in specs {
            guard let verifier = try? NSRegularExpression(pattern: #"\A(?:"# + spec.pattern + #")\z"#) else { continue }
            formIndicesByKey[spec.identityKey, default: []].append(forms.count)
            forms.append(CompiledForm(entry: spec.entry, isAcronym: spec.isAcronym, verifier: verifier))
            if spec.startsWithWordCharacter {
                wordStart.add(spec)
            } else {
                otherStart.add(spec)
            }
        }

        self.keepVerbatimTerms = terms
        self.outputs = outputs
        self.forms = forms
        self.formIndicesByKey = formIndicesByKey
        self.scanner = Self.makeScanner(wordStart: wordStart, otherStart: otherStart)
    }

    /// Maps aliases and variant spellings to each entry's trigger spelling exactly as the user typed it.
    /// Runs on raw speech-recognition text, before the LLM cleanup pass. Never changes capitalization.
    public func normalize(_ text: String) -> String {
        rewrite(text, expanding: false)
    }

    /// Maps triggers, aliases and variants to each entry's replacement, or to the exact trigger spelling for
    /// vocabulary-only entries. Runs as the last step.
    public func expand(_ text: String) -> String {
        rewrite(text, expanding: true)
    }

    // MARK: - Rewriting

    private func rewrite(_ text: String, expanding: Bool) -> String {
        guard let scanner, !text.isEmpty else { return text }
        let utf16 = text.utf16
        let matches = scanner.matches(in: text, options: [], range: NSRange(location: 0, length: utf16.count))
        guard !matches.isEmpty else { return text }

        var output = ""
        output.reserveCapacity(text.utf8.count)
        // Walk UTF-16 offsets forward instead of converting each NSRange from the start of the string. ICU matches
        // whole code points, so these indices always fall on Unicode scalar boundaries.
        var copiedUpTo = text.startIndex
        var walked = text.startIndex
        var walkedOffset = 0
        for match in matches {
            let lower = utf16.index(walked, offsetBy: match.range.location - walkedOffset)
            let upper = utf16.index(lower, offsetBy: match.range.length)
            walked = upper
            walkedOffset = match.range.location + match.range.length

            let matched = String(text[lower..<upper])
            guard let form = form(forMatch: matched),
                  !(form.isAcronym && Self.isInsideLongerDottedAcronym(
                      matched, preceding: text.unicodeScalars[..<lower], following: text.unicodeScalars[upper...]))
            else { continue }
            output += text[copiedUpTo..<lower]
            output += Self.writtenText(
                for: outputs[form.entry],
                matched: matched,
                expanding: expanding,
                after: output,
                before: text.unicodeScalars[upper...]
            )
            copiedUpTo = upper
        }
        output += text[copiedUpTo...]
        return output
    }

    /// The form that produced `matched`.
    ///
    /// The scanner tries forms in priority order and stops at the first that matches, so the first form in that
    /// order that matches the whole matched text is the one that fired. Boundary checks live outside the forms and
    /// depend only on the matched range, so they hold for every candidate equally.
    private func form(forMatch matched: String) -> CompiledForm? {
        let whole = NSRange(location: 0, length: matched.utf16.count)
        func matchesWhole(_ form: CompiledForm) -> Bool {
            form.verifier.rangeOfFirstMatch(in: matched, options: [], range: whole).location != NSNotFound
        }
        if let candidates = formIndicesByKey[Self.identityKey(matched)],
           let index = candidates.first(where: { matchesWhole(forms[$0]) }) {
            return forms[index]
        }
        // Only reached if Foundation's and ICU's case folding disagree about the matched text.
        return forms.first(where: matchesWhole)
    }

    /// True for a dotted spelling that is part of a longer dotted acronym: "R.L.S." inside "U.R.L.S." or
    /// "R.L.S.X.". Checked here instead of with look-arounds in each acronym's pattern (see `scanner`).
    private static func isInsideLongerDottedAcronym(
        _ matched: String,
        preceding: Substring.UnicodeScalarView,
        following: Substring.UnicodeScalarView
    ) -> Bool {
        guard matched.unicodeScalars.contains(".") else { return false }
        func isASCIIAlphanumeric(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar else { return false }
            return ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        var before = preceding.reversed().makeIterator()
        if before.next() == ".", isASCIIAlphanumeric(before.next()) {
            return true
        }
        var after = following.makeIterator()
        if matched.unicodeScalars.last == "." {
            return isASCIIAlphanumeric(after.next())
        }
        return after.next() == "." && isASCIIAlphanumeric(after.next())
    }

    private static func writtenText(
        for output: EntryOutput,
        matched: String,
        expanding: Bool,
        after preceding: String,
        before following: Substring.UnicodeScalarView
    ) -> String {
        var written: String
        if expanding, let replacement = output.replacement {
            if let sentenceCase = output.sentenceCaseReplacement, startsSentence(after: preceding) {
                written = sentenceCase
            } else {
                written = replacement
            }
        } else {
            written = output.spelling
        }

        if written.unicodeScalars.last == ".", following.first == "." {
            // "and so on." → "etc." rather than "etc..".
            written.unicodeScalars.removeLast()
        } else if matched.unicodeScalars.last == ".",
                  let last = written.unicodeScalars.last, !terminalPunctuation.contains(last),
                  endsSentence(before: following) {
            // The dotted acronym swallowed the sentence's period ("We need R.L.S." → "We need RLS.").
            written += "."
        }
        return written
    }

    /// Start of text (ignoring whitespace), after a line break, or after ".", "!" or "?" (optionally followed by
    /// closing quotes or brackets) and whitespace. Checks the text already written, not the input, so an earlier
    /// replacement that dropped a dot does not start a sentence.
    private static func startsSentence(after preceding: String) -> Bool {
        var sawWhitespace = false
        var scalars = preceding.unicodeScalars.reversed().makeIterator()
        while let scalar = scalars.next() {
            if lineBreaks.contains(scalar) { return true }
            if scalar.properties.isWhitespace {
                sawWhitespace = true
                continue
            }
            guard sawWhitespace else { return false }
            var candidate: Unicode.Scalar? = scalar
            while let closing = candidate, closingPunctuation.contains(closing) {
                candidate = scalars.next()
            }
            guard let terminator = candidate else { return false }
            return sentenceTerminators.contains(terminator)
        }
        return true
    }

    /// End of text, a line break, or whitespace followed by an uppercase letter.
    private static func endsSentence(before following: Substring.UnicodeScalarView) -> Bool {
        var sawWhitespace = false
        for scalar in following {
            if lineBreaks.contains(scalar) { return true }
            if scalar.properties.isWhitespace {
                sawWhitespace = true
                continue
            }
            return sawWhitespace && scalar.properties.isUppercase
        }
        return true
    }

    private static let lineBreaks: Set<Unicode.Scalar> = ["\n", "\r", "\u{85}", "\u{2028}", "\u{2029}"]
    private static let sentenceTerminators: Set<Unicode.Scalar> = [".", "!", "?"]
    private static let terminalPunctuation: Set<Unicode.Scalar> = [".", "!", "?", "\u{2026}"]
    private static let closingPunctuation: Set<Unicode.Scalar> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "\u{BB}"]

    // MARK: - Building

    /// Word characters for the boundary checks. Marks are included so that a decomposed accent continues a word.
    private static let wordCharacter = #"[\p{L}\p{M}\p{N}_]"#

    /// `(?:(?<!W)(?:word-start forms)|(?:other forms))(?:(?<!W)|(?!W))`, each set of forms dispatched by `BucketList`.
    ///
    /// The leading lookbehind applies only to forms that begin with a word character. The trailing check says the
    /// match may not end between two word characters, which is the per-form rule "(?!W) after a form that ends with
    /// a word character" written once. Sharing both checks keeps the pattern small: ICU compiles each `\p{…}` class
    /// separately, at about 0.3 ms apiece.
    private static func makeScanner(wordStart: BucketList, otherStart: BucketList) -> NSRegularExpression? {
        var branches: [String] = []
        if let alternation = wordStart.alternation {
            branches.append("(?<!\(wordCharacter))\(alternation)")
        }
        if let alternation = otherStart.alternation {
            branches.append(alternation)
        }
        guard !branches.isEmpty else { return nil }
        let pattern = "(?:\(branches.joined(separator: "|")))(?:(?<!\(wordCharacter))|(?!\(wordCharacter)))"
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            assertionFailure("Dictionary scanner failed to compile: \(error)")
            return nil
        }
    }

    /// Case-folded, without whitespace, hyphens or dots. Every text a form can match has the form's key, so the key
    /// narrows identification to a handful of candidates.
    fileprivate static func identityKey(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar != "-" && scalar != "." && !scalar.properties.isWhitespace {
            kept.append(scalar)
        }
        return String(kept).folding(options: .caseInsensitive, locale: nil)
    }

    fileprivate static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    /// 2–10 uppercase ASCII letters or digits, at least two of them letters: "RLS", "BPC", "GPT4", "K8S".
    fileprivate static func isAcronymLike(_ form: String) -> Bool {
        var length = 0
        var letters = 0
        for scalar in form.unicodeScalars {
            length += 1
            switch scalar.value {
            case 0x41...0x5A: letters += 1
            case 0x30...0x39: break
            default: return false
            }
        }
        return (2...10).contains(length) && letters >= 2
    }

    /// Literal text, except that interior runs of whitespace and hyphens match any such run.
    fileprivate static func literalPattern(_ form: String, caseSensitive: Bool) -> String {
        func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "-" || scalar.properties.isWhitespace
        }
        let scalars = Array(form.unicodeScalars)
        var body = ""
        var literal = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard isSeparator(scalars[index]) else {
                literal.append(scalars[index])
                index += 1
                continue
            }
            var end = index
            while end < scalars.count, isSeparator(scalars[end]) {
                end += 1
            }
            if index > 0, end < scalars.count {
                // Matches exactly what `[\s\-]+` does. ICU compiles a bare `[set]+` into an optimized loop that
                // reserves a slot in its backtracking frame, which it copies on every backtracking save; one slot per
                // form made scanning about nine times slower. The grouped loop reserves no slot.
                body += NSRegularExpression.escapedPattern(for: String(literal)) + #"(?:[\s\-])+"#
                literal = String.UnicodeScalarView()
            } else {
                // A leading or trailing hyphen is part of the form itself.
                literal.append(contentsOf: scalars[index..<end])
            }
            index = end
        }
        body += NSRegularExpression.escapedPattern(for: String(literal))
        return caseSensitive ? "(?:\(body))" : "(?i:\(body))"
    }

    /// The acronym as typed (case-insensitive unless the entry is case-sensitive), plus uppercase dotted ("R.L.S.",
    /// "R. L. S.", "R.L.S") and spaced ("R L S") spellings. Lowercase dotted text such as "e.g." or "p.m." is left
    /// alone. The dotted spelling's final dot is optional; `isInsideLongerDottedAcronym` rejects dotted matches that
    /// are part of a longer dotted acronym.
    fileprivate static func acronymPattern(_ form: String, caseSensitive: Bool) -> String {
        let characters = form.map(String.init)
        let dotted = characters.joined(separator: #"\.\h*"#) + #"\.?"#
        let spaced = characters.joined(separator: #"\h+"#)
        let plain = caseSensitive ? form : "(?i:\(form))"
        return "(?:\(dotted)|\(spaced)|\(plain))"
    }

    /// The replacement with its first character capitalized, when its first word is all lowercase letters
    /// (hyphens allowed), e.g. "row-level security" → "Row-level security". `nil` for text like "iOS app".
    fileprivate static func sentenceCased(_ replacement: String) -> String? {
        let firstWord = replacement.unicodeScalars.prefix { !$0.properties.isWhitespace }
        guard let first = firstWord.first, first.properties.generalCategory == .lowercaseLetter else { return nil }
        for scalar in firstWord where scalar != "-" {
            switch scalar.properties.generalCategory {
            case .lowercaseLetter, .nonspacingMark, .spacingMark, .enclosingMark:
                continue
            default:
                return nil
            }
        }
        guard let firstCharacter = replacement.first else { return nil }
        return String(firstCharacter).capitalized + replacement.dropFirst()
    }
}

// MARK: - Supporting types

private struct EntryOutput: Sendable {
    /// The trimmed trigger, exactly as typed.
    let spelling: String
    /// `nil` for vocabulary-only entries.
    let replacement: String?
    let sentenceCaseReplacement: String?

    init(_ entry: DictionaryEntry, spelling: String) {
        self.spelling = spelling
        if entry.isVocabularyOnly {
            replacement = nil
            sentenceCaseReplacement = nil
        } else {
            replacement = entry.replacement
            sentenceCaseReplacement = DictionaryMatcher.sentenceCased(entry.replacement)
        }
    }
}

private struct CompiledForm: Sendable {
    let entry: Int
    let isAcronym: Bool
    /// The form's pattern anchored at both ends, for identifying which form produced a match.
    let verifier: NSRegularExpression
}

private struct FormSpec {
    let entry: Int
    /// Position among all forms in entry order; breaks length ties.
    let rank: Int
    let length: Int
    let isAcronym: Bool
    let pattern: String
    let identityKey: String
    let firstScalar: Unicode.Scalar
    /// Case-folded first scalar. Only forms in the same bucket can match at the same position.
    let bucketKey: Unicode.Scalar
    let startsWithWordCharacter: Bool

    /// - Parameter form: Trimmed, NFC-normalized and non-empty.
    init?(_ form: String, caseSensitive: Bool, entry: Int, rank: Int) {
        guard let first = form.unicodeScalars.first else { return nil }
        self.entry = entry
        self.rank = rank
        length = form.count
        isAcronym = DictionaryMatcher.isAcronymLike(form)
        pattern = isAcronym
            ? DictionaryMatcher.acronymPattern(form, caseSensitive: caseSensitive)
            : DictionaryMatcher.literalPattern(form, caseSensitive: caseSensitive)
        identityKey = DictionaryMatcher.identityKey(form)
        firstScalar = first
        let folded = String(first).folding(options: .caseInsensitive, locale: nil)
        bucketKey = folded.unicodeScalars.first ?? first
        startsWithWordCharacter = DictionaryMatcher.isWordCharacter(first)
    }
}

/// Forms grouped by case-folded first character ("buckets"), keeping priority order within each bucket. Only forms in
/// the same bucket can match at the same position, so the order of buckets does not matter and the scanner can skip
/// a whole bucket, or a group of buckets, with one look-ahead on the next character.
private struct BucketList {
    private struct Node {
        var firstScalars: [Unicode.Scalar]
        var pattern: String
    }

    /// ICU tries alternatives one after another, so no level of the dispatch tree offers more than this many.
    private static let fanout = 16

    private var buckets: [(key: Unicode.Scalar, firstScalars: [Unicode.Scalar], alternatives: [String])] = []
    private var indexByKey: [Unicode.Scalar: Int] = [:]

    mutating func add(_ spec: FormSpec) {
        guard let index = indexByKey[spec.bucketKey] else {
            indexByKey[spec.bucketKey] = buckets.count
            buckets.append((key: spec.bucketKey, firstScalars: [spec.firstScalar], alternatives: [spec.pattern]))
            return
        }
        if !buckets[index].firstScalars.contains(spec.firstScalar) {
            buckets[index].firstScalars.append(spec.firstScalar)
        }
        buckets[index].alternatives.append(spec.pattern)
    }

    /// A shallow tree: buckets sorted by first character, grouped under look-aheads until at most `fanout`
    /// alternatives remain, e.g. `(?:(?i:(?=[a-m…]))(?:bucket|bucket|…)|(?i:(?=[n-z…]))(?:…))`. `nil` when empty.
    var alternation: String? {
        guard !buckets.isEmpty else { return nil }
        var level = buckets.sorted { $0.key.value < $1.key.value }.map { bucket in
            // A lone form tests its own first character; a look-ahead would only add per-attempt overhead.
            bucket.alternatives.count == 1
                ? Node(firstScalars: bucket.firstScalars, pattern: bucket.alternatives[0])
                : Self.guarded(Node(firstScalars: bucket.firstScalars, pattern: bucket.alternatives.joined(separator: "|")))
        }
        while level.count > Self.fanout {
            let children = level
            let groupCount = (children.count + Self.fanout - 1) / Self.fanout
            level = (0..<groupCount).map { group in
                let members = children[children.count * group / groupCount ..< children.count * (group + 1) / groupCount]
                return Self.guarded(Node(
                    firstScalars: members.flatMap(\.firstScalars),
                    pattern: members.map(\.pattern).joined(separator: "|")
                ))
            }
        }
        return "(?:\(level.map(\.pattern).joined(separator: "|")))"
    }

    /// Prefixes a case-insensitive look-ahead for the node's first characters. ICU resets every look-around's data
    /// on each match attempt, so the tree adds them sparingly.
    private static func guarded(_ node: Node) -> Node {
        let set = node.firstScalars.map { "\\x{\(String($0.value, radix: 16))}" }.joined()
        return Node(firstScalars: node.firstScalars, pattern: "(?i:(?=[\(set)]))(?:\(node.pattern))")
    }
}
