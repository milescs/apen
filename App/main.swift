import ApenEngines

// The same executable doubles as the cleanup-LLM helper process, so the model's memory is
// returned to the system as soon as a dictation ends.
if CommandLine.arguments.contains(LLMHelper.flag) {
    LLMHelper.runBlockingAndExit()
}
ApenApp.main()
