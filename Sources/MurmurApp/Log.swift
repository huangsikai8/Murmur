import Foundation

/// Appends to `~/Library/Logs/Murmur.log`.
///
/// A menu bar accessory has no console, and NSLog from a bundled app is awkward
/// to retrieve, so startup and failure detail goes to a file you can tail.
enum Log {

    static let fileURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Murmur.log")

    private static let queue = DispatchQueue(label: "com.sikaihuang.murmur.log")

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        NSLog("[murmur] %@", message)
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Starts a fresh file each launch so the log reflects the current run.
    static func startSession() {
        try? FileManager.default.removeItem(at: fileURL)
        write("=== Murmur \(Bundle.main.bundleIdentifier ?? "?") starting ===")
    }
}
