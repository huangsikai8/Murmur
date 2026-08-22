import Foundation

/// Runs `work`, and gives up *waiting* for it after `deadline`. Returns nil if
/// the deadline passed first.
///
/// The work is abandoned rather than cancelled, which is the whole point: an
/// MLX generation pass does not check for cancellation, so the only thing that
/// can honestly be bounded is how long anything waits on it. Cancelling a task
/// group would not help — the group still waits for every child before it
/// returns, which is the wait being escaped here.
public func withDeadline<T: Sendable>(
    _ deadline: Duration,
    _ work: @escaping @Sendable () async -> T
) async -> T? {
    let once = OnceBox()
    var timer: Task<Void, Never>?
    let result = await withCheckedContinuation {
        (continuation: CheckedContinuation<T?, Never>) in
        Task {
            let value = await work()
            if once.claim() { continuation.resume(returning: value) }
        }
        timer = Task {
            try? await Task.sleep(for: deadline)
            if once.claim() { continuation.resume(returning: nil) }
        }
    }
    // The wait is over, so this timer can only ever find the box already
    // claimed. Cancelled rather than left to sleep the deadline out: cleanup
    // is bounded at 20 s, so every utterance otherwise left a task asleep for
    // that long, and continuous dictation accumulated one per sentence.
    timer?.cancel()
    return result
}

/// Lets exactly one of two racing tasks resume the continuation. Resuming a
/// continuation twice is a crash, not a warning.
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
