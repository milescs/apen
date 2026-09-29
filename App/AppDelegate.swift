import AppKit
import ApenEngines

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // FluidAudio logs recognized text at debug level; keep dictation out of the system log.
        EngineLogging.quiet()
        model.launch()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            model.open(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
