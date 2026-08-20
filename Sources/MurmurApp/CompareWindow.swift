import AppKit
import MurmurCore
import SwiftUI

/// The multi-model comparison window: speak once, and every bubble shows what
/// its own combination of models made of it.
///
/// Deliberately not persisted. This is a bench for answering "which models
/// should I be using", not a mode to leave running — the bubbles are gone when
/// the window closes, and every model they loaded is released with them.
@MainActor
final class CompareWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let model = CompareViewModel()

    /// Called before the microphone opens. The app's own dictation has to stand
    /// down first: hands-free would be holding the input device, and its engine
    /// would be holding memory the comparison is about to need.
    init(prepareToRecord: @escaping @MainActor () async -> Void) {
        super.init()
        model.prepareToRecord = prepareToRecord
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: CompareView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Compare Models"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 820, height: 620))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the window is the teardown. Leaving several gigabytes of speech
    /// and cleanup weights resident after a comparison is exactly the failure
    /// this window is supposed to make unnecessary.
    func windowWillClose(_ notification: Notification) {
        model.teardown()
    }
}

// MARK: - State

@MainActor
final class CompareViewModel: ObservableObject {

    struct BubbleState: Identifiable {
        var config: ModelComparison.BubbleConfig
        var raw: String?
        var cleaned: String?
        var timing: String?
        var failure: String?

        var id: UUID { config.id }
        /// What this bubble would have inserted.
        var text: String? { cleaned ?? raw }
    }

    @Published var bubbles: [BubbleState] = []
    @Published private(set) var isRecording = false
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var recordedSeconds: TimeInterval = 0
    /// Contested-word marking for the current results, keyed by bubble ID.
    @Published private(set) var rows: [UUID: TranscriptDiff.Row] = [:]
    @Published private(set) var disagreements: Int?

    var prepareToRecord: (@MainActor () async -> Void)?

    private var recording: ModelComparison.Recording?
    private let capture = AudioCapture()
    private var buffer = ModelComparison.RecordingBuffer()
    private var runTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?

    /// True once there is audio to replay, which is what lets a bubble be added
    /// and compared without speaking again.
    var hasRecording: Bool { !(recording?.isEmpty ?? true) }

    init() {
        bubbles = Self.defaultBubbles().map { BubbleState(config: $0) }
    }

    // MARK: Bubbles

    /// Starts from what is already installed, so the window is useful before
    /// anything is configured.
    ///
    /// One model per distinct engine, Apple's first. Taking the catalog's first
    /// three instead opens on the three Nemotron latency tiers — the same model
    /// three times, which is the least informative comparison available.
    private static func defaultBubbles() -> [ModelComparison.BubbleConfig] {
        var seen: Set<String> = []
        var chosen: [AIModelDescriptor] = []
        let ordered = speechChoices.sorted { left, _ in left.id == ModelCatalog.appleSpeechID }
        for descriptor in ordered {
            guard let engine = SpeechEngineFactory.engine(for: descriptor.id) else { continue }
            let family = String(describing: type(of: engine))
            guard seen.insert(family).inserted else { continue }
            chosen.append(descriptor)
        }
        // Two is the smallest number that can disagree, and disagreement is the
        // only thing this window reports.
        return chosen.prefix(3).map { ModelComparison.BubbleConfig(speechModelID: $0.id) }
    }

    static var speechChoices: [AIModelDescriptor] {
        let installed = ModelCatalog.installedModelIDs()
        return ModelCatalog.models(in: .speechRecognition)
            .filter { $0.id == ModelCatalog.appleSpeechID || installed.contains($0.id) }
    }

    static var cleanupChoices: [AIModelDescriptor] {
        let installed = ModelCatalog.installedModelIDs()
        return ModelCatalog.models(in: .correction)
            .filter { $0.id == ModelCatalog.appleCorrectionID || installed.contains($0.id) }
    }

    func addBubble() {
        guard let first = Self.speechChoices.first else { return }
        let template = bubbles.last?.config
        bubbles.append(
            BubbleState(
                config: ModelComparison.BubbleConfig(
                    speechModelID: template?.speechModelID ?? first.id,
                    cleanupModelID: template?.cleanupModelID,
                    cleanupLevel: template?.cleanupLevel ?? .off)))
    }

    func remove(_ id: UUID) {
        bubbles.removeAll { $0.id == id }
        recompute()
    }

    /// Reconfigures one bubble, discarding the result it no longer explains.
    func update(
        _ id: UUID, speechModelID: String? = nil,
        cleanupModelID: String?? = nil, cleanupLevel: CleanupLevel? = nil
    ) {
        guard let index = bubbles.firstIndex(where: { $0.id == id }) else { return }
        let old = bubbles[index].config
        bubbles[index].config = ModelComparison.BubbleConfig(
            id: old.id,
            speechModelID: speechModelID ?? old.speechModelID,
            cleanupModelID: cleanupModelID ?? old.cleanupModelID,
            cleanupLevel: cleanupLevel ?? old.cleanupLevel)
        bubbles[index].raw = nil
        bubbles[index].cleaned = nil
        bubbles[index].timing = nil
        bubbles[index].failure = nil
        recompute()
    }

    // MARK: Recording

    func startRecording() async {
        guard !isRecording, !isRunning else { return }
        await prepareToRecord?()

        guard await AudioCapture.requestPermission() else {
            status = "Microphone access was denied."
            return
        }

        buffer = ModelComparison.RecordingBuffer()
        capture.prearm(targetFormat: ModelComparison.Recording.format)
        do {
            try capture.start { [buffer] in buffer.append($0) }
        } catch {
            status = error.localizedDescription
            return
        }

        isRecording = true
        status = "Recording — speak, then press Stop."
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                level = capture.currentLevel
                recordedSeconds = buffer.duration
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func stopRecordingAndRun() {
        guard isRecording else { return }
        capture.stop()
        meterTask?.cancel()
        meterTask = nil
        isRecording = false
        level = 0

        let captured = buffer.recording()
        recordedSeconds = captured.duration
        guard !captured.isEmpty else {
            status = "No audio was captured."
            return
        }
        recording = captured
        run()
    }

    // MARK: Running

    func run() {
        guard let recording, !isRunning else { return }
        runTask?.cancel()

        for index in bubbles.indices {
            bubbles[index].raw = nil
            bubbles[index].cleaned = nil
            bubbles[index].timing = nil
            bubbles[index].failure = nil
        }
        rows = [:]
        disagreements = nil
        isRunning = true

        let configs = bubbles.map(\.config)
        runTask = Task { [weak self] in
            for await event in ModelComparison.run(recording, bubbles: configs) {
                guard let self else { return }
                apply(event)
            }
            guard let self else { return }
            isRunning = false
            status = hasRecording ? "Done. The recording is kept — change a bubble and run again." : ""
            recompute()
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        status = "Stopped."
    }

    private func apply(_ event: ModelComparison.Event) {
        switch event {
        case .loading(let modelID):
            status = "Loading \(ModelCatalog.model(id: modelID)?.name ?? modelID)…"

        case .transcribed(let id, let text, let firstPartialMs, let decodeMs):
            guard let index = bubbles.firstIndex(where: { $0.id == id }) else { return }
            bubbles[index].raw = text
            let partial =
                firstPartialMs < 0
                ? "no live text (decodes on release)"
                : "first text \(firstPartialMs) ms"
            bubbles[index].timing = "\(partial) · finalize \(decodeMs) ms"
            recompute()

        case .cleaned(let id, let text, let elapsedMs):
            guard let index = bubbles.firstIndex(where: { $0.id == id }) else { return }
            bubbles[index].cleaned = text
            bubbles[index].timing = (bubbles[index].timing ?? "") + " · cleanup \(elapsedMs) ms"
            recompute()

        case .failed(let id, let message):
            guard let index = bubbles.firstIndex(where: { $0.id == id }) else { return }
            bubbles[index].failure = message
        }
    }

    /// Re-aligns whatever results exist so far, so contested words appear as
    /// bubbles fill in rather than only at the end.
    private func recompute() {
        // Keyed by ID, not by display name: two bubbles can legitimately carry
        // the same label, and matching rows back by name would give them each
        // other's text.
        let entries = bubbles.compactMap { bubble in
            bubble.text.map { TranscriptDiff.Entry(label: bubble.id.uuidString, text: $0) }
        }
        guard entries.count > 1 else {
            rows = [:]
            disagreements = nil
            return
        }
        let comparison = TranscriptDiff.compare(entries)
        var mapped: [UUID: TranscriptDiff.Row] = [:]
        for row in comparison.rows {
            if let id = UUID(uuidString: row.label) { mapped[id] = row }
        }
        rows = mapped
        disagreements = comparison.disagreements
    }

    // MARK: Teardown

    func teardown() {
        capture.stop()
        meterTask?.cancel()
        meterTask = nil
        runTask?.cancel()
        runTask = nil
        isRecording = false
        isRunning = false
        recording = nil
        level = 0
    }
}

// MARK: - View

private struct CompareView: View {
    @ObservedObject var model: CompareViewModel

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.bubbles) { bubble in
                        BubbleCard(model: model, bubble: bubble)
                    }
                    Button {
                        model.addBubble()
                    } label: {
                        Label("Add bubble", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isRunning || model.isRecording)
                }
                .padding()
            }
            Divider()
            footer
        }
        .frame(minWidth: 700, minHeight: 480)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if model.isRecording {
                Button("Stop") { model.stopRecordingAndRun() }
                    .keyboardShortcut(.defaultAction)
                meter
                Text(String(format: "%.1f s", model.recordedSeconds))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Button("Record") { Task { await model.startRecording() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isRunning)
                // The payoff of replaying held audio rather than running every
                // model live: a bubble can be added or reconfigured and
                // compared against the same speech, with nothing said twice.
                Button("Run again") { model.run() }
                    .disabled(!model.hasRecording || model.isRunning)
                if model.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }
                }
            }
            Spacer()
            Text(model.status).font(.callout).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var meter: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.tint)
                    .frame(width: proxy.size.width * CGFloat(model.level))
            }
        }
        .frame(width: 90, height: 6)
    }

    private var footer: some View {
        HStack {
            if let disagreements = model.disagreements {
                if disagreements == 0 {
                    Label(
                        "Every bubble agreed word for word.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        "\(disagreements) contested word(s), highlighted. "
                            + "There is no right answer here — read them and decide "
                            + "which model heard you.",
                        systemImage: "exclamationmark.bubble")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Nothing is ever inserted from this window.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
        .padding(12)
    }
}

// MARK: - One bubble

private struct BubbleCard: View {
    @ObservedObject var model: CompareViewModel
    let bubble: CompareViewModel.BubbleState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            pickers
            content
            if let timing = bubble.timing {
                Text(timing).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var pickers: some View {
        HStack(spacing: 8) {
            Picker(
                "",
                selection: Binding(
                    get: { bubble.config.speechModelID },
                    set: { model.update(bubble.id, speechModelID: $0) })
            ) {
                ForEach(CompareViewModel.speechChoices) { descriptor in
                    Text(descriptor.name).tag(descriptor.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)

            Picker(
                "",
                selection: Binding<String>(
                    get: { bubble.config.cleanupModelID ?? "" },
                    set: { model.update(bubble.id, cleanupModelID: $0.isEmpty ? .some(nil) : $0) })
            ) {
                Text("No cleanup").tag("")
                ForEach(CompareViewModel.cleanupChoices) { descriptor in
                    Text(descriptor.name).tag(descriptor.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)

            if bubble.config.cleanupModelID != nil {
                Picker(
                    "",
                    selection: Binding(
                        get: { bubble.config.cleanupLevel },
                        set: { model.update(bubble.id, cleanupLevel: $0) })
                ) {
                    ForEach(CleanupLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 110)
            }

            Spacer()

            Button {
                model.remove(bubble.id)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
        }
        .disabled(model.isRunning || model.isRecording)
    }

    @ViewBuilder
    private var content: some View {
        if let failure = bubble.failure {
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        } else if let row = model.rows[bubble.id] {
            Text(highlighted(row)).font(.body).textSelection(.enabled)
        } else if let text = bubble.text {
            Text(text).font(.body).textSelection(.enabled)
        } else if model.isRunning {
            Text("waiting…").font(.callout).foregroundStyle(.tertiary)
        } else {
            Text("No result yet.").font(.callout).foregroundStyle(.tertiary)
        }
    }

    /// Contested words stand out; everything the models agreed on stays plain,
    /// so the eye lands only on what is actually in question.
    private func highlighted(_ row: TranscriptDiff.Row) -> AttributedString {
        var result = AttributedString()
        for (index, token) in row.tokens.enumerated() {
            if index > 0 { result += AttributedString(" ") }
            var piece = AttributedString(token.text)
            if !token.agrees {
                piece.foregroundColor = .orange
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            result += piece
        }
        return result
    }
}
