/// Serializes Core ML inference across transcription sessions.
///
/// FluidAudio managers crash when two of them run Core ML predictions at the same time
/// (FluidAudio #661), so a dictation and a file job take turns through this lock.
public actor CoreMLGate {
    public static let shared = CoreMLGate()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
