public import Foundation
import GRDB

/// Apen's local SQLite database: owns the connection and the schema.
///
/// Create one instance per database file and share it; the stores
/// (`HistoryStore`, `DictionaryStore`) are cheap value types built on top of
/// it. All methods are thread-safe.
public nonisolated final class AppDatabase: Sendable {
    /// The connection used for writes and observation.
    let writer: any DatabaseWriter

    /// The connection used for reads. With a file-backed database (a
    /// `DatabasePool` in WAL mode), reads run concurrently with writes.
    var reader: any DatabaseReader { writer }

    /// Opens the database at `fileURL`, creating the file and its parent
    /// directories if needed, and migrates it to the current schema.
    ///
    /// The database uses WAL mode, so `-wal` and `-shm` files live next to it.
    public convenience init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool = try DatabasePool(
            path: fileURL.path(percentEncoded: false),
            configuration: Self.makeConfiguration()
        )
        try self.init(writer: pool)
    }

    /// Returns a new, empty, private in-memory database, for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue(configuration: makeConfiguration()))
    }

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    private static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.label = "ApenDatabase"
        return configuration
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // Rebuilds the database from scratch whenever a migration changes
        // during development. Never enabled in release builds.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            try db.create(table: "transcripts") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("created_at", .datetime).notNull().indexed()
                t.column("kind", .text).notNull() // 'dictation' | 'file'
                t.column("source_name", .text)
                t.column("source_bundle_id", .text)
                t.column("duration_s", .double).notNull().defaults(to: 0)
                t.column("raw_text", .text).notNull()
                t.column("cleaned_text", .text)
                t.column("final_text", .text).notNull()
                t.column("asr_model", .text).notNull()
                t.column("cleanup_model", .text)
                t.column("processing_ms", .integer).notNull().defaults(to: 0)
                t.column("status", .text).notNull() // 'completed' | 'failed'
                t.column("error", .text)
                t.column("audio_path", .text)
                t.column("pasted", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "dictionary_entries") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trigger", .text).notNull()
                t.column("aliases", .text).notNull().defaults(to: "[]") // JSON array of strings
                t.column("replacement", .text).notNull().defaults(to: "")
                t.column("case_sensitive", .boolean).notNull().defaults(to: false)
                t.column("boost", .boolean).notNull().defaults(to: false)
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(
                index: "dictionary_entries_on_trigger",
                on: "dictionary_entries",
                expressions: [Column("trigger").collating(.nocase)],
                options: .unique
            )
        }

        return migrator
    }

    // MARK: - Observation

    /// Serial queue on which observed values are handed to their streams.
    private static let observationQueue = DispatchQueue(label: "ApenDatabase.observation")

    /// Observes the value returned by `fetch`.
    ///
    /// The stream yields the current value, then a fresh value after every
    /// committed change that modifies it (identical consecutive values are
    /// skipped). A consumer that falls behind only receives the latest value.
    /// Terminating the stream (cancelling the consuming task, or dropping the
    /// stream) stops the database observation. The stream finishes if the
    /// observation fails.
    func observe<Value: Sendable & Equatable>(
        _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncStream<Value> {
        let observation = ValueObservation.tracking(fetch).removeDuplicates()
        let reader = self.reader
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let cancellable = observation.start(
                in: reader,
                scheduling: .async(onQueue: Self.observationQueue),
                onError: { _ in continuation.finish() },
                onChange: { value in continuation.yield(value) }
            )
            // Retains the observation for the lifetime of the stream.
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }
}
