import AppKit
import MurmurCore
import SwiftUI

/// The one key capture in the process.
///
/// Shared rather than one per field, because a local event monitor is not
/// exclusive: two fields left recording at once would both see the same key
/// press and both claim it. Starting a recording therefore cancels whatever was
/// recording before.
@MainActor
final class ShortcutRecorder: ObservableObject {

    static let shared = ShortcutRecorder()

    /// What a recording produced.
    enum Result {
        case chord(KeyChord)
        /// Delete pressed on its own: unbind the shortcut.
        case cleared
        /// Escape, or another field taking over.
        case cancelled
    }

    /// The field currently listening, if any.
    @Published private(set) var recording: UUID?

    private var monitor: Any?
    private var finish: ((Result) -> Void)?

    private init() {}

    func start(_ field: UUID, onResult: @escaping (Result) -> Void) {
        cancel()
        recording = field
        finish = onResult

        // A local monitor, not a global one: this is the settings window, it is
        // key, and the press must be swallowed rather than also reaching
        // whatever the chord already means in this app.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let bare = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.function, .numericPad, .capsLock])
                .isEmpty

            if bare, event.keyCode == 53 { self.complete(.cancelled); return nil }
            if bare, event.keyCode == 51 { self.complete(.cleared); return nil }
            guard let chord = KeyChord(event: event) else {
                // Not a chord Murmur will register — a bare letter, or Shift
                // and a letter, which is that letter. Swallowed and ignored, so
                // the field goes on waiting rather than binding something that
                // would claim a key everywhere.
                return nil
            }
            self.complete(.chord(chord))
            return nil
        }
    }

    func cancel() {
        guard recording != nil else { return }
        complete(.cancelled)
    }

    private func complete(_ result: Result) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        let finish = self.finish
        self.finish = nil
        finish?(result)
    }
}

/// A row that shows a shortcut and records a new one when clicked.
struct ShortcutField: View {

    let title: String
    @Binding var chord: KeyChord?
    /// Pushes the new binding into the running app, the way every other
    /// setting here does.
    let onChange: () -> Void

    @StateObject private var recorder = ShortcutRecorder.shared
    @State private var id = UUID()

    private var isRecording: Bool { recorder.recording == id }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            Button(action: record) {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isRecording ? Color.accentColor : .primary)
                    .frame(minWidth: 96)
            }
            .help("Click, then press the keys you want to use")

            Button {
                ShortcutRecorder.shared.cancel()
                chord = nil
                onChange()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(chord == nil ? 0 : 1)
            .disabled(chord == nil)
            .help("Remove this shortcut")
        }
    }

    private var label: String {
        if isRecording { return "Press keys…" }
        return chord?.displayName ?? "Click to set"
    }

    private func record() {
        if isRecording {
            ShortcutRecorder.shared.cancel()
            return
        }
        ShortcutRecorder.shared.start(id) { result in
            switch result {
            case .chord(let recorded):
                chord = recorded
                onChange()
            case .cleared:
                chord = nil
                onChange()
            case .cancelled:
                break
            }
        }
    }
}
