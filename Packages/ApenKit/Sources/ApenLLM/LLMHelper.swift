import Foundation

/// Child-process side of the cleanup LLM.
///
/// The app runs its bundled `apen-llm` tool (the CLI uses its own executable) with `--llm-helper <model.gguf>`.
/// The helper loads the model, prints `{"ready":true}`, then answers one JSON request per stdin line until
/// stdin closes.
/// Running the model out of process means every byte it used (including Metal allocations llama.cpp
/// can't release) goes back to the system the moment the dictation ends.
public enum LLMHelper {
    public static let flag = "--llm-helper"

    package struct Request: Codable {
        package let id: Int
        package let messages: [Message]
        package let maxTokens: Int
        package let timeoutSeconds: Double?
        /// Typical output length, used only to report progress.
        package var expectedTokens: Int?

        package init(id: Int, messages: [Message], maxTokens: Int, timeoutSeconds: Double?, expectedTokens: Int?) {
            self.id = id
            self.messages = messages
            self.maxTokens = maxTokens
            self.timeoutSeconds = timeoutSeconds
            self.expectedTokens = expectedTokens
        }
    }

    package struct Message: Codable {
        package let role: String
        package let content: String

        package init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    package struct Response: Codable {
        package var ready: Bool?
        package var id: Int?
        package var text: String?
        package var error: String?
        /// 0…1 while generating (estimated from `expectedTokens`).
        package var progress: Double?

        package init(ready: Bool? = nil, id: Int? = nil, text: String? = nil, error: String? = nil, progress: Double? = nil) {
            self.ready = ready
            self.id = id
            self.text = text
            self.error = error
            self.progress = progress
        }
    }

    /// For synchronous `main.swift` entry points: runs the helper and exits the process; never returns.
    public static func runBlockingAndExit(arguments: [String] = CommandLine.arguments) -> Never {
        Task {
            await run(arguments: arguments)
            exit(0)
        }
        dispatchMain()
    }

    /// Serves requests until stdin reaches EOF.
    public static func run(arguments: [String] = CommandLine.arguments) async {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            send(Response(error: "missing model path"))
            return
        }
        let runtime = LlamaRuntime(modelURL: URL(fileURLWithPath: arguments[index + 1]))
        do {
            try await runtime.load()
        } catch {
            send(Response(error: error.localizedDescription))
            return
        }
        send(Response(ready: true))

        let decoder = JSONDecoder()
        while let line = readLine(strippingNewline: true) {
            guard let request = try? decoder.decode(Request.self, from: Data(line.utf8)) else {
                send(Response(error: "malformed request"))
                continue
            }
            let deadline = request.timeoutSeconds.map { ContinuousClock.now + .seconds($0) }
            do {
                let expected = max(request.expectedTokens ?? request.maxTokens, 1)
                let text = try await runtime.generate(
                    messages: request.messages.map { LlamaRuntime.Message(role: $0.role, content: $0.content) },
                    maxTokens: request.maxTokens,
                    deadline: deadline
                ) { generated in
                    if generated % 8 == 0 {
                        send(Response(id: request.id, progress: min(Double(generated) / Double(expected), 0.99)))
                    }
                }
                send(Response(id: request.id, text: text))
            } catch {
                send(Response(id: request.id, error: error.localizedDescription))
            }
        }
        await runtime.unload()
    }

    private static func send(_ response: Response) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
