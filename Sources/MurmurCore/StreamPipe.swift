import Foundation

/// A thread-safe handle onto an `AsyncStream` continuation.
///
/// Audio arrives on the capture thread and must reach the recognizer **in
/// order**. Spawning a `Task` per buffer does not guarantee that: tasks on an
/// actor are not FIFO, so buffers can be delivered out of sequence, and a
/// session can be finalized before the last of them has run at all. Yielding
/// straight into the continuation is synchronous, ordered, and safe to call
/// from any thread.
public final class StreamPipe<Element>: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: AsyncStream<Element>.Continuation?

    public init() {}

    public func attach(_ continuation: AsyncStream<Element>.Continuation) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    public func yield(_ value: Element) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(value)
    }

    public func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }
}
