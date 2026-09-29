import os

/// Unified-log categories. Never log transcript text — only events, timings and states.
enum Log {
    static let session = Logger(subsystem: "com.milescs.apen", category: "session")
    static let paste = Logger(subsystem: "com.milescs.apen", category: "paste")
}
