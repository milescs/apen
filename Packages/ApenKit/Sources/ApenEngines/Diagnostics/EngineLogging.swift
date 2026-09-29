import FluidAudio

public enum EngineLogging {
    /// Keeps FluidAudio from writing recognized text to the unified log (it logs transcripts at debug level).
    public static func quiet() {
        AppLogger.minimumLevel = .warning
    }
}
