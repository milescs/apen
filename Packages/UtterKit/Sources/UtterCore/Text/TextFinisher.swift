/// The final tidy applied to dictated text just before it is pasted.
public enum TextFinisher {
    /// Trims leading/trailing whitespace, collapses runs of spaces/tabs (not newlines) to one space,
    /// removes spaces before , . ! ? ; : ), keeps at most two consecutive newlines, and appends a single
    /// trailing space when `trailingSpace` is true and the result is non-empty.
    ///
    /// Spaces and tabs at the start or end of a line are removed along with the line's other surrounding
    /// whitespace, so blank lines that contain spaces still count toward the two-newline limit.
    ///
    /// A space before a mark is kept when a letter or digit follows the mark, so tokens such as `.env`,
    /// `.5` and `:tada:` are untouched, and so are emoticons such as `:)` and `;-)`. Newline characters
    /// (including `\r\n`) are kept as they are.
    public static func finish(_ text: String, trailingSpace: Bool) -> String {
        let characters = Array(text)
        var result = ""
        result.reserveCapacity(text.utf8.count + 1)
        var pendingSpace = false
        var pendingNewlines: [Character] = []

        for (offset, character) in characters.enumerated() {
            if character.isNewline {
                if pendingNewlines.count < 2 { pendingNewlines.append(character) }
                // Whitespace at the end of a line is dropped.
                pendingSpace = false
            } else if character.isWhitespace {
                pendingSpace = true
            } else {
                if !pendingNewlines.isEmpty {
                    // Leading newlines are trimmed, and so is whitespace at the start of a line.
                    if !result.isEmpty { result.append(contentsOf: pendingNewlines) }
                    pendingNewlines.removeAll(keepingCapacity: true)
                } else if pendingSpace, !result.isEmpty {
                    let next = offset + 1 < characters.count ? characters[offset + 1] : nil
                    if !attachesToPrecedingText(character, next: next) { result.append(" ") }
                }
                pendingSpace = false
                result.append(character)
            }
        }
        // Trailing whitespace is never flushed, which trims the end.
        if trailingSpace && !result.isEmpty { result.append(" ") }
        return result
    }

    /// True when the text has no letters or digits.
    public static func isEffectivelyEmpty(_ text: String) -> Bool {
        !text.contains { $0.isLetter || $0.isNumber }
    }

    private static let closingMarks: Set<Character> = [",", ".", "!", "?", ";", ":", ")"]
    /// Characters that can follow `:` or `;` in an emoticon.
    private static let emoticonFaces: Set<Character> = ["-", ")", "(", "/", "|", "*", "'"]

    /// Whether the space before `mark` should be removed.
    private static func attachesToPrecedingText(_ mark: Character, next: Character?) -> Bool {
        guard closingMarks.contains(mark) else { return false }
        guard let next else { return true }
        if next.isLetter || next.isNumber { return false }
        if mark == ":" || mark == ";", emoticonFaces.contains(next) { return false }
        return true
    }
}
