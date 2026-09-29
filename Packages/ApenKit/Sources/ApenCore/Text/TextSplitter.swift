/// Splits long text into pieces that fit a limited budget (for example an LLM's context), preferring
/// sentence boundaries.
public enum TextSplitter {
    /// Splits at sentence boundaries (after . ! ? … followed by whitespace, or at newlines) into pieces
    /// whose `measure(piece) <= maxUnits`.
    ///
    /// Pieces are packed greedily with as many whole sentences as fit. A terminator still counts when
    /// closing quotes or brackets follow it (`"Stop." Then`), and a period inside a number such as `3.5`
    /// is never a boundary. Abbreviations such as "e.g." may end a piece.
    ///
    /// A single sentence longer than `maxUnits` is split at the last whitespace that fits. It is split
    /// mid-word only when one word alone exceeds `maxUnits`.
    ///
    /// Concatenating the returned pieces reproduces the input exactly. Whitespace is kept at the end of
    /// the preceding piece, with one exception: when a word fits but the whitespace after it does not
    /// (possible only with a measure that counts whitespace), the rest of that whitespace starts the next
    /// piece.
    ///
    /// `measure` is always called on the exact candidate piece, so it does not need to be additive. It is
    /// assumed not to shrink as a piece grows. If not even one character fits, single characters are
    /// returned so that the split always finishes. Empty text returns no pieces.
    public static func split(_ text: String, maxUnits: Int, measure: (Substring) -> Int) -> [String] {
        guard !text.isEmpty else { return [] }
        if measure(text[...]) <= maxUnits { return [text] }

        let sentenceEnds = sentenceEnds(in: text)
        let wordBreaks = wordBreaks(in: text)
        var pieces: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = pieceEnd(
                from: start,
                in: text,
                sentenceEnds: sentenceEnds,
                wordBreaks: wordBreaks,
                maxUnits: maxUnits,
                measure: measure
            )
            pieces.append(String(text[start..<end]))
            start = end
        }
        return pieces
    }

    /// Counts whitespace-separated words, the way `wc -w` does.
    public static func wordCount(_ text: Substring) -> Int {
        var count = 0
        var inWord = false
        for character in text {
            if character.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    // MARK: - Piece selection

    /// The end of the piece that starts at `start`: the furthest break that fits, trying whole sentences,
    /// then whole words, then breaks beside the first word, and finally breaks inside it.
    private static func pieceEnd(
        from start: String.Index,
        in text: String,
        sentenceEnds: [String.Index],
        wordBreaks: [String.Index],
        maxUnits: Int,
        measure: (Substring) -> Int
    ) -> String.Index {
        // 1. As many whole sentences as fit.
        let firstSentence = firstPosition(in: sentenceEnds, after: start)
        if let end = furthestFit(
            sentenceEnds[firstSentence...], from: start, in: text, maxUnits: maxUnits, measure: measure
        ) {
            return end
        }

        // 2. The first sentence alone is too long: as many of its words, with their whitespace, as fit.
        let sentenceEnd = sentenceEnds[firstSentence]
        let words = wordBreaks[
            firstPosition(in: wordBreaks, after: start)..<firstPosition(in: wordBreaks, after: sentenceEnd)
        ]
        if let end = furthestFit(words, from: start, in: text, maxUnits: maxUnits, measure: measure) {
            return end
        }

        // 3. Even the first word and the whitespace after it are too long. Break beside the word: inside
        //    the whitespace after it (keeping as much as fits), right after it, or before it.
        var wordStart = start
        while wordStart < sentenceEnd, text[wordStart].isWhitespace { wordStart = text.index(after: wordStart) }
        var wordEnd = wordStart
        while wordEnd < sentenceEnd, !text[wordEnd].isWhitespace { wordEnd = text.index(after: wordEnd) }
        var runEnd = wordEnd
        while runEnd < sentenceEnd, text[runEnd].isWhitespace { runEnd = text.index(after: runEnd) }

        var besideWord: [String.Index] = []
        var insideWord: [String.Index] = []
        var position = start
        while position < runEnd {
            position = text.index(after: position)
            if position > wordStart && position < wordEnd {
                insideWord.append(position)
            } else {
                besideWord.append(position)
            }
        }
        if let end = furthestFit(besideWord[...], from: start, in: text, maxUnits: maxUnits, measure: measure) {
            return end
        }

        // 4. The word alone is too long: split it at the last character that fits.
        if let end = furthestFit(insideWord[...], from: start, in: text, maxUnits: maxUnits, measure: measure) {
            return end
        }

        // 5. Not even one character fits. Take one anyway so the split always advances.
        return text.index(after: start)
    }

    /// The furthest of the ascending `candidates` whose piece from `start` fits.
    ///
    /// The search gallops outward from `start` and then bisects, so no probe measures much more than
    /// twice the piece it returns, however long the rest of the text is.
    private static func furthestFit(
        _ candidates: ArraySlice<String.Index>,
        from start: String.Index,
        in text: String,
        maxUnits: Int,
        measure: (Substring) -> Int
    ) -> String.Index? {
        // Offsets into `candidates`: the furthest known to fit, and the nearest known not to.
        var fitting = candidates.startIndex - 1
        var failing = candidates.endIndex
        var step = 1
        while fitting + step < failing {
            let probe = fitting + step
            if measure(text[start..<candidates[probe]]) <= maxUnits {
                fitting = probe
                step *= 2
            } else {
                failing = probe
            }
        }
        while failing - fitting > 1 {
            let middle = fitting + (failing - fitting) / 2
            if measure(text[start..<candidates[middle]]) <= maxUnits {
                fitting = middle
            } else {
                failing = middle
            }
        }
        return fitting >= candidates.startIndex ? candidates[fitting] : nil
    }

    /// The offset in the ascending `positions` of the first one after `bound`.
    private static func firstPosition(in positions: [String.Index], after bound: String.Index) -> Int {
        var low = 0
        var high = positions.count
        while low < high {
            let middle = low + (high - low) / 2
            if positions[middle] > bound {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }

    // MARK: - Boundaries

    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    /// Closing quotes and brackets that may sit between a terminator and the whitespace after it.
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}", "»"]

    /// Where sentences end, ascending, always finishing with `text.endIndex`.
    ///
    /// A sentence ends after a terminator (and any closers) that is followed by whitespace, or at a
    /// newline, and it keeps the whole whitespace run that follows. Leading whitespace belongs to the
    /// first sentence rather than forming a sentence of its own.
    private static func sentenceEnds(in text: String) -> [String.Index] {
        var ends: [String.Index] = []
        var index = text.startIndex
        var sawContent = false
        var afterTerminator = false
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                if sawContent && (afterTerminator || character.isNewline) {
                    var end = index
                    while end < text.endIndex, text[end].isWhitespace { end = text.index(after: end) }
                    ends.append(end)
                    sawContent = false
                    afterTerminator = false
                    index = end
                    continue
                }
            } else {
                sawContent = true
                if terminators.contains(character) {
                    afterTerminator = true
                } else if !(afterTerminator && closers.contains(character)) {
                    afterTerminator = false
                }
            }
            index = text.index(after: index)
        }
        if ends.last != text.endIndex { ends.append(text.endIndex) }
        return ends
    }

    /// Where each whitespace run ends (so a word starts there, or the text ends), ascending.
    private static func wordBreaks(in text: String) -> [String.Index] {
        var breaks: [String.Index] = []
        var previousWasWhitespace = false
        var index = text.startIndex
        while index < text.endIndex {
            let isWhitespace = text[index].isWhitespace
            if previousWasWhitespace && !isWhitespace { breaks.append(index) }
            previousWasWhitespace = isWhitespace
            index = text.index(after: index)
        }
        if previousWasWhitespace { breaks.append(text.endIndex) }
        return breaks
    }
}
