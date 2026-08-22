import AppKit
import MurmurCore

/// Menu bar presence and the minimal controls the MVP needs.
@MainActor
final class MenuBarController {

    private let statusItem: NSStatusItem
    private let controller: DictationController
    private let hotkeyMonitor: HotkeyMonitor
    private let toggleMonitor = ToggleShortcutMonitor()
    private let menu = NSMenu()

    private var statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private var cleanupItem = NSMenuItem()
    private var handsFreeItem = NSMenuItem(
        title: "Turn On Hands-Free", action: nil, keyEquivalent: "")
    /// The microphone control, and beneath it what the *system* thinks.
    ///
    /// The two are separate on purpose. macOS keeps the orange indicator lit
    /// for several seconds after a process releases the microphone, so
    /// switching this off and watching the menu bar looks exactly like nothing
    /// having happened. The line underneath is read from CoreAudio when the
    /// menu opens, and answers the question the indicator cannot.
    private let microphoneItem = NSMenuItem(
        title: "Keep Microphone Open", action: nil, keyEquivalent: "")
    private let microphoneStateItem = NSMenuItem(
        title: "Microphone: …", action: nil, keyEquivalent: "")
    private var menuObserver: MenuOpenObserver?
    private var settingsController: SettingsWindowController?
    private var compareController: CompareWindowController?

    init(controller: DictationController, hotkeyMonitor: HotkeyMonitor) {
        self.controller = controller
        self.hotkeyMonitor = hotkeyMonitor
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        configureButton()
        buildMenu()

        toggleMonitor.onTrigger = { [weak self] in
            self?.toggleHandsFree()
        }
        toggleMonitor.start()

        controller.onStatusChange = { [weak self] status in
            self?.apply(status)
        }
        controller.onHandsFreeChange = { [weak self] _ in
            guard let self else { return }
            syncMenuState()
            apply(controller.status)
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = MenuBarGlyph.mark(accessibilityDescription: "Murmur dictation")
        statusItem.menu = menu
    }

    private func buildMenu() {
        // Without this, AppKit enables every item that has a target/action and
        // ignores the explicit isEnabled below, making unfinished items look live.
        menu.autoenablesItems = false

        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        handsFreeItem.target = self
        handsFreeItem.action = #selector(toggleHandsFree)
        menu.addItem(handsFreeItem)

        microphoneItem.target = self
        microphoneItem.action = #selector(toggleMicrophoneArmed)
        microphoneItem.isEnabled = true
        microphoneItem.toolTip =
            "Opening the microphone costs up to a third of a second, and that audio "
            + "is never recorded rather than merely delayed. Held open, a press costs "
            + "nothing. Nothing is transcribed or kept unless you dictate."
        menu.addItem(microphoneItem)

        microphoneStateItem.isEnabled = false
        menu.addItem(microphoneStateItem)
        menu.addItem(.separator())

        // Refreshed on open, because what the system reports changes without
        // anything in this process happening.
        let observer = MenuOpenObserver { [weak self] in self?.syncMicrophoneItem() }
        menu.delegate = observer
        menuObserver = observer

        let hotkeyMenu = NSMenu()
        for key in Hotkey.allCases {
            let item = NSMenuItem(
                title: key.displayName,
                action: #selector(selectHotkey(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = true
            item.representedObject = key.rawValue
            item.state = key == hotkeyMonitor.hotkey ? .on : .off
            hotkeyMenu.addItem(item)
        }
        hotkeyMenu.autoenablesItems = false
        let hotkeyItem = NSMenuItem(title: "Hold-to-Talk Key", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        hotkeyItem.isEnabled = true
        menu.addItem(hotkeyItem)

        let cleanupMenu = NSMenu()
        cleanupMenu.autoenablesItems = false
        let cleanupAvailable = FoundationModelsCleaner.isSupported
        for level in CleanupLevel.allCases {
            let item = NSMenuItem(
                title: level.displayName,
                action: #selector(selectCleanupLevel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = level.rawValue
            item.state = level == controller.cleanupLevel ? .on : .off
            item.toolTip = level.summary
            // Only "Off" stays usable when Apple Intelligence is unavailable.
            item.isEnabled = cleanupAvailable || level == .off
            cleanupMenu.addItem(item)
        }
        cleanupItem = NSMenuItem(title: "AI Cleanup", action: nil, keyEquivalent: "")
        cleanupItem.submenu = cleanupMenu
        cleanupItem.isEnabled = true
        if let reason = FoundationModelsCleaner.unavailableReason {
            cleanupItem.toolTip = reason
        }
        menu.addItem(cleanupItem)

        menu.addItem(.separator())

        let engineItem = NSMenuItem(
            title: "Engine: \(AppleSpeechEngine.engineName)",
            action: nil,
            keyEquivalent: ""
        )
        engineItem.isEnabled = false
        menu.addItem(engineItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.isEnabled = true
        menu.addItem(settingsItem)

        let compareItem = NSMenuItem(
            title: "Compare Models…",
            action: #selector(openCompare),
            keyEquivalent: ""
        )
        compareItem.target = self
        compareItem.isEnabled = true
        menu.addItem(compareItem)

        let permissionsItem = NSMenuItem(
            title: "Open Permission Settings…",
            action: #selector(openPermissions),
            keyEquivalent: ""
        )
        permissionsItem.target = self
        permissionsItem.isEnabled = true
        menu.addItem(permissionsItem)

        let unloadItem = NSMenuItem(
            title: "Unload Models (free RAM)",
            action: #selector(unloadModels),
            keyEquivalent: ""
        )
        unloadItem.target = self
        unloadItem.isEnabled = true
        menu.addItem(unloadItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Murmur", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)
    }

    private func apply(_ status: DictationController.Status) {
        guard let button = statusItem.button else { return }
        switch status {
        case .idle:
            if controller.isHandsFree {
                // A live microphone must never be something you have to
                // remember. The icon is filled and the menu says so.
                statusMenuItem.title = "Hands-free — listening continuously"
                button.image = MenuBarGlyph.mark(
                    active: true, accessibilityDescription: "Hands-free dictation on"
                )
                return
            }
            statusMenuItem.title = "Ready — hold \(hotkeyMonitor.hotkey.displayName)"
            button.image = MenuBarGlyph.mark(accessibilityDescription: "Ready")
        case .preparing:
            statusMenuItem.title = "Loading speech model…"
            button.image = MenuBarGlyph.mark(accessibilityDescription: "Loading")
        case .listening:
            statusMenuItem.title = "Listening…"
            button.image = MenuBarGlyph.mark(
                active: true, accessibilityDescription: "Listening"
            )
        case .finishing:
            statusMenuItem.title = "Transcribing…"
            button.image = MenuBarGlyph.mark(accessibilityDescription: "Transcribing")
        case .unavailable(let reason):
            statusMenuItem.title = "Unavailable: \(reason)"
            button.image = MenuBarGlyph.mark(
                slashed: true, accessibilityDescription: "Unavailable"
            )
        }
    }

    // MARK: - Actions

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let key = Hotkey(rawValue: raw) else { return }
        hotkeyMonitor.hotkey = key
        Preferences.shared.hotkey = key
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == raw ? .on : .off
        }
        apply(controller.status)
    }

    @objc private func selectCleanupLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let level = CleanupLevel(rawValue: raw) else { return }
        controller.cleanupLevel = level
        Preferences.shared.cleanupLevel = level
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == raw ? .on : .off
        }
    }

    /// Switching hands-free on loads a detector and an engine, which takes
    /// seconds. A press arriving inside that window would otherwise queue up
    /// and undo the switch the moment it finished.
    private var isTogglingHandsFree = false

    @objc func toggleHandsFree() {
        guard !isTogglingHandsFree else { return }
        isTogglingHandsFree = true
        Task {
            defer { isTogglingHandsFree = false }
            if controller.isHandsFree {
                await controller.stopHandsFree()
            } else {
                await controller.startHandsFree()
            }
            Preferences.shared.handsFreeEnabled = controller.isHandsFree
        }
    }

    @objc private func toggleMicrophoneArmed() {
        Preferences.shared.keepMicrophoneArmed.toggle()
        applyPreferences()
        syncMicrophoneItem()
        Log.write(
            "keep microphone open set to \(Preferences.shared.keepMicrophoneArmed) from the menu")
    }

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(preferences: Preferences.shared) {
                [weak self] in
                self?.applyPreferences()
            }
        }
        settingsController?.show()
    }

    @objc private func openCompare() {
        if compareController == nil {
            compareController = CompareWindowController { [weak self] in
                guard let self else { return }
                // Hands-free would be holding the input device, and the app's
                // own engine would be holding memory the comparison is about to
                // need for a different model.
                await controller.stopHandsFree()
                await controller.releaseModels()
            }
        }
        compareController?.show()
    }

    /// Pushes saved choices into the live objects.
    func applyPreferences() {
        let preferences = Preferences.shared
        hotkeyMonitor.hotkey = preferences.hotkey
        hotkeyMonitor.mode = preferences.hotkeyMode
        controller.cleanupLevel = preferences.cleanupLevel
        controller.minimumHoldDuration = .milliseconds(preferences.minimumHoldMilliseconds)
        controller.handsFreeIdleTimeout = .seconds(preferences.handsFreeIdleMinutes * 60)
        toggleMonitor.shortcut = preferences.handsFreeToggleShortcut
        controller.formatting = preferences.formatting
        controller.handsFreeUsesTurnDetector = preferences.usesTurnDetector
        controller.turnDetectorThreshold = Float(preferences.turnDetectorThreshold)
        controller.turnDetectorSilence = Double(preferences.turnSilenceMilliseconds) / 1000
        controller.scratchEnabled = preferences.scratchEnabled
        controller.meterStyle = preferences.meterStyle
        controller.keepMicrophoneArmed = preferences.keepMicrophoneArmed
        controller.microphoneIdleTimeout = .seconds(preferences.microphoneIdleMinutes * 60)
        // Setting the preference above only reacts to a *change*, so a
        // device closed by something else stays closed. This is what
        // notices.
        controller.rearmMicrophoneIfNeeded()
        controller.scratchWindow = .seconds(preferences.scratchWindowSeconds)
        Task {
            await controller.applySpeechModel(preferences.activeSpeechModelID)
            await controller.applyCorrectionModel(preferences.activeCorrectionModelID)
            await controller.setHandsFreeSilence(
                milliseconds: preferences.handsFreeSilenceMilliseconds)
            await controller.refreshVocabulary()
            // Continuous dictation is restored last, once the engine it needs
            // is the one the user actually chose.
            if preferences.handsFreeEnabled, !controller.isHandsFree {
                await controller.startHandsFree()
            } else if !preferences.handsFreeEnabled, controller.isHandsFree {
                await controller.stopHandsFree()
            }
        }
        syncMenuState()
        apply(controller.status)
    }

    /// Whether the preference is on, and separately whether the microphone is
    /// actually open — which is what the user is really asking.
    private func syncMicrophoneItem() {
        microphoneItem.state = Preferences.shared.keepMicrophoneArmed ? .on : .off
        // Opening the menu is also the cheapest moment to notice that the
        // device is shut while the preference says otherwise, which is what a
        // configuration change leaves behind.
        controller.rearmMicrophoneIfNeeded()
        switch AudioCapture.systemReportsInputRunning {
        case true:
            microphoneStateItem.title = "Microphone: open"
        case false:
            // Says *why*, because "closed" with the switch ticked reads as a
            // bug even when it is the timeout doing exactly its job.
            microphoneStateItem.title =
                controller.microphoneClosedWhileIdle
                ? "Microphone: closed (idle)" : "Microphone: closed"
        default:
            microphoneStateItem.title = "Microphone: unknown"
        }
    }

    /// Reflects current values in the menu's checkmarks.
    private func syncMenuState() {
        syncMicrophoneItem()
        handsFreeItem.title =
            controller.isHandsFree ? "Turn Off Hands-Free" : "Turn On Hands-Free"
        handsFreeItem.state = controller.isHandsFree ? .on : .off
        for item in cleanupItem.submenu?.items ?? [] {
            item.state =
                (item.representedObject as? String) == controller.cleanupLevel.rawValue
                ? .on : .off
        }
        for item in menu.items.first(where: { $0.title == "Hold-to-Talk Key" })?.submenu?.items
            ?? []
        {
            item.state =
                (item.representedObject as? String) == hotkeyMonitor.hotkey.rawValue ? .on : .off
        }
    }

    @objc private func openPermissions() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }

    @objc private func unloadModels() {
        Task { await controller.releaseModels() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// `NSMenuDelegate` is an `@objc` protocol and `MenuBarController` is a plain
/// Swift class, so the one callback needed comes through this.
private final class MenuOpenObserver: NSObject, NSMenuDelegate {
    private let onOpen: @MainActor () -> Void

    init(onOpen: @escaping @MainActor () -> Void) {
        self.onOpen = onOpen
    }

    func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated { onOpen() }
    }
}
