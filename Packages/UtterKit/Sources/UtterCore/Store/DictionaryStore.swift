public import Foundation
import GRDB

public nonisolated enum DictionaryStoreError: Error, Equatable, Sendable, LocalizedError {
    /// Another entry already uses this trigger (compared ignoring ASCII case).
    case duplicateTrigger(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateTrigger(let trigger):
            "The dictionary already has an entry for “\(trigger)”."
        }
    }
}

/// Reads and writes the custom dictionary.
///
/// Methods are synchronous and thread-safe.
public nonisolated struct DictionaryStore: Sendable {
    private let database: AppDatabase
    private let now: @Sendable () -> Date

    /// - Parameter now: The clock that stamps `created_at` and `updated_at`.
    public init(database: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    /// Every entry, ordered by trigger, ignoring case.
    public func all() throws -> [DictionaryEntry] {
        try database.reader.read { db in
            try Self.fetchAll(db)
        }
    }

    /// Inserts `entry` when it has no `id` (or its row no longer exists),
    /// otherwise updates it. Returns the entry with its `id`.
    ///
    /// - Throws: `DictionaryStoreError.duplicateTrigger` when another entry
    ///   has the same trigger, ignoring case.
    @discardableResult
    public func save(_ entry: DictionaryEntry) throws -> DictionaryEntry {
        let timestamp = now()
        do {
            return try database.writer.write { db in
                var row = try DictionaryEntryRow(entry, timestamp: timestamp)
                if row.id != nil, try row.exists(db) {
                    try row.update(db, columns: DictionaryEntryRow.updatedColumns)
                } else {
                    try row.insert(db)
                }
                return row.entry
            }
        } catch DatabaseError.SQLITE_CONSTRAINT_UNIQUE {
            throw DictionaryStoreError.duplicateTrigger(entry.trigger)
        }
    }

    /// Deletes the entry with `id`, if any.
    public func delete(id: Int64) throws {
        _ = try database.writer.write { db in
            try DictionaryEntryRow.deleteOne(db, key: id)
        }
    }

    /// Replaces the whole dictionary with `entries` (a JSON import), in one
    /// transaction: on error, the previous dictionary is left untouched.
    /// Entries get new ids.
    ///
    /// - Throws: `DictionaryStoreError.duplicateTrigger` when two entries have
    ///   the same trigger, ignoring case.
    public func replaceAll(_ entries: [DictionaryEntry]) throws {
        let timestamp = now()
        try database.writer.write { db in
            _ = try DictionaryEntryRow.deleteAll(db)
            for entry in entries {
                var row = try DictionaryEntryRow(entry, timestamp: timestamp)
                row.id = nil
                do {
                    try row.insert(db)
                } catch DatabaseError.SQLITE_CONSTRAINT_UNIQUE {
                    throw DictionaryStoreError.duplicateTrigger(entry.trigger)
                }
            }
        }
    }

    /// Every entry, ordered like `all()`: the current list, then the fresh
    /// list after every change. Cancelling the consuming task, or dropping the
    /// stream, stops the observation.
    public func observeAll() -> AsyncStream<[DictionaryEntry]> {
        database.observe { db in
            try Self.fetchAll(db)
        }
    }

    private static func fetchAll(_ db: Database) throws -> [DictionaryEntry] {
        try DictionaryEntryRow
            .order(
                DictionaryEntryRow.Columns.trigger.collating(.localizedCaseInsensitiveCompare),
                DictionaryEntryRow.Columns.id
            )
            .fetchAll(db)
            .map(\.entry)
    }
}

// MARK: - Database row

/// The `dictionary_entries` row of a `DictionaryEntry`, which keeps its
/// aliases as JSON text and carries the timestamps.
nonisolated struct DictionaryEntryRow: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "dictionary_entries"

    var id: Int64?
    var trigger: String
    /// A JSON array of strings.
    var aliasesJSON: String
    var replacement: String
    var caseSensitive: Bool
    var boost: Bool
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case trigger
        case aliasesJSON = "aliases"
        case replacement
        case caseSensitive = "case_sensitive"
        case boost
        case enabled
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let trigger = Column(CodingKeys.trigger)
        static let aliasesJSON = Column(CodingKeys.aliasesJSON)
        static let replacement = Column(CodingKeys.replacement)
        static let caseSensitive = Column(CodingKeys.caseSensitive)
        static let boost = Column(CodingKeys.boost)
        static let enabled = Column(CodingKeys.enabled)
        static let createdAt = Column(CodingKeys.createdAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }

    /// Everything an update writes: all columns but `id` and `created_at`.
    static let updatedColumns = [
        Columns.trigger, Columns.aliasesJSON, Columns.replacement, Columns.caseSensitive,
        Columns.boost, Columns.enabled, Columns.updatedAt,
    ]

    /// A row for `entry`, created and updated at `timestamp`.
    init(_ entry: DictionaryEntry, timestamp: Date) throws {
        id = entry.id
        trigger = entry.trigger
        aliasesJSON = try Self.encodeAliases(entry.aliases)
        replacement = entry.replacement
        caseSensitive = entry.caseSensitive
        boost = entry.boost
        enabled = entry.enabled
        createdAt = timestamp
        updatedAt = timestamp
    }

    var entry: DictionaryEntry {
        DictionaryEntry(
            id: id,
            trigger: trigger,
            aliases: Self.decodeAliases(aliasesJSON),
            replacement: replacement,
            caseSensitive: caseSensitive,
            boost: boost,
            enabled: enabled
        )
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static func encodeAliases(_ aliases: [String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(aliases), as: UTF8.self)
    }

    /// Malformed JSON (only possible through outside edits) reads as no aliases
    /// rather than making the whole dictionary unreadable.
    static func decodeAliases(_ json: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }
}
