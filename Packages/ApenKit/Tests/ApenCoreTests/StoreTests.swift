import Foundation
import GRDB
import Testing
@testable import ApenCore

/// 2026-09-21 14:13:20 UTC, a whole second so stored dates compare exactly.
private let referenceDate = Date(timeIntervalSince1970: 1_790_000_000)

private func days(_ count: Int) -> TimeInterval {
    Double(count) * 86_400
}

private func makeRecord(
    _ finalText: String,
    raw: String? = nil,
    at createdAt: Date,
    status: TranscriptRecord.Status = .completed,
    audioPath: String? = nil
) -> TranscriptRecord {
    TranscriptRecord(
        createdAt: createdAt,
        rawText: raw ?? finalText,
        finalText: finalText,
        asrModel: "test-asr",
        status: status,
        error: status == .failed ? "Transcription failed" : nil,
        audioPath: audioPath
    )
}

private struct TimedOut: Error {}

/// Runs `operation`, failing with `TimedOut` if it takes longer than `timeout`.
private func withTimeout<T: Sendable>(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimedOut()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw TimedOut() }
        return result
    }
}

/// A fresh directory for file-backed databases. Honors `TMPDIR`, which
/// Foundation ignores on Darwin, so a run can keep its files in one place.
private func makeTemporaryDirectory() -> URL {
    let base = ProcessInfo.processInfo.environment["TMPDIR"].map {
        URL(filePath: $0, directoryHint: .isDirectory)
    } ?? FileManager.default.temporaryDirectory
    return base.appending(path: "ApenStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@Suite("Stores")
struct StoreTests {
    let database: AppDatabase
    let history: HistoryStore
    let dictionary: DictionaryStore

    init() throws {
        database = try AppDatabase.inMemory()
        history = HistoryStore(database: database)
        dictionary = DictionaryStore(database: database)
    }

    // MARK: - Schema

    @Test func migrationCreatesBothTables() throws {
        try database.reader.read { db in
            #expect(try AppDatabase.migrator.appliedMigrations(db) == ["v1"])

            #expect(try db.columns(in: "transcripts").map(\.name) == [
                "id", "created_at", "kind", "source_name", "source_bundle_id", "duration_s",
                "raw_text", "cleaned_text", "final_text", "asr_model", "cleanup_model",
                "processing_ms", "status", "error", "audio_path", "pasted",
            ])
            #expect(try db.indexes(on: "transcripts").contains { $0.columns == ["created_at"] })

            #expect(try db.columns(in: "dictionary_entries").map(\.name) == [
                "id", "trigger", "aliases", "replacement", "case_sensitive", "boost", "enabled",
                "created_at", "updated_at",
            ])
            let triggerIndex = try #require(
                try db.indexes(on: "dictionary_entries").first { $0.name == "dictionary_entries_on_trigger" }
            )
            #expect(triggerIndex.isUnique)
            #expect(triggerIndex.columns == ["trigger"])
            let indexSQL = try String.fetchOne(
                db, sql: "SELECT sql FROM sqlite_master WHERE name = 'dictionary_entries_on_trigger'"
            )
            #expect(indexSQL?.contains("COLLATE NOCASE") == true)
        }
    }

    @Test func columnDefaultsProduceReadableRows() throws {
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO transcripts (created_at, kind, raw_text, final_text, asr_model, status)
                VALUES ('2026-09-21 14:13:20.000', 'dictation', 'raw', 'final', 'asr', 'completed')
                """)
            try db.execute(sql: """
                INSERT INTO dictionary_entries ("trigger", created_at, updated_at)
                VALUES ('bare', '2026-09-21 14:13:20.000', '2026-09-21 14:13:20.000')
                """)
        }

        let record = try #require(try history.recent(limit: 1).first)
        #expect(record.createdAt == referenceDate)
        #expect(record.durationSeconds == 0)
        #expect(record.processingMilliseconds == 0)
        #expect(record.pasted == false)
        #expect(record.sourceName == nil)

        #expect(try dictionary.all() == [
            DictionaryEntry(id: 1, trigger: "bare", aliases: [], replacement: "", caseSensitive: false, boost: false, enabled: true),
        ])
    }

    @Test func fileBackedDatabaseCreatesDirectoriesAndUsesWAL() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "Application Support/Apen/Apen.sqlite")

        do {
            let database = try AppDatabase(fileURL: fileURL)
            #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
            let journalMode = try database.reader.read { db in
                try String.fetchOne(db, sql: "PRAGMA journal_mode")
            }
            #expect(journalMode == "wal")
            try HistoryStore(database: database).insert(makeRecord("persisted", at: referenceDate))
        }

        do {
            // Reopening keeps the data and does not re-run migrations.
            let reopened = try AppDatabase(fileURL: fileURL)
            #expect(try HistoryStore(database: reopened).recent(limit: 10).map(\.finalText) == ["persisted"])
        }
    }

    // MARK: - History: writing and reading

    @Test func recordInitializerDefaults() {
        let raw = TranscriptRecord(rawText: "raw", asrModel: "asr")
        #expect(raw.finalText == "raw")
        #expect(raw.kind == .dictation)
        #expect(raw.status == .completed)
        #expect(raw.pasted == false)
        #expect(TranscriptRecord(rawText: "raw", cleanedText: "Clean.", asrModel: "asr").finalText == "Clean.")
        #expect(TranscriptRecord(rawText: "raw", cleanedText: "Clean.", finalText: "Final", asrModel: "asr").finalText == "Final")
    }

    @Test func insertAndFetchRoundTripAllFields() throws {
        let record = TranscriptRecord(
            createdAt: referenceDate.addingTimeInterval(0.25),
            kind: .file,
            sourceName: "Interview — Zoë 🎙️.m4a",
            sourceBundleID: "com.apple.finder",
            durationSeconds: 83.75,
            rawText: "héllo wörld, ça va? 👋🏽 こんにちは",
            cleanedText: "Héllo wörld, ça va? 👋🏽",
            finalText: "Héllo wörld, ça va? 👋🏽 🇺🇸 👨‍👩‍👧",
            asrModel: "whisper-large-v3-turbo",
            cleanupModel: "cleanup-mini",
            processingMilliseconds: 1_234,
            status: .failed,
            error: "Paste failed: “Notes” refused ⌘V",
            audioPath: "/Users/me/Library/Application Support/Apen/Audio/ünïcode 1.m4a",
            pasted: true
        )

        let inserted = try history.insert(record)
        let id = try #require(inserted.id)
        var expected = record
        expected.id = id
        #expect(inserted == expected)
        #expect(try history.record(id: id) == expected)

        // Enums and booleans are stored as readable values; dates as UTC text.
        let row = try #require(try database.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT kind, status, pasted, created_at FROM transcripts WHERE id = ?", arguments: [id])
        })
        let kind: String? = row["kind"]
        let status: String? = row["status"]
        let pasted: Int? = row["pasted"]
        let createdAt: String? = row["created_at"]
        #expect(kind == "file")
        #expect(status == "failed")
        #expect(pasted == 1)
        #expect(createdAt == "2026-09-21 14:13:20.250")
    }

    @Test func insertAndFetchRoundTripNilOptionals() throws {
        let record = TranscriptRecord(createdAt: referenceDate, rawText: "", asrModel: "asr")
        let inserted = try history.insert(record)
        let id = try #require(inserted.id)
        let fetched = try #require(try history.record(id: id))

        #expect(fetched == inserted)
        #expect(fetched.sourceName == nil)
        #expect(fetched.sourceBundleID == nil)
        #expect(fetched.cleanedText == nil)
        #expect(fetched.cleanupModel == nil)
        #expect(fetched.error == nil)
        #expect(fetched.audioPath == nil)
        #expect(fetched.rawText.isEmpty)
        #expect(fetched.finalText.isEmpty)
    }

    @Test func insertReturnsTheRecordAsStored() throws {
        // The database keeps milliseconds; `insert` returns what reads return.
        let now = Date()
        let inserted = try history.insert(makeRecord("now", at: now))
        #expect(abs(inserted.createdAt.timeIntervalSince(now)) < 0.001)
        let id = try #require(inserted.id)
        #expect(try history.record(id: id) == inserted)
        #expect(try history.recent(limit: 1) == [inserted])
    }

    @Test func recordWithUnknownIDIsNil() throws {
        #expect(try history.record(id: 42) == nil)
    }

    @Test func updateSavesEveryColumn() throws {
        var record = try history.insert(makeRecord("draft", at: referenceDate))
        record.finalText = "Final text"
        record.cleanedText = "Cleaned"
        record.cleanupModel = "cleanup-mini"
        record.pasted = true
        record.status = .failed
        record.error = "boom"
        record.audioPath = nil
        try history.update(record)

        let id = try #require(record.id)
        #expect(try history.record(id: id) == record)
    }

    @Test func updateThrowsForMissingRecords() throws {
        var ghost = try history.insert(makeRecord("ghost", at: referenceDate))
        try history.delete(id: try #require(ghost.id))
        ghost.finalText = "edited"

        #expect(throws: RecordError.self) { try history.update(ghost) }
        #expect(throws: RecordError.self) { try history.update(makeRecord("never inserted", at: referenceDate)) }
    }

    @Test func recentReturnsNewestFirstUpToLimit() throws {
        for (minute, text) in ["one", "two", "three", "four"].enumerated() {
            try history.insert(makeRecord(text, at: referenceDate.addingTimeInterval(Double(minute) * 60)))
        }
        try history.insert(makeRecord("oldest, inserted last", at: referenceDate.addingTimeInterval(-3_600)))

        #expect(try history.recent(limit: 3).map(\.finalText) == ["four", "three", "two"])
        #expect(try history.recent(limit: 10).map(\.finalText) == ["four", "three", "two", "one", "oldest, inserted last"])
        #expect(try history.recent(limit: 0).isEmpty)
    }

    @Test func recentBreaksTimestampTiesByInsertionOrder() throws {
        try history.insert(makeRecord("first", at: referenceDate))
        try history.insert(makeRecord("second", at: referenceDate))

        #expect(try history.recent(limit: 2).map(\.finalText) == ["second", "first"])
    }

    // MARK: - History: search

    @Test func searchIgnoresCase() throws {
        try history.insert(makeRecord("Meeting notes for Friday", at: referenceDate))
        try history.insert(makeRecord("Über den Wolken", raw: "ÜBER DEN WOLKEN", at: referenceDate.addingTimeInterval(60)))
        try history.insert(makeRecord("Grocery list", at: referenceDate.addingTimeInterval(120)))

        #expect(try history.search("MEETING", limit: 10, offset: 0).map(\.finalText) == ["Meeting notes for Friday"])
        #expect(try history.search("notes FOR friday", limit: 10, offset: 0).map(\.finalText) == ["Meeting notes for Friday"])
        #expect(try history.search("  friday\n", limit: 10, offset: 0).map(\.finalText) == ["Meeting notes for Friday"])
        // Letters outside ASCII ignore case too.
        #expect(try history.search("über", limit: 10, offset: 0).map(\.finalText) == ["Über den Wolken"])
        #expect(try history.search("DEN WÖLKEN", limit: 10, offset: 0).isEmpty)
        #expect(try history.search("absent", limit: 10, offset: 0).isEmpty)
    }

    @Test func searchMatchesRawText() throws {
        try history.insert(makeRecord("Cleaned final text", raw: "um the ORIGINAL words", at: referenceDate))
        try history.insert(makeRecord("Unrelated", at: referenceDate.addingTimeInterval(60)))

        #expect(try history.search("original", limit: 10, offset: 0).map(\.finalText) == ["Cleaned final text"])
        #expect(try history.search("cleaned", limit: 10, offset: 0).map(\.finalText) == ["Cleaned final text"])
    }

    @Test func searchMatchesTextWithoutCase() throws {
        try history.insert(makeRecord("こんにちは世界 🌏", at: referenceDate))
        try history.insert(makeRecord("hello world", at: referenceDate.addingTimeInterval(60)))

        #expect(try history.search("世界", limit: 10, offset: 0).map(\.finalText) == ["こんにちは世界 🌏"])
        #expect(try history.search("🌏", limit: 10, offset: 0).map(\.finalText) == ["こんにちは世界 🌏"])
    }

    @Test func searchMatchesWildcardsAndBackslashLiterally() throws {
        let texts = [
            "100% sure", "100 percent sure",
            "snake_case name", "snakeXcase name",
            #"C:\temp\file"#, "C:/temp/file",
            "Ärger_1", "ÄrgerX1",
        ]
        for (second, text) in texts.enumerated() {
            try history.insert(makeRecord(text, at: referenceDate.addingTimeInterval(Double(second))))
        }

        func search(_ query: String) throws -> [String] {
            try history.search(query, limit: 10, offset: 0).map(\.finalText)
        }
        #expect(try search("100%") == ["100% sure"])
        #expect(try search("%") == ["100% sure"])
        #expect(try search("e_c") == ["snake_case name"])
        #expect(try search("_") == ["Ärger_1", "snake_case name"])
        #expect(try search(#"\temp"#) == [#"C:\temp\file"#])
        #expect(try search(#"\"#) == [#"C:\temp\file"#])
        // Escaping also holds on the Unicode case-folding path.
        #expect(try search("ärger_1") == ["Ärger_1"])
    }

    @Test func searchWithBlankQueryReturnsRecent() throws {
        for (minute, text) in ["a", "b", "c"].enumerated() {
            try history.insert(makeRecord(text, at: referenceDate.addingTimeInterval(Double(minute) * 60)))
        }

        #expect(try history.search("", limit: 2, offset: 0).map(\.finalText) == ["c", "b"])
        #expect(try history.search(" \n\t", limit: 2, offset: 1).map(\.finalText) == ["b", "a"])
    }

    @Test func searchPagesNewestFirst() throws {
        for minute in 0..<5 {
            try history.insert(makeRecord("note \(minute)", at: referenceDate.addingTimeInterval(Double(minute) * 60)))
        }
        try history.insert(makeRecord("other", at: referenceDate.addingTimeInterval(600)))

        #expect(try history.search("NOTE", limit: 2, offset: 0).map(\.finalText) == ["note 4", "note 3"])
        #expect(try history.search("NOTE", limit: 2, offset: 2).map(\.finalText) == ["note 2", "note 1"])
        #expect(try history.search("NOTE", limit: 2, offset: 4).map(\.finalText) == ["note 0"])
    }

    // MARK: - History: pruning and deleting

    @Test func pruneDeletesOldTranscriptsAndReportsTheirAudio() throws {
        let now = referenceDate
        try history.insert(makeRecord("old with audio", at: now - days(40), audioPath: "/audio/old.m4a"))
        try history.insert(makeRecord("old, older audio", at: now - days(45), audioPath: "/audio/older.m4a"))
        try history.insert(makeRecord("old without audio", at: now - days(31)))
        try history.insert(makeRecord("old, empty audio path", at: now - days(35), audioPath: ""))
        try history.insert(makeRecord("exactly 30 days", at: now - days(30), audioPath: "/audio/boundary.m4a"))
        try history.insert(makeRecord("recent", at: now - days(29), audioPath: "/audio/recent.m4a"))

        #expect(try history.audioPathsOlderThan(days: 30, now: now) == ["/audio/older.m4a", "/audio/old.m4a"])
        #expect(try history.prune(olderThan: 30, now: now) == 4)
        #expect(try history.recent(limit: 10).map(\.finalText) == ["recent", "exactly 30 days"])

        #expect(try history.audioPathsOlderThan(days: 30, now: now).isEmpty)
        #expect(try history.prune(olderThan: 30, now: now) == 0)
    }

    @Test(arguments: [0, -1, Int.max])
    func pruneKeepsEverythingForNonPositiveOrHugeRetention(retention: Int) throws {
        try history.insert(makeRecord("ancient", at: referenceDate - days(1_000), audioPath: "/audio/ancient.m4a"))

        #expect(try history.audioPathsOlderThan(days: retention, now: referenceDate).isEmpty)
        #expect(try history.prune(olderThan: retention, now: referenceDate) == 0)
        #expect(try history.recent(limit: 10).count == 1)
    }

    @Test func failedRecordsReturnsOnlyFailuresNewestFirst() throws {
        try history.insert(makeRecord("ok 1", at: referenceDate))
        try history.insert(makeRecord("failed 1", at: referenceDate.addingTimeInterval(60), status: .failed))
        try history.insert(makeRecord("ok 2", at: referenceDate.addingTimeInterval(120)))
        try history.insert(makeRecord("failed 2", at: referenceDate.addingTimeInterval(180), status: .failed))

        let failed = try history.failedRecords()
        #expect(failed.map(\.finalText) == ["failed 2", "failed 1"])
        #expect(failed.allSatisfy { $0.status == .failed && $0.error != nil })
    }

    @Test func deleteRemovesOneTranscriptAndDeleteAllRemovesEverything() throws {
        let first = try history.insert(makeRecord("first", at: referenceDate))
        let second = try history.insert(makeRecord("second", at: referenceDate.addingTimeInterval(60)))
        let third = try history.insert(makeRecord("third", at: referenceDate.addingTimeInterval(120)))

        let secondID = try #require(second.id)
        try history.delete(id: secondID)
        #expect(try history.record(id: secondID) == nil)
        #expect(try history.recent(limit: 10) == [third, first])

        try history.delete(id: 424_242) // Unknown ids are ignored.
        #expect(try history.recent(limit: 10).count == 2)

        try history.deleteAll()
        #expect(try history.recent(limit: 10).isEmpty)
    }

    // MARK: - History: observation

    @Test func observeRecentEmitsInitialValueThenChanges() async throws {
        let history = self.history
        try history.insert(makeRecord("first", at: referenceDate))

        let emitted = try await withTimeout(.seconds(10)) {
            var received: [[String]] = []
            for await records in history.observeRecent(limit: 2) {
                received.append(records.map(\.finalText))
                switch received.count {
                case 1: try history.insert(makeRecord("second", at: referenceDate.addingTimeInterval(60)))
                case 2: try history.insert(makeRecord("third", at: referenceDate.addingTimeInterval(120)))
                default: return received
                }
            }
            return received
        }

        #expect(emitted == [["first"], ["second", "first"], ["third", "second"]])
    }

    @Test func observeRecentWorksOnFileBackedDatabase() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let emitted: [[String]]
        do {
            let history = HistoryStore(database: try AppDatabase(fileURL: root.appending(path: "Apen.sqlite")))
            emitted = try await withTimeout(.seconds(10)) {
                var received: [[String]] = []
                for await records in history.observeRecent(limit: 10) {
                    received.append(records.map(\.finalText))
                    if received.count == 1 {
                        try history.insert(makeRecord("dictated", at: referenceDate))
                    } else {
                        break
                    }
                }
                return received
            }
        }

        #expect(emitted == [[], ["dictated"]])
    }

    // MARK: - Dictionary

    @Test func dictionarySaveInsertsThenUpdates() throws {
        let createdAt = referenceDate
        let updatedAt = referenceDate.addingTimeInterval(3_600)
        let creatingStore = DictionaryStore(database: database, now: { createdAt })
        let updatingStore = DictionaryStore(database: database, now: { updatedAt })

        /// `created_at` and `updated_at` of the entry.
        func timestamps(_ id: Int64) throws -> [Date] {
            let row = try #require(try database.reader.read { db in
                try Row.fetchOne(db, sql: "SELECT created_at, updated_at FROM dictionary_entries WHERE id = ?", arguments: [id])
            })
            return [row["created_at"], row["updated_at"]]
        }

        let saved = try creatingStore.save(DictionaryEntry(
            trigger: "gpt", aliases: ["G P T"], replacement: "GPT", caseSensitive: true, boost: false, enabled: false
        ))
        let id = try #require(saved.id)
        #expect(try dictionary.all() == [saved])
        #expect(saved.caseSensitive && !saved.boost && !saved.enabled)
        #expect(try timestamps(id) == [createdAt, createdAt])

        var edited = saved
        edited.replacement = "GPT-5"
        edited.aliases = ["G.P.T."]
        edited.boost = true
        edited.enabled = true
        #expect(try updatingStore.save(edited) == edited)
        #expect(try dictionary.all() == [edited])
        #expect(try timestamps(id) == [createdAt, updatedAt])

        // An entry whose row is gone is inserted again.
        try dictionary.delete(id: id)
        #expect(try dictionary.save(edited) == edited)
        #expect(try dictionary.all() == [edited])
    }

    @Test func dictionaryRejectsDuplicateTriggersIgnoringCase() throws {
        let openAI = try dictionary.save(DictionaryEntry(trigger: "OpenAI"))

        #expect(throws: DictionaryStoreError.duplicateTrigger("openai")) {
            try dictionary.save(DictionaryEntry(trigger: "openai"))
        }

        var renamed = try dictionary.save(DictionaryEntry(trigger: "Anthropic"))
        renamed.trigger = "OPENAI"
        #expect(throws: DictionaryStoreError.duplicateTrigger("OPENAI")) {
            try dictionary.save(renamed)
        }

        // Saving an entry again, with its own trigger, is not a duplicate.
        try dictionary.save(openAI)
        #expect(try dictionary.all().map(\.trigger) == ["Anthropic", "OpenAI"])
        #expect(DictionaryStoreError.duplicateTrigger("openai").localizedDescription.contains("openai"))
    }

    @Test func dictionaryStoresAliasesAsJSONText() throws {
        let aliases = ["Open AI", "open-a.i.", "AC/DC", #"a "quote" and a \ backslash"#, "Zoë 🤖", ""]
        let saved = try dictionary.save(DictionaryEntry(trigger: "OpenAI", aliases: aliases))
        let bare = try dictionary.save(DictionaryEntry(trigger: "bare"))

        #expect(try dictionary.all().map(\.aliases) == [[], aliases])

        func storedAliases(_ entry: DictionaryEntry) throws -> String? {
            try database.reader.read { db in
                try String.fetchOne(db, sql: "SELECT aliases FROM dictionary_entries WHERE id = ?", arguments: [entry.id])
            }
        }
        let json = try #require(try storedAliases(saved))
        #expect(try JSONDecoder().decode([String].self, from: Data(json.utf8)) == aliases)
        #expect(json.contains("AC/DC"))
        #expect(try storedAliases(bare) == "[]")

        // Malformed JSON, which only outside edits can produce, reads as no aliases.
        try database.writer.write { db in
            try db.execute(sql: "UPDATE dictionary_entries SET aliases = 'not json' WHERE id = ?", arguments: [saved.id])
        }
        #expect(try dictionary.all().map(\.aliases) == [[], []])
    }

    @Test func dictionaryAllIsOrderedByTriggerIgnoringCase() throws {
        for trigger in ["banana", "Cherry", "apple", "Banana split", "APRICOT"] {
            try dictionary.save(DictionaryEntry(trigger: trigger))
        }

        #expect(try dictionary.all().map(\.trigger) == ["apple", "APRICOT", "banana", "Banana split", "Cherry"])
    }

    @Test func dictionaryReplaceAllSwapsTheWholeDictionaryAtomically() throws {
        try dictionary.save(DictionaryEntry(trigger: "stale"))

        try dictionary.replaceAll([
            DictionaryEntry(id: 77, trigger: "Kubernetes", aliases: ["k8s", "kube"], replacement: "Kubernetes"),
            DictionaryEntry(trigger: "gRPC", caseSensitive: true),
        ])
        let imported = try dictionary.all()
        #expect(imported.map(\.trigger) == ["gRPC", "Kubernetes"])
        #expect(imported.allSatisfy { $0.id != nil && $0.id != 77 })
        #expect(imported.last?.aliases == ["k8s", "kube"])
        #expect(imported.first?.caseSensitive == true)

        // A duplicate anywhere in the import leaves the dictionary untouched.
        #expect(throws: DictionaryStoreError.duplicateTrigger("KUBERNETES")) {
            try dictionary.replaceAll([
                DictionaryEntry(trigger: "new"),
                DictionaryEntry(trigger: "kubernetes"),
                DictionaryEntry(trigger: "KUBERNETES"),
            ])
        }
        #expect(try dictionary.all() == imported)

        try dictionary.replaceAll([])
        #expect(try dictionary.all().isEmpty)
    }

    @Test func dictionaryDeleteRemovesOneEntry() throws {
        let alpha = try dictionary.save(DictionaryEntry(trigger: "alpha"))
        let beta = try dictionary.save(DictionaryEntry(trigger: "beta"))

        try dictionary.delete(id: try #require(alpha.id))
        try dictionary.delete(id: 999) // Unknown ids are ignored.
        #expect(try dictionary.all() == [beta])
    }

    @Test func observeAllEmitsInitialValueThenChanges() async throws {
        let dictionary = self.dictionary

        let emitted = try await withTimeout(.seconds(10)) {
            var received: [[String]] = []
            for await entries in dictionary.observeAll() {
                received.append(entries.map(\.trigger))
                if received.count == 1 {
                    try dictionary.save(DictionaryEntry(trigger: "Apen"))
                } else {
                    break
                }
            }
            return received
        }

        #expect(emitted == [[], ["Apen"]])
    }
}
