import Foundation
import MurmurCore

/// Choices that survive a restart.
@MainActor
final class Preferences: ObservableObject {

    static let shared = Preferences()

    private enum Key {
        static let hotkey = "murmur.hotkey"
        static let cleanupLevel = "murmur.cleanupLevel"
        static let minimumHoldMilliseconds = "murmur.minimumHoldMilliseconds"
        static let activeSpeechModel = "murmur.activeSpeechModel"
        static let activeCorrectionModel = "murmur.activeCorrectionModel"
    }

    private let defaults = UserDefaults.standard

    @Published var hotkey: Hotkey {
        didSet { defaults.set(hotkey.rawValue, forKey: Key.hotkey) }
    }

    @Published var cleanupLevel: CleanupLevel {
        didSet { defaults.set(cleanupLevel.rawValue, forKey: Key.cleanupLevel) }
    }

    @Published var minimumHoldMilliseconds: Int {
        didSet { defaults.set(minimumHoldMilliseconds, forKey: Key.minimumHoldMilliseconds) }
    }

    @Published var activeSpeechModelID: String {
        didSet { defaults.set(activeSpeechModelID, forKey: Key.activeSpeechModel) }
    }

    @Published var activeCorrectionModelID: String {
        didSet { defaults.set(activeCorrectionModelID, forKey: Key.activeCorrectionModel) }
    }

    private init() {
        hotkey = (defaults.string(forKey: Key.hotkey).flatMap(Hotkey.init(rawValue:))) ?? .fn
        cleanupLevel =
            (defaults.string(forKey: Key.cleanupLevel).flatMap(CleanupLevel.init(rawValue:))) ?? .off
        let stored = defaults.integer(forKey: Key.minimumHoldMilliseconds)
        minimumHoldMilliseconds = stored > 0 ? stored : 250
        activeSpeechModelID =
            defaults.string(forKey: Key.activeSpeechModel) ?? ModelCatalog.appleSpeechID
        activeCorrectionModelID =
            defaults.string(forKey: Key.activeCorrectionModel) ?? ModelCatalog.appleCorrectionID
    }
}
