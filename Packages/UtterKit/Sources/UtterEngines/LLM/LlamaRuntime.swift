import Foundation
import llama

/// A loaded GGUF model plus one inference context, used for short single-turn rewrites.
///
/// All llama.cpp pointers stay inside this actor. `unload()` (or deinit) frees the weights, KV cache
/// and Metal buffers, so the model only occupies memory between `load()` and `unload()`.
public actor LlamaRuntime {
    public struct Message: Sendable {
        public let role: String
        public let content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    public let modelURL: URL
    public let contextLength: Int32

    private var handles: LlamaHandles?

    public init(modelURL: URL, contextLength: Int32 = 4096) {
        self.modelURL = modelURL
        self.contextLength = contextLength
    }

    public var isLoaded: Bool { handles != nil }

    public func load() throws {
        guard handles == nil else { return }
        LlamaBackend.initialize()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1  // everything on Metal
        guard let model = llama_model_load_from_file(modelURL.path, modelParams) else {
            throw LlamaError.loadFailed(modelURL.lastPathComponent)
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextLength)
        // llama_decode aborts when a batch exceeds n_batch, so allow a whole prompt in one batch.
        contextParams.n_batch = UInt32(contextLength)
        contextParams.n_ubatch = 512
        contextParams.no_perf = true
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LlamaError.loadFailed(modelURL.lastPathComponent)
        }

        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            llama_free(context)
            llama_model_free(model)
            throw LlamaError.loadFailed(modelURL.lastPathComponent)
        }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        handles = LlamaHandles(model: model, context: context, sampler: sampler)
    }

    /// Frees the weights, KV cache and Metal buffers.
    public func unload() {
        handles = nil
    }

    /// Token count of `text` (without special tokens); used to size pieces for the context window.
    public func tokenCount(_ text: String) throws -> Int {
        try tokenize(text, special: false).count
    }

    /// Greedy completion of a chat. Stops at end-of-generation, `maxTokens`, `deadline` or task cancellation.
    public func generate(messages: [Message], maxTokens: Int, deadline: ContinuousClock.Instant? = nil) throws -> String {
        guard let handles else { throw LlamaError.notLoaded }
        let (model, context, sampler, vocab) = (handles.model, handles.context, handles.sampler, handles.vocab)

        let prompt = try applyChatTemplate(messages, model: model)
        let promptTokens = try tokenize(prompt, special: true)
        guard promptTokens.count + maxTokens <= Int(contextLength) else {
            throw LlamaError.promptTooLong(promptTokens.count, Int(contextLength))
        }

        llama_memory_clear(llama_get_memory(context), false)
        llama_sampler_reset(sampler)

        var tokens = promptTokens
        let status = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        guard status == 0 else { throw LlamaError.decodeFailed(status) }

        var output: [UInt8] = []
        var pieceBuffer = [CChar](repeating: 0, count: 256)
        let clock = ContinuousClock()
        for _ in 0..<maxTokens {
            if Task.isCancelled { throw CancellationError() }
            if let deadline, clock.now >= deadline { throw LlamaError.timedOut }

            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }

            let length = llama_token_to_piece(vocab, token, &pieceBuffer, Int32(pieceBuffer.count), 0, false)
            if length > 0 {
                output.append(contentsOf: pieceBuffer[0..<Int(length)].map { UInt8(bitPattern: $0) })
            }
            let next = withUnsafeMutablePointer(to: &token) { pointer in
                llama_decode(context, llama_batch_get_one(pointer, 1))
            }
            guard next == 0 else { throw LlamaError.decodeFailed(next) }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func applyChatTemplate(_ messages: [Message], model: OpaquePointer) throws -> String {
        let template = llama_model_chat_template(model, nil)
        let roles = messages.map { strdup($0.role) }
        let contents = messages.map { strdup($0.content) }
        defer {
            roles.forEach { free($0) }
            contents.forEach { free($0) }
        }
        let chat = zip(roles, contents).map { llama_chat_message(role: $0, content: $1) }
        let estimate = messages.reduce(0) { $0 + $1.content.utf8.count + $1.role.utf8.count } * 2 + 512
        var buffer = [CChar](repeating: 0, count: estimate)
        var length = llama_chat_apply_template(template, chat, chat.count, true, &buffer, Int32(buffer.count))
        if length > Int32(buffer.count) {
            buffer = [CChar](repeating: 0, count: Int(length) + 1)
            length = llama_chat_apply_template(template, chat, chat.count, true, &buffer, Int32(buffer.count))
        }
        guard length > 0 else { throw LlamaError.templateFailed }
        return String(decoding: buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func tokenize(_ text: String, special: Bool) throws -> [llama_token] {
        guard let vocab = handles?.vocab else { throw LlamaError.notLoaded }
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 16)
        var count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), special, special)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), special, special)
        }
        guard count >= 0 else { throw LlamaError.tokenizeFailed }
        return Array(tokens.prefix(Int(count)))
    }
}

public enum LlamaError: LocalizedError {
    case loadFailed(String)
    case notLoaded
    case templateFailed
    case tokenizeFailed
    case promptTooLong(Int, Int)
    case decodeFailed(Int32)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .loadFailed(let name): "Couldn't load the cleanup model (\(name))."
        case .notLoaded: "The cleanup model isn't loaded."
        case .templateFailed: "The cleanup model has no usable chat template."
        case .tokenizeFailed: "Couldn't tokenize the text for cleanup."
        case .promptTooLong(let tokens, let limit): "Cleanup prompt too long (\(tokens) tokens, limit \(limit))."
        case .decodeFailed(let code): "Cleanup model inference failed (code \(code))."
        case .timedOut: "Cleanup took too long."
        }
    }
}

/// Owns the llama.cpp pointers; freeing happens in deinit when the runtime drops it.
private final class LlamaHandles: @unchecked Sendable {
    let model: OpaquePointer
    let context: OpaquePointer
    let sampler: UnsafeMutablePointer<llama_sampler>
    let vocab: OpaquePointer?

    init(model: OpaquePointer, context: OpaquePointer, sampler: UnsafeMutablePointer<llama_sampler>) {
        self.model = model
        self.context = context
        self.sampler = sampler
        vocab = llama_model_get_vocab(model)
    }

    deinit {
        llama_sampler_free(sampler)
        llama_free(context)
        llama_model_free(model)
    }
}

/// Process-wide llama.cpp setup: backend init and a silent log handler.
enum LlamaBackend {
    private static let once: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    static func initialize() {
        _ = once
    }
}
