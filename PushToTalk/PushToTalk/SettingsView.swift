import SwiftUI
import ServiceManagement

/// The Settings window (⌘, or the menu's "Settings…").
///
/// @AppStorage is SwiftUI's two-way binding to UserDefaults: editing a
/// control writes the default immediately, and the pipeline reads the same
/// keys (Prefs.*) at dictation time — no sync layer needed.
struct SettingsView: View {
    @AppStorage(Prefs.hotkey) private var hotkeyRaw = HotkeyChoice.rightOption.rawValue
    @AppStorage(Prefs.rewriteHotkey) private var rewriteHotkeyRaw = HotkeyChoice.rightCommand.rawValue
    @AppStorage(Prefs.memorySaverMinutes) private var memorySaverMinutes = 15
    @AppStorage(Prefs.soundsEnabled) private var soundsEnabled = true
    @AppStorage(Prefs.cleanupEnabled) private var cleanupEnabled = true
    @AppStorage(Prefs.cleanupPrompt) private var cleanupPrompt = Cleaner.systemPrompt

    /// SMAppService doesn't publish changes, so mirror it into local state
    /// and re-read after every toggle attempt.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    /// Voice command rules: edited here as local state, persisted to
    /// UserDefaults on every change (the pipeline re-reads per dictation).
    @State private var voiceCommands = VoiceCommandStore.load()
    /// Non-nil while the editor sheet is up — either an existing command
    /// (pencil button) or a fresh blank one (Add Command).
    @State private var editingCommand: VoiceCommand?

    var body: some View {
        Form {
            Section("General") {
                Picker("Push-to-talk key", selection: $hotkeyRaw) {
                    ForEach(HotkeyChoice.allCases) { choice in
                        Text(choice.label).tag(choice.rawValue)
                    }
                }
                .onChange(of: hotkeyRaw) { _, raw in
                    AppState.shared.setHotkey(HotkeyChoice(rawValue: raw) ?? .rightOption)
                }

                Picker("Rewrite key", selection: $rewriteHotkeyRaw) {
                    Text("Off").tag("off")
                    ForEach(HotkeyChoice.allCases) { choice in
                        Text(choice.label).tag(choice.rawValue)
                    }
                }
                .onChange(of: rewriteHotkeyRaw) { _, raw in
                    AppState.shared.setRewriteHotkey(raw)
                }
                Text("Select text in any app, hold the rewrite key, and speak an instruction (\"make this more formal\") — the local LLM replaces the selection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if rewriteHotkeyRaw == hotkeyRaw {
                    Text("The rewrite key must differ from the push-to-talk key — rewrite is disabled while they match.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Picker("Unload models when idle", selection: $memorySaverMinutes) {
                    Text("Never").tag(0)
                    Text("After 5 minutes").tag(5)
                    Text("After 15 minutes").tag(15)
                    Text("After 30 minutes").tag(30)
                    Text("After 1 hour").tag(60)
                }
                Text("Frees ~4 GB of RAM when you're not dictating. The first dictation afterwards reloads the models (a few seconds).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Sound feedback (Tink on start, Pop on paste)", isOn: $soundsEnabled)

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginItemError = nil
                        } catch {
                            loginItemError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Cleanup") {
                Toggle("Clean up transcripts with the local LLM", isOn: $cleanupEnabled)
                Text("Only runs on dictations of \(Cleaner.minWords)+ words; shorter ones always paste instantly. If the model misbehaves, the raw transcript pastes instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Cleanup instructions")
                    TextEditor(text: $cleanupPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 110)
                        .disabled(!cleanupEnabled)
                    Button("Reset to default") {
                        cleanupPrompt = Cleaner.systemPrompt
                    }
                    .disabled(cleanupPrompt == Cleaner.systemPrompt)
                }
            }

            Section("Voice commands") {
                Text("If a dictation matches a phrase exactly (case and punctuation are ignored), the mapped text is typed instead. Commands with ⏎ also press Return — useful in a terminal, so \"cd downloads\" actually runs `cd ~/Downloads`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(voiceCommands) { command in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("“\(command.phrase)”")
                            Text(command.replacement)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if command.pressReturn {
                            Image(systemName: "return")
                                .foregroundStyle(.secondary)
                                .help("Presses Return after typing")
                        }
                        Button {
                            editingCommand = command
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Edit")
                        Button {
                            voiceCommands.removeAll { $0.id == command.id }
                            VoiceCommandStore.save(voiceCommands)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete")
                    }
                }

                Button("Add Command…") {
                    editingCommand = VoiceCommand(phrase: "", replacement: "")
                }
            }
            // Sheet instead of inline row editing: text fields inside Form
            // rows on macOS often refuse focus (long-standing SwiftUI bug);
            // a sheet's fields are ordinary and dependable.
            .sheet(item: $editingCommand) { command in
                VoiceCommandEditor(command: command) { saved in
                    if let index = voiceCommands.firstIndex(where: { $0.id == saved.id }) {
                        voiceCommands[index] = saved
                    } else {
                        voiceCommands.append(saved)
                    }
                    VoiceCommandStore.save(voiceCommands)
                }
            }

            Section("Models (downloaded on first launch, then cached)") {
                LabeledContent("Speech to text") {
                    Text("\(Transcriber.modelName) — \(AppState.shared.whisperStatus.text)")
                }
                LabeledContent("Cleanup LLM") {
                    Text("Qwen3-4B-Instruct 4-bit — \(AppState.shared.cleanupStatus.text)")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Editor sheet for one voice command. Local @State copies, committed to
/// the caller only on Save — Cancel discards cleanly.
struct VoiceCommandEditor: View {
    private let id: UUID
    @State private var phrase: String
    @State private var replacement: String
    @State private var pressReturn: Bool
    let onSave: (VoiceCommand) -> Void
    @Environment(\.dismiss) private var dismiss

    init(command: VoiceCommand, onSave: @escaping (VoiceCommand) -> Void) {
        self.id = command.id
        _phrase = State(initialValue: command.phrase)
        _replacement = State(initialValue: command.replacement)
        _pressReturn = State(initialValue: command.pressReturn)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Voice Command")
                .font(.headline)

            Form {
                TextField("When I say", text: $phrase, prompt: Text("cd downloads"))
                TextField("Type this", text: $replacement, prompt: Text("cd ~/Downloads"))
                    .font(.system(.body, design: .monospaced))
                Toggle("Press Return after typing (runs it)", isOn: $pressReturn)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    onSave(VoiceCommand(
                        id: id, phrase: phrase,
                        replacement: replacement, pressReturn: pressReturn))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(phrase.trimmingCharacters(in: .whitespaces).isEmpty
                          || replacement.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

#Preview {
    SettingsView()
}
