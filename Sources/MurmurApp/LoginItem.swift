import AppKit
import Foundation
import ServiceManagement

/// Whether macOS opens Murmur at login.
///
/// Deliberately not a `Preferences` key: the registration lives in
/// LaunchServices, and System Settings › General › Login Items can switch it
/// off without telling the app. A stored bool would then tick a switch over a
/// registration that no longer exists — the same failure as the microphone
/// switch staying ticked over a shut device. `SMAppService` is the only store,
/// and this object is a cache of what it says, refreshed whenever the settings
/// window is shown.
@MainActor
final class LoginItem: ObservableObject {

    /// What LaunchServices currently reports. `.requiresApproval` is the
    /// interesting one: the app is registered, and the user has switched it
    /// off in System Settings, so registering again changes nothing.
    @Published private(set) var status: SMAppService.Status

    /// The last registration failure, cleared by the next successful change.
    /// Surfaced in the settings window, because the alternative is a switch
    /// that springs back with no explanation.
    @Published private(set) var failure: String?

    private let service = SMAppService.mainApp

    init() {
        status = SMAppService.mainApp.status
    }

    var isEnabled: Bool { status == .enabled }

    func refresh() {
        status = service.status
    }

    /// Registers or unregisters, then re-reads rather than assuming it worked.
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                // Registering an already-registered app throws, and the state
                // this is called from may be stale by a few seconds.
                if service.status != .enabled { try service.register() }
            } else {
                try service.unregister()
            }
            failure = nil
            Log.write("launch at login set to \(enabled)")
        } catch {
            failure = error.localizedDescription
            Log.write("launch at login \(enabled ? "register" : "unregister") failed: \(error)")
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The registration names this exact bundle path, so a copy run from the
    /// build directory registers the build directory — and moving or deleting
    /// it leaves a login item that opens nothing.
    var isInApplicationsFolder: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    /// Only `.requiresApproval` is worth saying out loud.
    ///
    /// `.notFound` reads like a broken bundle and is not: measured, a copy that
    /// has never been registered reports `.notFound`, registers successfully,
    /// and reports `.notRegistered` after being unregistered again. Explaining
    /// it would put a warning about moving the app in front of every new user,
    /// for a switch that works.
    var explanation: String? {
        guard status == .requiresApproval else { return nil }
        return "Murmur is registered but switched off in System Settings › "
            + "General › Login Items. It has to be turned on there."
    }
}
