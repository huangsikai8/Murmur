import Foundation
import MurmurCore

/// Choices that survive a restart.
@MainActor
final class Preferences: ObservableObject {

    static let shared = Preferences()

    private enum Key {
        static let hotkey = "murmur.hotkey"
        static let hotkeyMode = "murmur.hotkeyMode"
        static let cleanupLevel = "murmur.cleanupLevel"
        static let minimumHoldMilliseconds = "murmur.minimumHoldMilliseconds"
        static let activeSpeechModel = "murmur.activeSpeechModel"
        static let activeCorrectionModel = "murmur.activeCorrectionModel"
        static let handsFreeEnabled = "murmur.handsFreeEnabled"
        static let handsFreeSilenceMilliseconds = "murmur.handsFreeSilenceMilliseconds"
        static let handsFreeIdleMinutes = "murmur.handsFreeIdleMinutes"
        static let formatting = "murmur.formatting"
        static let handsFreeToggleShortcut = "murmur.handsFreeToggleShortcut"
        static let usesTurnDetector = "murmur.usesTurnDetector"
        static let turnDetectorThreshold = "murmur.turnDetectorThreshold"
        static let turnSilenceMilliseconds = "murmur.turnSilenceMilliseconds"
        static let scratchEnabled = "murmur.scratchEnabled"
        static let keepMicrophoneArmed = "murmur.keepMicrophoneArmed"
        static let scratchWindowSeconds = "murmur.scratchWindowSeconds"
        static let meterStyle = "murmur.meterStyle"
    }

    private let defaults = UserDefaults.standard

    /// Whether the dictation key is held or tapped. Latch exists because
    /// holding a key through a long sentence is its own kind of pressure, and
    /// because it endpoints on nothing at all — pausing to think is free.
    @Published var hotkeyMode: HotkeyMode {
        didSet { defaults.set(hotkeyMode.rawValue, forKey: Key.hotkeyMode) }
    }

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

    /// Continuous dictation. Persisted, because the point of it is not having
    /// to switch it on again — the menu bar icon carries the warning instead.
    @Published var handsFreeEnabled: Bool {
        didSet { defaults.set(handsFreeEnabled, forKey: Key.handsFreeEnabled) }
    }

    /// Silence that ends an utterance. Rounded up to 256 ms chunks by the
    /// detector, so only multiples of that actually change anything.
    @Published var handsFreeSilenceMilliseconds: Int {
        didSet {
            defaults.set(handsFreeSilenceMilliseconds, forKey: Key.handsFreeSilenceMilliseconds)
        }
    }

    /// Switches hands-free off after this long with nothing said. Zero is off.
    @Published var handsFreeIdleMinutes: Int {
        didSet { defaults.set(handsFreeIdleMinutes, forKey: Key.handsFreeIdleMinutes) }
    }

    /// Chord that turns hands-free on and off without the menu.
    @Published var handsFreeToggleShortcut: ToggleShortcut {
        didSet {
            defaults.set(handsFreeToggleShortcut.rawValue, forKey: Key.handsFreeToggleShortcut)
        }
    }

    /// Whether a pause is judged by the turn model or by a stopwatch alone.
    @Published var usesTurnDetector: Bool {
        didSet { defaults.set(usesTurnDetector, forKey: Key.usesTurnDetector) }
    }

    /// How sure the turn model must be that a thought finished. Higher waits
    /// longer before committing.
    @Published var turnDetectorThreshold: Double {
        didSet { defaults.set(turnDetectorThreshold, forKey: Key.turnDetectorThreshold) }
    }

    /// Silence that triggers a turn judgement, used instead of
    /// `handsFreeSilenceMilliseconds` whenever the turn model is loaded. Silero
    /// rounds up to whole 256 ms chunks, so only multiples of that matter.
    @Published var turnSilenceMilliseconds: Int {
        didSet { defaults.set(turnSilenceMilliseconds, forKey: Key.turnSilenceMilliseconds) }
    }

    /// Whether saying "scratch that" takes back the last insertion.
    /// Whether the input device stays open between dictations.
    ///
    /// On, a press only switches where the audio goes and costs 0.7 ms. Off,
    /// the device is opened on the key, which measured 15-360 ms — and that is
    /// speech that never existed rather than speech that arrived late. The
    /// price of leaving it on is the orange microphone indicator staying lit.
    @Published var keepMicrophoneArmed: Bool {
        didSet { defaults.set(keepMicrophoneArmed, forKey: Key.keepMicrophoneArmed) }
    }

    @Published var scratchEnabled: Bool {
        didSet { defaults.set(scratchEnabled, forKey: Key.scratchEnabled) }
    }

    /// How the input meter is drawn. Only visible for engines that produce no
    /// text until the key is released, since the others show the transcript
    /// instead and never draw a meter at all.
    @Published var meterStyle: MeterStyle {
        didSet { defaults.set(meterStyle.rawValue, forKey: Key.meterStyle) }
    }

    /// How long after an insertion "scratch that" still applies. Deleting is
    /// destructive and cannot verify where the cursor went, so this is the
    /// main thing standing between a retraction and somebody's typing.
    @Published var scratchWindowSeconds: Int {
        didSet { defaults.set(scratchWindowSeconds, forKey: Key.scratchWindowSeconds) }
    }

    /// The free, instant formatting pass. Stored whole rather than as one key
    /// per switch, so adding a rule later needs no migration.
    @Published var formatting: SpokenFormatter.Options {
        didSet {
            guard let data = try? JSONEncoder().encode(formatting) else { return }
            defaults.set(data, forKey: Key.formatting)
        }
    }

    private init() {
        hotkey = (defaults.string(forKey: Key.hotkey).flatMap(Hotkey.init(rawValue:))) ?? .fn
        hotkeyMode =
            (defaults.string(forKey: Key.hotkeyMode).flatMap(HotkeyMode.init(rawValue:))) ?? .hold
        cleanupLevel =
            (defaults.string(forKey: Key.cleanupLevel).flatMap(CleanupLevel.init(rawValue:))) ?? .off
        let stored = defaults.integer(forKey: Key.minimumHoldMilliseconds)
        minimumHoldMilliseconds = stored > 0 ? stored : 250
        activeSpeechModelID =
            defaults.string(forKey: Key.activeSpeechModel) ?? ModelCatalog.appleSpeechID
        activeCorrectionModelID =
            defaults.string(forKey: Key.activeCorrectionModel) ?? ModelCatalog.appleCorrectionID
        handsFreeEnabled = defaults.bool(forKey: Key.handsFreeEnabled)
        let silence = defaults.integer(forKey: Key.handsFreeSilenceMilliseconds)
        handsFreeSilenceMilliseconds = silence > 0 ? silence : 500
        let idle = defaults.object(forKey: Key.handsFreeIdleMinutes) as? Int
        handsFreeIdleMinutes = idle ?? 30
        handsFreeToggleShortcut =
            (defaults.string(forKey: Key.handsFreeToggleShortcut)
                .flatMap(ToggleShortcut.init(rawValue:))) ?? .none
        // `object(forKey:)` rather than `bool`/`double`, so that "never set"
        // is distinguishable from a deliberate false or zero. Reading these
        // with the plain accessors would turn a first run into "turn detector
        // off, threshold 0", which endpoints on every pause.
        usesTurnDetector = (defaults.object(forKey: Key.usesTurnDetector) as? Bool) ?? true
        turnDetectorThreshold =
            (defaults.object(forKey: Key.turnDetectorThreshold) as? Double) ?? 0.5
        let turnSilence = defaults.integer(forKey: Key.turnSilenceMilliseconds)
        turnSilenceMilliseconds = turnSilence > 0 ? turnSilence : 250
        scratchEnabled = (defaults.object(forKey: Key.scratchEnabled) as? Bool) ?? true
        meterStyle =
            (defaults.string(forKey: Key.meterStyle).flatMap(MeterStyle.init(rawValue:)))
            ?? .waveform
        keepMicrophoneArmed =
            (defaults.object(forKey: Key.keepMicrophoneArmed) as? Bool) ?? true
        let scratchWindow = defaults.integer(forKey: Key.scratchWindowSeconds)
        scratchWindowSeconds = scratchWindow > 0 ? scratchWindow : 60
        formatting =
            (defaults.data(forKey: Key.formatting)
                .flatMap { try? JSONDecoder().decode(SpokenFormatter.Options.self, from: $0) })
            ?? SpokenFormatter.Options()
    }
}
