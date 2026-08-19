import AppKit

/// Starts the menu bar application. Never returns.
@MainActor
func launchMurmur() -> Never {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    // Accessory: menu bar only, no Dock icon, never becomes the active app,
    // so holding the hotkey cannot pull focus from your text field.
    application.setActivationPolicy(.accessory)
    // Keep the delegate alive for the process lifetime.
    objc_setAssociatedObject(application, "murmur.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    application.run()
    exit(0)
}

/// Runs an async operation to completion from synchronous code.
///
/// Deliberately used instead of top-level `await`: an async top level hands the
/// main thread to the concurrency runtime, and `NSApplication.run()` must own
/// it. Otherwise an app started by LaunchServices never receives
/// `applicationDidFinishLaunching`, so it never asks for the microphone and
/// never appears in Privacy settings at all.
///
/// The wait pumps the run loop rather than blocking on a semaphore. Blocking
/// would deadlock any work that needs to hop to the main actor — model loading
/// does — leaving the process alive at zero CPU forever.
func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let box = ResultBox<T>()
    Task.detached(priority: .userInitiated) {
        let value = await body()
        box.complete(with: value)
    }
    while !box.isFinished {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return box.value!
}

private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T?
    private var finished = false

    func complete(with value: T) {
        lock.lock()
        storage = value
        finished = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var value: T? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
