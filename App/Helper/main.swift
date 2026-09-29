import ApenLLM
import Foundation

// apen-llm: runs Apen's optional cleanup model in its own process, so every byte it uses is returned to
// the system when the dictation ends. Apen launches it with `--llm-helper <model.gguf>` and talks to it
// over stdin/stdout (see LLMHelper).
await LLMHelper.run()
exit(0)
