import Foundation

/// One inserted transcript.
public struct HistoryEntry: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var text: String
    public var date: Date

    public init(id: UUID = UUID(), text: String, date: Date = Date()) {
        self.id = id
        self.text = text
        self.date = date
    }
}

/// The most recent transcripts actually inserted, newest first. Capped rather
/// than unbounded, since nobody wants a growing archive of everything they
/// have ever dictated — just enough to recover the last few if focus moved or
/// a paste landed in the wrong place.
public final class HistoryStore: @unchecked Sendable {

    public static let shared = HistoryStore()
    public static let limit = 20

    /// Posted after an entry is recorded.
    ///
    /// The settings window is built once and reused, so a view that reads the
    /// store when it appears reads it exactly once and then shows a list that
    /// never changes again — which is a history of everything dictated
    /// before the window was first opened, and nothing since.
    public static let didChangeNotification = Notification.Name("murmur.historyDidChange")

    private let defaultsKey = "murmur.history"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var storage: [HistoryEntry]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            storage = decoded
        } else {
            storage = []
        }
    }

    public var entries: [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        storage.insert(HistoryEntry(text: trimmed), at: 0)
        if storage.count > Self.limit {
            storage.removeLast(storage.count - Self.limit)
        }
        persist()
        lock.unlock()
        // Posted outside the lock: an observer reads `entries` to react, and
        // doing that from inside would deadlock on a lock this call still
        // holds.
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Caller already holds the lock.
    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
