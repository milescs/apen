public import Foundation
public import GRDB

/// One dictation or file transcription in the history (`transcripts` table).
public nonisolated struct TranscriptRecord: Codable, Sendable, Hashable, Identifiable {
    public nonisolated enum Kind: String, Codable, Sendable {
        case dictation
        case file
    }

    public nonisolated enum Status: String, Codable, Sendable {
        case completed
        case failed
    }

    /// Assigned by the database on insert.
    public var id: Int64?
    public var createdAt: Date
    public var kind: Kind
    /// Display name of where the audio came from, such as an app or a file name.
    public var sourceName: String?
    public var sourceBundleID: String?
    public var durationSeconds: Double
    public var rawText: String
    public var cleanedText: String?
    /// The text that was delivered (pasted or copied).
    public var finalText: String
    public var asrModel: String
    public var cleanupModel: String?
    public var processingMilliseconds: Int
    public var status: Status
    public var error: String?
    public var audioPath: String?
    public var pasted: Bool

    /// - Parameter finalText: Defaults to `cleanedText ?? rawText`.
    public init(
        id: Int64? = nil,
        createdAt: Date = Date(),
        kind: Kind = .dictation,
        sourceName: String? = nil,
        sourceBundleID: String? = nil,
        durationSeconds: Double = 0,
        rawText: String,
        cleanedText: String? = nil,
        finalText: String? = nil,
        asrModel: String,
        cleanupModel: String? = nil,
        processingMilliseconds: Int = 0,
        status: Status = .completed,
        error: String? = nil,
        audioPath: String? = nil,
        pasted: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.sourceName = sourceName
        self.sourceBundleID = sourceBundleID
        self.durationSeconds = durationSeconds
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.finalText = finalText ?? cleanedText ?? rawText
        self.asrModel = asrModel
        self.cleanupModel = cleanupModel
        self.processingMilliseconds = processingMilliseconds
        self.status = status
        self.error = error
        self.audioPath = audioPath
        self.pasted = pasted
    }

    /// Column names. They are also the keys of the record's JSON encoding.
    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case kind
        case sourceName = "source_name"
        case sourceBundleID = "source_bundle_id"
        case durationSeconds = "duration_s"
        case rawText = "raw_text"
        case cleanedText = "cleaned_text"
        case finalText = "final_text"
        case asrModel = "asr_model"
        case cleanupModel = "cleanup_model"
        case processingMilliseconds = "processing_ms"
        case status
        case error
        case audioPath = "audio_path"
        case pasted
    }
}

// MARK: - Persistence

nonisolated extension TranscriptRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "transcripts"

    public nonisolated enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let createdAt = Column(CodingKeys.createdAt)
        public static let kind = Column(CodingKeys.kind)
        public static let sourceName = Column(CodingKeys.sourceName)
        public static let sourceBundleID = Column(CodingKeys.sourceBundleID)
        public static let durationSeconds = Column(CodingKeys.durationSeconds)
        public static let rawText = Column(CodingKeys.rawText)
        public static let cleanedText = Column(CodingKeys.cleanedText)
        public static let finalText = Column(CodingKeys.finalText)
        public static let asrModel = Column(CodingKeys.asrModel)
        public static let cleanupModel = Column(CodingKeys.cleanupModel)
        public static let processingMilliseconds = Column(CodingKeys.processingMilliseconds)
        public static let status = Column(CodingKeys.status)
        public static let error = Column(CodingKeys.error)
        public static let audioPath = Column(CodingKeys.audioPath)
        public static let pasted = Column(CodingKeys.pasted)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
