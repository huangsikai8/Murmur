import AVFoundation
import AppKit
import Foundation
import FoundationModels
import MurmurCore
import Speech

/// `Murmur --diagnose` — prints environment readiness and exits.
enum Diagnostics {

    static func run() async {
        print("Murmur diagnostics\n")

        print("System")
        print("  macOS:              \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("  Engine:             \(AppleSpeechEngine.engineName)")
        print("  Transcriber usable: \(mark(SpeechTranscriber.isAvailable))")

        print("\nPermissions")
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        print("  Microphone:         \(mark(micStatus == .authorized)) \(describe(micStatus))")
        print("  Accessibility:      \(mark(AXIsProcessTrusted()))")
        print("     needed to see the hotkey while another app is frontmost,")
        print("     and to post the paste keystroke into that app.")

        print("\nStartup")
        for line in await loginItemLines() { print(line) }

        print("\nSpeech model")
        let locale = Locale.current
        print("  Locale:             \(locale.identifier)")

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let installed = await SpeechTranscriber.installedLocales
        let supported = await SpeechTranscriber.supportedLocales
        let isSupported = supported.contains { $0.identifier == locale.identifier }
        let isInstalled = installed.contains { $0.identifier == locale.identifier }

        print("  Supported locales:  \(supported.count)")
        print("  Locale supported:   \(mark(isSupported))")
        print("  Model installed:    \(mark(isInstalled))")

        let status = await AssetInventory.status(forModules: [transcriber])
        print("  Asset status:       \(describe(status))")
        if status != .installed {
            print("     Murmur downloads this automatically on first launch.")
        }

        if let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        {
            print("  Analyzer format:    \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
        }

        // The engine must outlive the inputNode access, and the input node is
        // only meaningful once microphone access has been granted.
        if micStatus == .authorized {
            let audioEngine = AVAudioEngine()
            let hardware = audioEngine.inputNode.outputFormat(forBus: 0)
            print(
                "  Microphone format:  \(Int(hardware.sampleRate)) Hz, "
                    + "\(hardware.channelCount) ch"
            )
        } else {
            print("  Microphone format:  unavailable until access is granted")
        }

        print("\nCleanup model (Apple Foundation Models)")
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            print("  Availability:       yes — on-device, already installed")
            print("  Languages:          \(model.supportedLanguages.count)")
        case .unavailable(let reason):
            print("  Availability:       NO \(describe(reason))")
        }

        print("")
    }

    private static func describe(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible: "(this Mac is not eligible)"
        case .appleIntelligenceNotEnabled:
            "(turn on Apple Intelligence in System Settings)"
        case .modelNotReady: "(model still downloading)"
        @unknown default: "(unknown reason)"
        }
    }

    /// Reported rather than stored: LaunchServices owns this setting, and
    /// System Settings can switch it off without telling the app.
    @MainActor
    private static func loginItemLines() -> [String] {
        let item = LoginItem()
        let detail: String
        switch item.status {
        case .enabled: detail = "registered and enabled"
        case .notRegistered: detail = "not registered"
        case .requiresApproval: detail = "registered, switched off in System Settings"
        case .notFound: detail = "macOS cannot find this bundle"
        @unknown default: detail = "unknown"
        }
        var lines = [
            "  Open at login:      \(mark(item.isEnabled)) \(detail)",
            "  Bundle:             \(Bundle.main.bundleURL.path)",
        ]
        if !item.isInApplicationsFolder {
            lines.append("     a login item names this exact path, so a copy run from a")
            lines.append("     build directory registers the build directory.")
        }
        return lines
    }

    private static func mark(_ value: Bool) -> String {
        value ? "yes" : "NO"
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "(granted)"
        case .denied: "(denied — enable in System Settings)"
        case .restricted: "(restricted)"
        case .notDetermined: "(not yet requested)"
        @unknown default: "(unknown)"
        }
    }

    private static func describe(_ status: AssetInventory.Status) -> String {
        switch status {
        case .installed: "installed"
        case .downloading: "downloading"
        case .supported: "supported, not yet downloaded"
        case .unsupported: "unsupported for this locale"
        @unknown default: "unknown"
        }
    }
}
