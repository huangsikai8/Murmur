import Foundation
import Speech

/// One installable speech-recognition language.
public struct SpeechLocaleInfo: Identifiable, Sendable, Equatable {
    public let locale: Locale
    public let isInstalled: Bool

    public var id: String { locale.identifier }

    public var displayName: String {
        Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }
}

/// Browsing and installing the languages Apple's on-device recognizer supports.
///
/// The models are managed by macOS, so this reports and requests rather than
/// storing anything itself.
public enum SpeechModelCatalog {

    /// Every supported language, marked with whether it is installed.
    public static func locales() async -> [SpeechLocaleInfo] {
        let supported = await SpeechTranscriber.supportedLocales
        let installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
        return supported
            .map { SpeechLocaleInfo(locale: $0, isInstalled: installed.contains($0.identifier)) }
            .sorted { $0.displayName < $1.displayName }
    }

    /// Downloads and installs one language's model.
    public static func install(
        _ locale: Locale,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
        else {
            progress?(1.0)
            return
        }

        let reporter = request.progress
        let observation = Task {
            while !Task.isCancelled && !reporter.isFinished {
                progress?(reporter.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { observation.cancel() }

        try await request.downloadAndInstall()
        progress?(1.0)
    }

    /// Languages currently held for offline use, and the system's cap.
    public static var reservedLocales: [Locale] {
        get async { await AssetInventory.reservedLocales }
    }

    public static var maximumReservedLocales: Int {
        AssetInventory.maximumReservedLocales
    }

    /// Gives up a reservation. macOS reclaims the storage when it needs to;
    /// applications cannot delete the asset directly.
    @discardableResult
    public static func release(_ locale: Locale) async -> Bool {
        await AssetInventory.release(reservedLocale: locale)
    }
}
