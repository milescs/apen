import ApenLLM
import Foundation

/// Runs the cleanup LLM in a helper process that exists only while a dictation needs it.
///
/// A session calls `checkout()` when recording starts, so the model loads while you talk, and `checkin()`
/// when it ends; the helper then exits (after the optional keep-warm period) and the OS reclaims all of its
/// memory. `cancelInFlight()` kills the helper to skip a cleanup immediately.
public actor CleanupHost {
    public static let shared = CleanupHost()

    private let helperExecutable: URL?
    private var helper: HelperProcess?
    private var starting: Task<HelperProcess, Error>?
    private var users = 0
    private var keepWarm: Duration = .zero
    private var shutdownTask: Task<Void, Never>?

    /// - Parameter helperExecutable: a binary that implements `LLMHelper.flag`. Defaults to `APEN_LLM_HELPER`
    ///   when set (tests), else the app's bundled `apen-llm` tool, else — outside an app bundle, i.e. the
    ///   CLI — the current executable. An app never relaunches itself: in the App Sandbox the system aborts
    ///   a child that carries its own sandbox entitlements, so the helper is a separate inheriting tool.
    public init(helperExecutable: URL? = nil) {
        if let helperExecutable {
            self.helperExecutable = helperExecutable
        } else if let override = ProcessInfo.processInfo.environment["APEN_LLM_HELPER"] {
            self.helperExecutable = URL(fileURLWithPath: override)
        } else if let bundled = Bundle.main.url(forAuxiliaryExecutable: "apen-llm") {
            self.helperExecutable = bundled
        } else if Bundle.main.bundleURL.pathExtension != "app" {
            self.helperExecutable = Bundle.main.executableURL
        } else {
            self.helperExecutable = nil
        }
    }

    public var isRunning: Bool { helper != nil }

    public func setKeepWarm(_ duration: Duration) {
        keepWarm = max(.zero, duration)
        if keepWarm == .zero, users == 0 { shutdownNow() }
    }

    /// Starts the helper (loading the model) if needed. Balance every successful call with `checkin()`.
    public func checkout() async throws {
        shutdownTask?.cancel()
        shutdownTask = nil
        users += 1
        do {
            _ = try await runningHelper()
        } catch {
            users -= 1
            throw error
        }
    }

    public func checkin() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        guard keepWarm > .zero else {
            shutdownNow()
            return
        }
        let delay = keepWarm
        shutdownTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.shutdownIfIdle()
        }
    }

    /// Greedy completion in the helper.
    public func generate(
        messages: [LlamaRuntime.Message],
        maxTokens: Int,
        expectedTokens: Int? = nil,
        timeout: Duration,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        let helper = try await runningHelper()
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        return try await helper.generate(
            messages: messages, maxTokens: maxTokens, expectedTokens: expectedTokens,
            timeoutSeconds: seconds, progress: progress
        )
    }

    /// Kills the helper so an in-flight generation fails right away (the next request restarts it).
    public func cancelInFlight() {
        starting?.cancel()
        starting = nil
        helper?.terminate()
        helper = nil
    }

    private func runningHelper() async throws -> HelperProcess {
        if let helper, helper.isAlive { return helper }
        helper = nil
        guard CleanupModel.isDownloaded else { throw CleanupEngineError.modelMissing }
        guard let helperExecutable else { throw CleanupEngineError.helperUnavailable }
        let task = starting ?? Task {
            try await HelperProcess.launch(executable: helperExecutable, modelURL: CleanupModel.fileURL)
        }
        starting = task
        defer { starting = nil }
        let launched = try await task.value
        helper = launched
        return launched
    }

    private func shutdownIfIdle() {
        if users == 0 { shutdownNow() }
    }

    private func shutdownNow() {
        shutdownTask?.cancel()
        shutdownTask = nil
        helper?.close()
        helper = nil
    }
}

public enum CleanupEngineError: LocalizedError {
    case modelMissing
    case helperUnavailable
    case helperFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing: "The cleanup model isn't downloaded. Download it in Apen's Settings, or turn cleanup off."
        case .helperUnavailable: "The cleanup helper couldn't be started."
        case .helperFailed(let message): "Cleanup failed: \(message)"
        }
    }
}

/// The parent's handle on one helper process: line-delimited JSON over stdin/stdout.
final class HelperProcess: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let reader: LineReader
    private let lock = NSLock()
    private var nextID = 0

    private init(process: Process, input: FileHandle, reader: LineReader) {
        self.process = process
        self.input = input
        self.reader = reader
    }

    var isAlive: Bool { process.isRunning }

    static func launch(executable: URL, modelURL: URL) async throws -> HelperProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = [LLMHelper.flag, modelURL.path]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let helper = HelperProcess(process: process, input: stdin.fileHandleForWriting, reader: LineReader(stdout.fileHandleForReading))
        guard let first = await helper.reader.nextLine(),
            let response = try? JSONDecoder().decode(LLMHelper.Response.self, from: Data(first.utf8))
        else {
            helper.terminate()
            throw CleanupEngineError.helperFailed("the helper exited before loading the model")
        }
        guard response.ready == true else {
            helper.terminate()
            throw CleanupEngineError.helperFailed(response.error ?? "the model didn't load")
        }
        return helper
    }

    func generate(
        messages: [LlamaRuntime.Message],
        maxTokens: Int,
        expectedTokens: Int?,
        timeoutSeconds: Double,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> String {
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        let request = LLMHelper.Request(
            id: id,
            messages: messages.map { LLMHelper.Message(role: $0.role, content: $0.content) },
            maxTokens: maxTokens,
            timeoutSeconds: timeoutSeconds,
            expectedTokens: expectedTokens
        )
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        do {
            try input.write(contentsOf: data)
        } catch {
            throw CleanupEngineError.helperFailed("the helper stopped")
        }
        while let line = await reader.nextLine() {
            guard let response = try? JSONDecoder().decode(LLMHelper.Response.self, from: Data(line.utf8)),
                response.id == id
            else { continue }
            if let fraction = response.progress {
                progress?(fraction)
                continue
            }
            if let text = response.text { return text }
            throw CleanupEngineError.helperFailed(response.error ?? "no output")
        }
        throw CleanupEngineError.helperFailed("the helper stopped")
    }

    /// Closes stdin; the helper frees the model and exits.
    func close() {
        try? input.close()
        let process = process
        // Don't wait forever on a wedged helper.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { process.terminate() }
        }
    }

    func terminate() {
        try? input.close()
        if process.isRunning { process.terminate() }
    }
}

/// Reads newline-delimited text from a pipe without blocking a Swift concurrency thread.
final class LineReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [String] = []
    private var waiters: [CheckedContinuation<String?, Never>] = []
    private var isClosed = false

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            self?.receive(chunk)
        }
    }

    func nextLine() async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !lines.isEmpty {
                let line = lines.removeFirst()
                lock.unlock()
                continuation.resume(returning: line)
            } else if isClosed {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func receive(_ chunk: Data) {
        lock.lock()
        var resumed: [(CheckedContinuation<String?, Never>, String?)] = []
        if chunk.isEmpty {
            isClosed = true
            handle.readabilityHandler = nil
            resumed = waiters.map { ($0, nil) }
            waiters.removeAll()
        } else {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                if waiters.isEmpty {
                    lines.append(line)
                } else {
                    resumed.append((waiters.removeFirst(), line))
                }
            }
        }
        lock.unlock()
        for (continuation, line) in resumed { continuation.resume(returning: line) }
    }
}
