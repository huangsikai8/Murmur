import Foundation
import MurmurCore

/// `Murmur --download <modelID>` — fetches a model's weights from the terminal,
/// which makes download failures visible without going through the settings UI.
enum ModelDownloadCommand {

    static func run(modelID: String) async -> Int32 {
        ModelCatalog.coreMLEngineWired = true
        ModelCatalog.mlxSupported = true
        ModelCatalog.moonshineEngineWired = true

        guard !modelID.isEmpty else {
            print("Usage: Murmur --download <modelID>\n\nDownloadable models:")
            for model in ModelCatalog.all where model.runtime != .appleBuiltIn {
                let mark = ModelCatalog.installedModelIDs().contains(model.id) ? "installed" : "  —  "
                print("  [\(mark)] \(model.id)")
                print("            \(model.name), \(model.sizeDescription)")
            }
            return 1
        }

        guard let descriptor = ModelCatalog.model(id: modelID) else {
            print("Unknown model: \(modelID)")
            return 1
        }

        print("Downloading \(descriptor.name) (\(descriptor.sizeDescription))…")
        print("This needs an internet connection; later runs work offline.\n")

        let start = ContinuousClock.now
        do {
            try await ModelCatalog.install(descriptor) { fraction in
                let percent = Int(fraction * 100)
                if percent % 10 == 0 { print("  \(percent)%") }
            }
        } catch {
            print("FAILED: \(error.localizedDescription)")
            return 1
        }

        let seconds = Double((ContinuousClock.now - start).components.seconds)
        let installed = ModelCatalog.installedModelIDs().contains(descriptor.id)
        print(String(format: "Done in %.0f s. Installed on disk: %@", seconds, installed ? "yes" : "NO"))
        return installed ? 0 : 1
    }
}
