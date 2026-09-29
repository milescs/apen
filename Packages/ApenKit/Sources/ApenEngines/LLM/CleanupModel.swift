import CryptoKit
import Foundation

/// The optional cleanup LLM: Qwen3-4B-Instruct-2507, Q4_K_M GGUF (Apache-2.0).
public enum CleanupModel {
    public static let displayName = "Qwen3 4B Instruct (2507)"
    public static let identifier = "qwen3-4b-instruct-2507-q4_k_m"
    public static let fileName = "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
    public static let downloadURL = URL(
        string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
    )!
    public static let sha256 = "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597"
    public static let byteCount: Int64 = 2_497_281_120

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apen/Models", isDirectory: true)
    }

    public static var fileURL: URL { directory.appendingPathComponent(fileName) }

    /// Present with the expected size (the hash is verified once, at download time).
    public static var isDownloaded: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
        return size == byteCount
    }

    /// Downloads, verifies the SHA-256 and moves the file into place. The only network access for cleanup.
    public static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let downloaded = try await FileDownloader.download(downloadURL, progress: progress)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let digest = try sha256Hex(of: downloaded)
        guard digest == sha256 else { throw CleanupModelError.checksumMismatch }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: downloaded, to: fileURL)
    }

    public static func delete() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 16 * 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum CleanupModelError: LocalizedError {
    case checksumMismatch

    public var errorDescription: String? {
        "The downloaded cleanup model didn't match its published checksum, so it was discarded. Try again."
    }
}

/// URLSession download with progress and cancellation, returning a temporary file URL.
enum FileDownloader {
    static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var _continuation: CheckedContinuation<URL, Error>?

    var continuation: CheckedContinuation<URL, Error>? {
        get { lock.withLock { _continuation } }
        set { lock.withLock { _continuation = newValue } }
    }

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    private func resume(with result: Result<URL, Error>) {
        let continuation = lock.withLock {
            defer { _continuation = nil }
            return _continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns, so move it first.
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("apen-\(UUID().uuidString).download")
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            resume(with: .success(destination))
        } catch {
            resume(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { resume(with: .failure(error)) }
    }
}
