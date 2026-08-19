import AppKit
import MurmurCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = DictationController()
    private let hotkeyMonitor = HotkeyMonitor(hotkey: Preferences.shared.hotkey)
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.startSession()
        Log.write("applicationDidFinishLaunching")
        menuBar = MenuBarController(controller: controller, hotkeyMonitor: hotkeyMonitor)
        // Restore saved choices before the first dictation can happen.
        menuBar?.applyPreferences()
        Log.write("status item created")

        hotkeyMonitor.onPress = { [weak controller] in controller?.begin() }
        hotkeyMonitor.onRelease = { [weak controller] in controller?.end() }

        Task { await bootstrap() }
    }

    private func bootstrap() async {
        Log.write("bootstrap started")
        // Core ML streaming engines are compiled in, so their models may be offered.
        ModelCatalog.coreMLEngineWired = true
        // MLX is compiled in, so the downloadable language models may be offered.
        ModelCatalog.mlxSupported = true
        ModelCatalog.moonshineEngineWired = true
        // Microphone: required to capture speech. Requested up front so the
        // first dictation is not interrupted by a permission sheet.
        Log.write("requesting microphone access")
        let micGranted = await AudioCapture.requestPermission()
        Log.write("microphone granted=\(micGranted)")
        if !micGranted {
            presentPermissionAlert(
                title: "Microphone access needed",
                message: """
                    Murmur captures audio only while you hold the dictation key. \
                    Grant access in System Settings › Privacy & Security › Microphone.
                    """
            )
        }

        // Accessibility: required to observe the hotkey while another app is
        // frontmost, and to post the paste keystroke into that app. Input
        // Monitoring is deliberately not requested — NSEvent monitors do not
        // need it.
        Log.write("accessibility trusted=\(FocusTracker.isAccessibilityTrusted)")
        if !FocusTracker.isAccessibilityTrusted {
            FocusTracker.requestAccessibility()
        }

        hotkeyMonitor.start()
        Log.write("hotkey monitor started")
        await controller.warmUp()
        Log.write("warmUp finished, status=\(controller.status)")
    }

    private func presentPermissionAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )!
            NSWorkspace.shared.open(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor.stop()
    }
}
