public import Foundation
import GRDB

/// Reads and writes the transcript history.
///
/// Methods are synchronous and thread-safe. Most are fast enough to call from
/// the main actor; run `search` over a large history, and bulk work, from a
/// background task.
public nonisolated struct HistoryStore: Sendable {
    private typealias Columns = TranscriptRecord.Columns

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Writing

    /// Inserts `record` and returns it as stored: with its new `id`, and
    /// `createdAt` at the database's millisecond precision, so the result
    /// equals what later reads return.
    @discardableResult
    public func insert(_ record: TranscriptRecord) throws -> TranscriptRecord {
        var inserted = record
        inserted.createdAt = Self.storedDate(record.createdAt)
        return try database.writer.write { db in
            try inserted.insert(db)
            return inserted
        }
    }

    /// Saves every column of `record`.
    ///
    /// - Throws: `RecordError.recordNotFound` if `record.id` is nil or no longer exists.
    public func update(_ record: TranscriptRecord) throws {
        try database.writer.write { db in
            try record.update(db)
        }
    }

    /// Deletes the transcript with `id`, if any. The audio file is the caller's
    /// to delete.
    public func delete(id: Int64) throws {
        _ = try database.writer.write { db in
            try TranscriptRecord.deleteOne(db, id: id)
        }
    }

    /// Deletes every transcript.
    public func deleteAll() throws {
        _ = try database.writer.write { db in
            try TranscriptRecord.deleteAll(db)
        }
    }

    /// Deletes transcripts created more than `days` days before `now`, and
    /// returns how many were deleted. A `days` of 0 or less keeps everything.
    ///
    /// Collect `audioPathsOlderThan(days:now:)` with the same arguments first
    /// if the audio files must be removed too.
    @discardableResult
    public func prune(olderThan days: Int, now: Date) throws -> Int {
        guard let cutoff = Self.cutoff(days: days, now: now) else { return 0 }
        return try database.writer.write { db in
            try TranscriptRecord
                .filter(Columns.createdAt < cutoff)
                .deleteAll(db)
        }
    }

    // MARK: - Reading

    public func record(id: Int64) throws -> TranscriptRecord? {
        try database.reader.read { db in
            try TranscriptRecord.fetchOne(db, id: id)
        }
    }

    /// The `limit` most recent transcripts, newest first.
    public func recent(limit: Int) throws -> [TranscriptRecord] {
        try database.reader.read { db in
            try Self.newestFirst(limit: limit).fetchAll(db)
        }
    }

    /// Transcripts whose final or raw text contains `query` (trimmed), ignoring
    /// case, newest first. `%`, `_` and `\` in the query match literally. A
    /// blank query returns the most recent transcripts.
    public func search(_ query: String, limit: Int, offset: Int) throws -> [TranscriptRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return try database.reader.read { db in
                try Self.newestFirst(limit: limit, offset: offset).fetchAll(db)
            }
        }

        // SQLite's LIKE ignores case for ASCII letters only. That is exact
        // when the query has no other letters with case (English, CJK, ...).
        // Otherwise ("Über"), both sides go through Swift's Unicode-aware
        // `lowercased()` (GRDB's `swiftLowercaseString` SQL function), which
        // is about 40 times slower, so it is only used when needed.
        let foldsUnicode = needle.unicodeScalars.contains {
            !$0.isASCII && $0.properties.changesWhenCaseMapped
        }
        let pattern = "%" + Self.escapeLikePattern(foldsUnicode ? needle.lowercased() : needle) + "%"
        let escape = String(Self.likeEscapeCharacter)
        let finalText = foldsUnicode ? Columns.finalText.lowercased : Columns.finalText.sqlExpression
        let rawText = foldsUnicode ? Columns.rawText.lowercased : Columns.rawText.sqlExpression
        return try database.reader.read { db in
            try Self.newestFirst(limit: limit, offset: offset)
                .filter(finalText.like(pattern, escape: escape) || rawText.like(pattern, escape: escape))
                .fetchAll(db)
        }
    }

    /// The non-empty `audio_path` values of the transcripts that
    /// `prune(olderThan: days, now: now)` would delete.
    public func audioPathsOlderThan(days: Int, now: Date) throws -> [String] {
        guard let cutoff = Self.cutoff(days: days, now: now) else { return [] }
        return try database.reader.read { db in
            try TranscriptRecord
                .filter(Columns.createdAt < cutoff)
                .filter(Columns.audioPath != nil && Columns.audioPath != "")
                .order(Columns.createdAt, Columns.id)
                .select(Columns.audioPath, as: String.self)
                .fetchAll(db)
        }
    }

    /// Transcripts that failed, newest first.
    public func failedRecords() throws -> [TranscriptRecord] {
        try database.reader.read { db in
            try TranscriptRecord
                .filter(Columns.status == TranscriptRecord.Status.failed.rawValue)
                .order(Columns.createdAt.desc, Columns.id.desc)
                .fetchAll(db)
        }
    }

    // MARK: - Observing

    /// The `limit` most recent transcripts, newest first: the current list,
    /// then the fresh list after every change to it.
    ///
    /// Iterate it from a task (for example SwiftUI's `.task`); cancelling the
    /// task, or dropping the stream, stops the observation. A slow consumer
    /// only receives the latest list.
    public func observeRecent(limit: Int) -> AsyncStream<[TranscriptRecord]> {
        database.observe { db in
            try Self.newestFirst(limit: limit).fetchAll(db)
        }
    }

    // MARK: - Helpers

    private static let likeEscapeCharacter: Unicode.Scalar = "\\"

    private static func newestFirst(limit: Int, offset: Int = 0) -> QueryInterfaceRequest<TranscriptRecord> {
        TranscriptRecord
            .order(Columns.createdAt.desc, Columns.id.desc)
            .limit(max(0, limit), offset: max(0, offset))
    }

    /// Escapes LIKE wildcards (and the escape character itself) so that they
    /// match literally in a pattern used with `ESCAPE '\'`.
    static func escapeLikePattern(_ string: String) -> String {
        var escaped = String.UnicodeScalarView()
        for scalar in string.unicodeScalars {
            if scalar == likeEscapeCharacter || scalar == "%" || scalar == "_" {
                escaped.append(likeEscapeCharacter)
            }
            escaped.append(scalar)
        }
        return String(escaped)
    }

    /// `date` as it reads back from the database, which stores
    /// "yyyy-MM-dd HH:mm:ss.SSS" text in UTC.
    static func storedDate(_ date: Date) -> Date {
        Date.fromDatabaseValue(date.databaseValue) ?? date
    }

    /// The creation date before which transcripts are older than `days`, or
    /// nil when `days` asks to keep everything.
    private static func cutoff(days: Int, now: Date) -> Date? {
        guard days > 0 else { return nil }
        // Beyond a century nothing is old enough to prune; the clamp also keeps
        // the cutoff a representable date.
        let days = min(days, 36_500)
        return now.addingTimeInterval(-Double(days) * 86_400)
    }
}
