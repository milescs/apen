import Foundation

/// One row of the personal dictionary: what the user says, what else the recognizer tends to hear, and what to write.
public struct DictionaryEntry: Sendable, Hashable, Codable, Identifiable {
    /// Database id; `nil` while the entry is unsaved.
    public var id: Int64?
    /// "When I say": the user's own spelling, e.g. "RLS", "Supabase" or "pull request".
    public var trigger: String
    /// "Also heard as": other spellings the recognizer produces for the trigger, e.g. "our LS".
    public var aliases: [String]
    /// "Write": the expansion. Empty means write the trigger exactly as spelled (a spelling or casing fix).
    public var replacement: String
    /// When true, the trigger and aliases only match with the exact casing typed.
    public var caseSensitive: Bool
    /// Whether the trigger is offered to the recognizer as a vocabulary hint.
    public var boost: Bool
    public var enabled: Bool

    /// - Parameter boost: Defaults to `true` for triggers of four or more characters or containing a space;
    ///   short acronyms are too ambiguous to bias recognition toward.
    public init(
        id: Int64? = nil,
        trigger: String,
        aliases: [String] = [],
        replacement: String = "",
        caseSensitive: Bool = false,
        boost: Bool? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.trigger = trigger
        self.aliases = aliases
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.boost = boost ?? Self.defaultBoost(for: trigger)
        self.enabled = enabled
    }

    /// True when the entry only fixes spelling or casing: there is no replacement text.
    public var isVocabularyOnly: Bool {
        replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func defaultBoost(for trigger: String) -> Bool {
        let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 4 || trimmed.contains(where: \.isWhitespace)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, trigger, aliases, replacement, caseSensitive, boost, enabled
    }

    /// Only `trigger` is required, so rows written before a field existed still decode with the usual defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(Int64.self, forKey: .id),
            trigger: try container.decode(String.self, forKey: .trigger),
            aliases: try container.decodeIfPresent([String].self, forKey: .aliases) ?? [],
            replacement: try container.decodeIfPresent(String.self, forKey: .replacement) ?? "",
            caseSensitive: try container.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false,
            boost: try container.decodeIfPresent(Bool.self, forKey: .boost),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        )
    }
}
