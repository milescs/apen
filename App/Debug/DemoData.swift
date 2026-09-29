import Foundation
import ApenCore

/// Sample content for screenshots: `Apen.app/Contents/MacOS/Apen --demo` (Debug builds) uses a throwaway
/// database and a separate preferences domain, so real history, dictionary and settings are never touched.
enum DemoData {
    static var isEnabled: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--demo")
        #else
        false
        #endif
    }

    static var defaults: UserDefaults {
        let defaults = UserDefaults(suiteName: "com.milescs.apen.demo") ?? .standard
        defaults.set(true, forKey: "cleanupEnabled")
        defaults.set("coding", forKey: "selectedModeID")
        return defaults
    }

    static func makeDatabase() throws -> AppDatabase {
        let database = try AppDatabase.inMemory()
        let history = HistoryStore(database: database)
        let now = Date()
        let samples: [(minutesAgo: Double, app: String, bundle: String, seconds: Double, text: String, kind: TranscriptRecord.Kind)] = [
            (2, "Cursor", "com.todesktop.230313mzl4w4u92", 21,
             "In `ContentView.swift`, refactor the list into a `LazyVStack` and add pull-to-refresh. Keep the existing loading state and don't change the API client.", .dictation),
            (9, "Claude", "com.anthropic.claudefordesktop", 48,
             "Can you review this pull request and flag any race conditions in the `SessionManager` actor? Focus on the reconnect logic, and suggest a test that reproduces the issue.", .dictation),
            (26, "Slack", "com.tinyspeck.slackmacgap", 6,
             "Running about ten minutes late. Start the standup without me and I'll catch up on the notes.", .dictation),
            (64, "Mail", "com.apple.mail", 17,
             "Hi Sam,\n\nThanks for the draft. The timeline looks good, but can we move the launch review to Thursday?\n\nBest,\nAlex", .dictation),
            (190, "Terminal", "com.apple.Terminal", 34,
             "Write a migration that adds a `deleted_at` column to the orders table and backfills it from the archive table in batches of 1,000.", .dictation),
            (1500, "Team sync.m4a", "", 1714,
             "Okay, let's get started. First up is the release checklist: QA signed off on the beta yesterday, so the remaining items are the App Store screenshots and the privacy policy page…", .file),
        ]
        for sample in samples {
            _ = try history.insert(
                TranscriptRecord(
                    createdAt: now.addingTimeInterval(-sample.minutesAgo * 60),
                    kind: sample.kind,
                    sourceName: sample.app,
                    sourceBundleID: sample.bundle.isEmpty ? nil : sample.bundle,
                    durationSeconds: sample.seconds,
                    rawText: sample.text,
                    finalText: sample.text,
                    asrModel: "Parakeet Unified EN 0.6B",
                    cleanupModel: "Qwen3 4B Instruct (2507) · Coding",
                    processingMilliseconds: 900,
                    pasted: sample.kind == .dictation
                )
            )
        }
        let dictionary = DictionaryStore(database: database)
        for entry in [
            DictionaryEntry(trigger: "RLS", replacement: "row-level security"),
            DictionaryEntry(trigger: "k8s", replacement: "Kubernetes"),
            DictionaryEntry(trigger: "LGTM", replacement: "looks good to me"),
            DictionaryEntry(trigger: "PR", replacement: "pull request", caseSensitive: true),
            DictionaryEntry(trigger: "Supabase", aliases: ["super base", "supa base"]),
            DictionaryEntry(trigger: "SwiftUI", aliases: ["swift UI"]),
        ] {
            _ = try dictionary.save(entry)
        }
        return database
    }
}
