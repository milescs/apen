import Foundation
import ApenEngines
import ApenLLM

// Command-line companion for model management, headless transcription and measurements.
//
//   apen models status
//   apen models download [--boost]
//   apen models download --cleanup
//   apen transcribe <audio-file> [--realtime] [--memory]

@main
struct ApenCLI {
    static func main() async {
        if CommandLine.arguments.contains(LLMHelper.flag) {
            await LLMHelper.run()
            exit(0)
        }
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            exit(64)
        }
        arguments.removeFirst()
        do {
            switch command {
            case "models":
                try await models(arguments)
            case "transcribe":
                try await Transcribe.run(arguments)
            default:
                printUsage()
                exit(64)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func models(_ arguments: [String]) async throws {
        switch arguments.first {
        case "status":
            print("\(SpeechModel.displayName): \(SpeechModel.isDownloaded ? "downloaded" : "missing") — \(SpeechModel.directory.path)")
            print("Vocabulary boost model: \(BoostModel.isDownloaded ? "downloaded" : "missing") — \(BoostModel.directory.path)")
            print("Cleanup model: \(CleanupModel.isDownloaded ? "downloaded" : "missing") — \(CleanupModel.fileURL.path)")
        case "download" where arguments.contains("--cleanup"):
            try await CleanupModel.download { fraction in
                FileHandle.standardError.write(Data("\rDownloading \(CleanupModel.displayName): \(Int(fraction * 100))%   ".utf8))
            }
            print("\n\(CleanupModel.displayName) downloaded and verified")
        case "download":
            let start = Date()
            try await SpeechModel.download { progress in
                FileHandle.standardError.write(Data("\r\(progress.label)                    ".utf8))
            }
            print("\n\(SpeechModel.displayName) ready in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
            if arguments.contains("--boost") {
                try await BoostModel.download()
                print("Vocabulary boost model ready")
            }
        default:
            printUsage()
            exit(64)
        }
    }

    static func printUsage() {
        print("""
            usage:
              apen models status
              apen models download [--boost]
              apen models download --cleanup
              apen transcribe <audio-file> [--realtime] [--memory]
            """)
    }
}
