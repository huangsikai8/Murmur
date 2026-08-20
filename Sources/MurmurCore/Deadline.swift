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
    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        Task {
            let value = await work()
            if once.claim() { continuation.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(for: deadline)
            if once.claim() { continuation.resume(returning: nil) }
        }
    }
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
