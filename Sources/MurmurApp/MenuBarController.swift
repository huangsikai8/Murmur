import AppKit
import MurmurCore

/// Menu bar presence and the minimal controls the MVP needs.
@MainActor
final class MenuBarController {

    private let statusItem: NSStatusItem
    private let controller: DictationController
    private let hotkeyMonitor: HotkeyMonitor
    private let menu = NSMenu()

    private var statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private var cleanupItem = NSMenuItem()
    private var settingsController: SettingsWindowController?

    init(controller: DictationController, hotkeyMonitor: HotkeyMonitor) {
        self.controller = controller
        self.hotkeyMonitor = hotkeyMonitor
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        configureButton()
        buildMenu()

        controller.onStatusChange = { [weak self] status in
            self?.apply(status)
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "mic",
            accessibilityDescription: "Murmur dictation"
        )
        button.image?.isTemplate = true
        statusItem.menu = menu
    }

    private func buildMenu() {
        // Without this, AppKit enables every item that has a target/action and
        // ignores the explicit isEnabled below, making unfinished items look live.
        menu.autoenablesItems = false

        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

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
            statusMenuItem.title = "Ready — hold \(hotkeyMonitor.hotkey.displayName)"
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Ready")
        case .preparing:
            statusMenuItem.title = "Loading speech model…"
            button.image = NSImage(
                systemSymbolName: "arrow.down.circle",
                accessibilityDescription: "Loading"
            )
        case .listening:
            statusMenuItem.title = "Listening…"
            button.image = NSImage(
                systemSymbolName: "mic.fill",
                accessibilityDescription: "Listening"
            )
        case .finishing:
            statusMenuItem.title = "Transcribing…"
            button.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "Transcribing"
            )
        case .unavailable(let reason):
            statusMenuItem.title = "Unavailable: \(reason)"
            button.image = NSImage(
                systemSymbolName: "mic.slash",
                accessibilityDescription: "Unavailable"
            )
        }
        button.image?.isTemplate = true
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

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(preferences: Preferences.shared) {
                [weak self] in
                self?.applyPreferences()
            }
        }
        settingsController?.show()
    }

    /// Pushes saved choices into the live objects.
    func applyPreferences() {
        let preferences = Preferences.shared
        hotkeyMonitor.hotkey = preferences.hotkey
        controller.cleanupLevel = preferences.cleanupLevel
        controller.minimumHoldDuration = .milliseconds(preferences.minimumHoldMilliseconds)
        Task {
            await controller.applySpeechModel(preferences.activeSpeechModelID)
            await controller.applyCorrectionModel(preferences.activeCorrectionModelID)
            await controller.refreshVocabulary()
        }
        syncMenuState()
        apply(controller.status)
    }

    /// Reflects current values in the menu's checkmarks.
    private func syncMenuState() {
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
