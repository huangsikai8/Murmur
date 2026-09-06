import AppKit
import MurmurCore
import SwiftUI

/// Which tab the window opens on.
enum SettingsTab: Hashable {
    case general, cleanup, words, models, history
}

/// The tab the window is showing.
///
/// Held outside the view because the window is built once and kept
/// (`isReleasedWhenClosed = false`), so opening it a second time cannot pass a
/// new value in through the initializer — a `@State` would keep whichever tab
/// the speaker last clicked and the history shortcut would open on that.
@MainActor
final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// The settings window, opened from the menu bar.
@MainActor
final class SettingsWindowController {

    private var window: NSWindow?
    private let preferences: Preferences
    private let onChange: () -> Void
    private let loginItem = LoginItem()
    private let selection = SettingsSelection()

    init(preferences: Preferences, onChange: @escaping () -> Void) {
        self.preferences = preferences
        self.onChange = onChange
    }

    func show(tab: SettingsTab? = nil) {
        // Login Items can be switched off in System Settings without telling
        // the app, and the window below is built once and kept, so `.onAppear`
        // fires only the first time a tab is shown. Re-read on every open.
        loginItem.refresh()
        if let tab { selection.tab = tab }

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(
            preferences: preferences, loginItem: loginItem, selection: selection,
            onChange: onChange)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Murmur Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 620, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        // Settings is the one place Murmur legitimately takes focus.
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var loginItem: LoginItem
    @ObservedObject var selection: SettingsSelection
    let onChange: () -> Void

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralSettings(preferences: preferences, loginItem: loginItem, onChange: onChange)
                .tabItem { Label("General", systemImage: "keyboard") }
                .tag(SettingsTab.general)
            CleanupSettings(preferences: preferences, onChange: onChange)
                .tabItem { Label("Cleanup", systemImage: "wand.and.stars") }
                .tag(SettingsTab.cleanup)
            VocabularySettings(onChange: onChange)
                .tabItem { Label("Words", systemImage: "character.book.closed") }
                .tag(SettingsTab.words)
            ModelSettings(onChange: onChange)
                .tabItem { Label("Models", systemImage: "shippingbox") }
                .tag(SettingsTab.models)
            HistorySettings()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(SettingsTab.history)
        }
        .frame(width: 620, height: 520)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var loginItem: LoginItem
    let onChange: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("Dictation key behaviour", selection: $preferences.hotkeyMode) {
                    ForEach(HotkeyMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: preferences.hotkeyMode) { _, _ in onChange() }

                Picker("Dictation key", selection: $preferences.hotkey) {
                    ForEach(Hotkey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .onChange(of: preferences.hotkey) { _, _ in onChange() }

                if preferences.hotkey == .fn {
                    Text(
                        "Set System Settings › Keyboard › \"Press 🌐 key to\" to "
                            + "\"Do Nothing\", or macOS will act on the key as well."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Picker("Listening indicator", selection: $preferences.meterStyle) {
                    ForEach(MeterStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .onChange(of: preferences.meterStyle) { _, _ in onChange() }
                Text(
                    preferences.meterStyle.summary
                        + " Shown while a model that only produces text on release is "
                        + "listening; the others show the words themselves instead."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                Toggle("Keep the microphone open between dictations", isOn: $preferences.keepMicrophoneArmed)
                    .onChange(of: preferences.keepMicrophoneArmed) { _, _ in onChange() }
                Text(
                    "Opening the microphone takes up to a third of a second, and that "
                        + "audio is not delayed \u{2014} it is never recorded. Leaving it open "
                        + "makes a press cost nothing, at the price of the orange "
                        + "microphone indicator staying lit. Nothing is transcribed or "
                        + "kept unless you start a dictation."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                if preferences.keepMicrophoneArmed {
                    Picker("Close it after", selection: $preferences.microphoneIdleMinutes) {
                        Text("Never").tag(0)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("2 hours").tag(120)
                    }
                    .onChange(of: preferences.microphoneIdleMinutes) { _, _ in onChange() }
                    Text(
                        "Closes the microphone once it has gone this long unused, so the "
                            + "indicator does not stay lit all evening. The next press "
                            + "reopens it and pays the opening cost once."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                ShortcutField(
                    title: "Hands-free toggle", chord: $preferences.handsFreeToggleChord,
                    onChange: onChange)

                Text(
                    "Switches continuous dictation on and off from anywhere. This "
                        + "chord is claimed exclusively, so the app in front will not "
                        + "act on it as well."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                ShortcutField(
                    title: "Show history", chord: $preferences.historyChord,
                    onChange: onChange)

                Text(
                    "Opens this window on the History tab, wherever you are. Click a "
                        + "shortcut and press the keys you want; Delete removes it."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } header: {
                Text("Hotkey")
            } footer: {
                Text(
                    "Holding the key dictates while it is down. Tapping to start "
                        + "and stop also ends on Return, which is swallowed only "
                        + "while a dictation is actually running."
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Dictate continuously", isOn: $preferences.handsFreeEnabled)
                    .onChange(of: preferences.handsFreeEnabled) { _, _ in onChange() }

                Picker(
                    "End a sentence after",
                    selection: $preferences.handsFreeSilenceMilliseconds
                ) {
                    // The detector rounds up to 256 ms chunks, so these are the
                    // only values that behave differently. Waits are measured.
                    Text("250 ms — text appears in ~0.7 s").tag(250)
                    Text("500 ms — text appears in ~1.0 s").tag(500)
                    Text("750 ms — text appears in ~1.2 s").tag(750)
                }
                .onChange(of: preferences.handsFreeSilenceMilliseconds) { _, _ in onChange() }
                .disabled(!preferences.handsFreeEnabled)

                Picker("Switch off after silence", selection: $preferences.handsFreeIdleMinutes) {
                    Text("Never").tag(0)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("2 hours").tag(120)
                }
                .onChange(of: preferences.handsFreeIdleMinutes) { _, _ in onChange() }
                .disabled(!preferences.handsFreeEnabled)
            } header: {
                Text("Hands-free")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "The microphone stays open and every sentence is inserted "
                            + "where the cursor is. Press Escape to discard the sentence "
                            + "you are speaking."
                    )
                    Label(
                        "Anything audible is dictated, including other people. "
                            + "The menu bar icon is filled while this is on.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Say \u{201C}scratch that\u{201D} to undo", isOn: $preferences.scratchEnabled)
                    .onChange(of: preferences.scratchEnabled) { _, _ in onChange() }

                Picker("Stop allowing it after", selection: $preferences.scratchWindowSeconds) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                }
                .onChange(of: preferences.scratchWindowSeconds) { _, _ in onChange() }
                .disabled(!preferences.scratchEnabled)
            } header: {
                Text("Undo by voice")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "Said on its own, it deletes the sentence just inserted. "
                            + "Said inside a sentence it is dictated normally, so "
                            + "\u{201C}I had to scratch that idea\u{201D} is safe."
                    )
                    Label(
                        "It deletes by pressing Delete, and cannot tell whether the "
                            + "cursor has moved. A shorter window is safer if you type "
                            + "between sentences.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Accidental presses") {
                Picker(
                    "Ignore presses shorter than",
                    selection: $preferences.minimumHoldMilliseconds
                ) {
                    Text("Off").tag(0)
                    Text("150 ms").tag(150)
                    Text("250 ms").tag(250)
                    Text("400 ms").tag(400)
                }
                .onChange(of: preferences.minimumHoldMilliseconds) { _, _ in onChange() }
                Text("A brief tap is treated as an ordinary keypress and inserts nothing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                // Bound to LaunchServices rather than to a stored preference,
                // so the switch cannot claim a registration that System
                // Settings has since removed.
                Toggle(
                    "Open Murmur at login",
                    isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { loginItem.setEnabled($0) })
                )

                if let explanation = loginItem.explanation {
                    Label(explanation, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button("Open Login Items\u{2026}") { loginItem.openLoginItemsSettings() }
                }

                if let failure = loginItem.failure {
                    Label(failure, systemImage: "xmark.octagon")
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                if !loginItem.isInApplicationsFolder {
                    Text(
                        "This copy is running from \(Bundle.main.bundleURL.deletingLastPathComponent().path). "
                            + "Login items name an exact location, so moving or deleting "
                            + "this copy leaves an item that opens nothing."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text(
                    "Murmur has no Dock icon and no window, so it is easy to forget "
                        + "to start it \u{2014} the menu bar mark is the only sign it is "
                        + "running."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Cleanup

private struct CleanupSettings: View {
    @ObservedObject var preferences: Preferences
    let onChange: () -> Void

    private var unavailableReason: String? { FoundationModelsCleaner.unavailableReason }

    /// One indented sub-switch under the master toggle. Every rule trades away
    /// some literal speech, so each is named with the phrase it consumes.
    @ViewBuilder
    private func rule(_ title: String, _ example: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(example).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 16)
        .disabled(!preferences.formatting.enabled)
        .onChange(of: value.wrappedValue) { _, _ in onChange() }
    }

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Clean up dictation automatically",
                    isOn: $preferences.formatting.enabled
                )
                .onChange(of: preferences.formatting.enabled) { _, _ in onChange() }

                rule(
                    "Apply spoken punctuation", "“new line”, “comma”, “period”",
                    $preferences.formatting.spokenPunctuation)
                rule("Remove filler words", "“um”, “uh”", $preferences.formatting.removeFillers)
                rule(
                    "Numbers and years", "“twenty twenty six” → 2026",
                    $preferences.formatting.numbers)
                rule("Currency", "“five dollars” → $5", $preferences.formatting.currency)
                rule(
                    "Spoken lists", "“bullet buy milk” → - buy milk",
                    $preferences.formatting.lists)
                rule(
                    "Markdown commands", "“heading intro”, “bold ship it”",
                    $preferences.formatting.markdown)
            } header: {
                Text("Formatting")
            } footer: {
                Text(
                    "Free, instant, on-device: capitalizes sentences and tidies spacing "
                        + "and punctuation. No internet required. Numbers, currency, lists, "
                        + "and markdown are off by default so they never touch ordinary prose."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Correction strength") {
                ForEach(CleanupLevel.allCases) { level in
                    HStack(alignment: .top, spacing: 10) {
                        Image(
                            systemName: preferences.cleanupLevel == level
                                ? "largecircle.fill.circle" : "circle"
                        )
                        .foregroundStyle(preferences.cleanupLevel == level ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.displayName).font(.body)
                            Text(level.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard unavailableReason == nil || level == .off else { return }
                        preferences.cleanupLevel = level
                        onChange()
                    }
                    .opacity(unavailableReason == nil || level == .off ? 1 : 0.4)
                }
            }

            Section("Safeguards") {
                Label(
                    "Questions you dictate are never answered, only punctuated.",
                    systemImage: "checkmark.shield"
                )
                Label(
                    "A reply that stops looking like a correction is discarded, "
                        + "and your raw words are inserted instead.",
                    systemImage: "checkmark.shield"
                )
                Label("Runs entirely on this Mac. Nothing is uploaded.", systemImage: "lock")
            }
            .font(.callout)

            if let unavailableReason {
                Section {
                    Label(unavailableReason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Vocabulary

@MainActor
private final class VocabularyModel: ObservableObject {
    @Published var terms: [VocabularyTerm] = []
    @Published var draft: String = ""
    @Published var duplicateWarning = false

    private let store = VocabularyStore.shared

    func load() { terms = store.allTerms }

    func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        duplicateWarning = !store.add(text)
        if !duplicateWarning { draft = "" }
        load()
    }

    func remove(_ term: VocabularyTerm) {
        store.remove(term)
        load()
    }

    func update(_ term: VocabularyTerm) {
        store.update(term)
        load()
    }
}

private struct VocabularySettings: View {
    @StateObject private var model = VocabularyModel()
    let onChange: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your words").font(.headline)
                Text(
                    "Names and terms Murmur should recognize — \"VS Code\", \"Claude\", "
                        + "project names, colleagues' names."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack {
                TextField("Add a word or phrase", text: $model.draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { commit() }
                Button("Add") { commit() }
                    .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if model.duplicateWarning {
                Label("That word is already in the list.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.terms.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "character.book.closed")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No words yet.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.terms) { term in
                        TermRow(
                            term: term,
                            onUpdate: {
                                model.update($0)
                                onChange()
                            },
                            onRemove: {
                                model.remove(term)
                                onChange()
                            }
                        )
                    }
                }
            }
        }
        .padding()
        .onAppear { model.load() }
    }

    private func commit() {
        model.add()
        onChange()
        fieldFocused = true
    }
}

/// One word, with the misheard variants that should map back to it.
private struct TermRow: View {
    let term: VocabularyTerm
    let onUpdate: (VocabularyTerm) -> Void
    let onRemove: () -> Void

    @State private var expanded = false
    @State private var alias = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)

                Text(term.text)
                if !term.soundsLike.isEmpty {
                    Text("heard as \(term.soundsLike.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onRemove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sometimes misheard as")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("e.g. cloud", text: $alias)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addAlias() }
                        Button("Add", action: addAlias)
                            .disabled(alias.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if !term.soundsLike.isEmpty {
                        FlowChips(items: term.soundsLike) { removeAlias($0) }
                    }

                    Toggle(
                        "Always replace, even when the ordinary word was meant",
                        isOn: Binding(
                            get: { term.alwaysReplace },
                            set: { newValue in
                                var updated = term
                                updated.alwaysReplace = newValue
                                onUpdate(updated)
                            }
                        )
                    )
                    .font(.callout)
                    .disabled(term.soundsLike.isEmpty)

                    Text(
                        term.alwaysReplace
                            ? "Every occurrence is rewritten. \"in the cloud\" would become "
                                + "\"in the Claude\"."
                            : "The correction model decides from context, so ordinary uses of "
                                + "the everyday word are left alone."
                    )
                    .font(.caption)
                    .foregroundStyle(term.alwaysReplace ? .orange : .secondary)
                }
                .padding(.leading, 20)
                .padding(.bottom, 4)
            }
        }
    }

    private func addAlias() {
        let text = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var updated = term
        guard !updated.soundsLike.contains(where: { $0.lowercased() == text.lowercased() })
        else {
            alias = ""
            return
        }
        updated.soundsLike.append(text)
        onUpdate(updated)
        alias = ""
    }

    private func removeAlias(_ value: String) {
        var updated = term
        updated.soundsLike.removeAll { $0 == value }
        onUpdate(updated)
    }
}

/// Removable chips for the misheard variants.
private struct FlowChips: View {
    let items: [String]
    let onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 4) {
                    Text(item).font(.caption)
                    Button {
                        onRemove(item)
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Models

@MainActor
private final class ModelListModel: ObservableObject {
    @Published var installedIDs: Set<String> = []
    @Published var activeSpeechID = ModelCatalog.appleSpeechID
    @Published var activeCorrectionID = ModelCatalog.appleCorrectionID
    @Published var busyID: String?
    @Published var errorMessage: String?

    /// Pushes the new choice into the running app. Without this the selection
    /// would only be saved, and would not take effect until the next launch.
    var onChange: () -> Void = {}

    func state(for descriptor: AIModelDescriptor) -> ModelInstallState {
        ModelCatalog.state(
            for: descriptor,
            appleSpeechAvailable: AppleSpeechEngine.isSupported,
            appleCorrectionUnavailableReason: FoundationModelsCleaner.unavailableReason,
            installedIDs: installedIDs
        )
    }

    func activeID(for layer: ModelLayer) -> String {
        layer == .speechRecognition ? activeSpeechID : activeCorrectionID
    }

    func activate(_ descriptor: AIModelDescriptor) {
        switch descriptor.layer {
        case .speechRecognition: activeSpeechID = descriptor.id
        case .correction: activeCorrectionID = descriptor.id
        }
        Preferences.shared.activeSpeechModelID = activeSpeechID
        Preferences.shared.activeCorrectionModelID = activeCorrectionID
        onChange()
    }

    func load() {
        activeSpeechID = Preferences.shared.activeSpeechModelID
        activeCorrectionID = Preferences.shared.activeCorrectionModelID
        installedIDs = ModelCatalog.installedModelIDs()
    }

    /// Downloads weights. Needs a network connection the first time only.
    func download(_ descriptor: AIModelDescriptor) async {
        busyID = descriptor.id
        errorMessage = nil
        defer { busyID = nil }
        do {
            try await ModelCatalog.install(descriptor)
            Log.write("downloaded model \(descriptor.id)")
        } catch {
            errorMessage = "\(descriptor.name): \(error.localizedDescription)"
            Log.write("model download failed for \(descriptor.id): \(error)")
        }
        installedIDs = ModelCatalog.installedModelIDs()
    }

    func delete(_ descriptor: AIModelDescriptor) {
        do {
            try ModelCatalog.delete(descriptor)
            // Fall back to the built-in engine if the active model just went away.
            if activeSpeechID == descriptor.id {
                activate(ModelCatalog.model(id: ModelCatalog.appleSpeechID)!)
            }
        } catch {
            errorMessage = "\(descriptor.name): \(error.localizedDescription)"
        }
        installedIDs = ModelCatalog.installedModelIDs()
    }
}

private struct ModelSettings: View {
    @StateObject private var model = ModelListModel()
    let onChange: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(ModelLayer.allCases) { layer in
                    section(for: layer)
                }

                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Text(
                    "Models are never bundled with Murmur. Anything not built into "
                        + "macOS is downloaded only when you ask for it — that first "
                        + "download needs an internet connection, and everything after "
                        + "it runs offline on this Mac."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding()
        }
        .onAppear {
            model.onChange = onChange
            model.load()
        }
    }

    private func section(for layer: ModelLayer) -> some View {
        let models = ModelCatalog.models(in: layer)
        return VStack(alignment: .leading, spacing: 8) {
            Text(layer.title).font(.headline)
            Text(layer.subtitle).font(.callout).foregroundStyle(.secondary)

            if layer == .speechRecognition {
                // The wait is the thing worth knowing before choosing, so the
                // two kinds are separated rather than mixed and badged alone.
                group("Live as you speak", models.filter(\.streams))
                group("Only when you release the key", models.filter { !$0.streams })
            } else {
                list(models)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ models: [AIModelDescriptor]) -> some View {
        if !models.isEmpty {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            list(models)
        }
    }

    private func list(_ models: [AIModelDescriptor]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(models.enumerated()), id: \.element.id) { index, descriptor in
                if index > 0 { Divider() }
                row(descriptor)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ descriptor: AIModelDescriptor) -> some View {
        let state = model.state(for: descriptor)
        let isActive = model.activeID(for: descriptor.layer) == descriptor.id && state.isUsable

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(descriptor.name).font(.body.weight(.medium))
                    if descriptor.layer == .speechRecognition {
                        Text(descriptor.streams ? "LIVE" : "ON RELEASE")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                (descriptor.streams ? Color.green : Color.orange).opacity(0.18)
                            )
                            .foregroundStyle(descriptor.streams ? Color.green : Color.orange)
                            .clipShape(Capsule())
                    }
                }
                Text(descriptor.summary).font(.callout).foregroundStyle(.secondary)
                Text("\(descriptor.vendor) · \(descriptor.sizeDescription) · \(descriptor.license)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if case .unavailable(let reason) = state {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
                if descriptor.layer == .speechRecognition, !descriptor.punctuates {
                    Label(
                        "Needs AI correction turned on for punctuation.",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Spacer()
            actions(for: descriptor, state: state, isActive: isActive)
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture {
            guard state.isUsable else { return }
            model.activate(descriptor)
        }
    }

    @ViewBuilder
    private func actions(
        for descriptor: AIModelDescriptor,
        state: ModelInstallState,
        isActive: Bool
    ) -> some View {
        switch state {
        case .builtIn:
            VStack(alignment: .trailing, spacing: 4) {
                Text(isActive ? "Active" : "Built in")
                    .font(.callout)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
        case .installed:
            VStack(alignment: .trailing, spacing: 4) {
                Text(isActive ? "Active" : "Installed")
                    .font(.callout)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Button("Delete", role: .destructive) { model.delete(descriptor) }
                    .buttonStyle(.link)
            }
        case .notInstalled:
            if model.busyID == descriptor.id {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Button("Download") {
                    Task { await model.download(descriptor) }
                }
                .disabled(model.busyID != nil)
            }
        case .downloading(let fraction):
            ProgressView(value: fraction).frame(width: 90)
        case .unavailable:
            Text("Unavailable").font(.callout).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - History

@MainActor
private final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []

    private let store = HistoryStore.shared
    private var observer: NSObjectProtocol?

    /// Reads the store on every insertion, not only when the view appears.
    ///
    /// The settings window is created once and kept (`isReleasedWhenClosed`
    /// is false), so `onAppear` fires the first time this tab is shown and
    /// never again — dictate, reopen settings, and the list is exactly as it
    /// was. That looked like history not being recorded at all.
    init() {
        entries = store.entries
        observer = NotificationCenter.default.addObserver(
            forName: HistoryStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func load() { entries = store.entries }
}

private struct HistorySettings: View {
    @StateObject private var model = HistoryModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent transcriptions").font(.headline)
                Text("The last \(HistoryStore.limit) sentences Murmur inserted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Nothing dictated yet.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.entries) { entry in
                        HistoryRow(entry: entry)
                    }
                }
            }
        }
        .padding()
        .onAppear { model.load() }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .lineLimit(3)
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: copy) {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copied ? Color.accentColor : .secondary)
            .help(copied ? "Copied" : "Copy")
        }
        .padding(.vertical, 2)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeOut(duration: 0.15)) { copied = false }
        }
    }
}
