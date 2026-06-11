import SwiftUI
import ServiceManagement

/// The Settings window (⌘, or the menu's "Settings…").
///
/// @AppStorage is SwiftUI's two-way binding to UserDefaults: editing a
/// control writes the default immediately, and the pipeline reads the same
/// keys (Prefs.*) at dictation time — no sync layer needed.
struct SettingsView: View {
    @AppStorage(Prefs.hotkey) private var hotkeyRaw = HotkeyChoice.rightOption.rawValue
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
                Text("If a dictation matches a phrase exactly (case and punctuation are ignored), the text on the right is typed instead. Turn on ⏎ to also press Return — useful in a terminal, so \"cd downloads\" actually runs `cd ~/Downloads`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach($voiceCommands) { $command in
                    HStack(spacing: 8) {
                        TextField("Say… (cd downloads)", text: $command.phrase)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                        TextField("Type… (cd ~/Downloads)", text: $command.replacement)
                            .font(.system(.body, design: .monospaced))
                        Toggle("⏎", isOn: $command.pressReturn)
                            .toggleStyle(.checkbox)
                            .help("Press Return after typing (runs the command)")
                        Button {
                            voiceCommands.removeAll { $0.id == command.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Button("Add Command") {
                    voiceCommands.append(VoiceCommand(phrase: "", replacement: ""))
                }
            }
            .onChange(of: voiceCommands) { _, commands in
                VoiceCommandStore.save(commands)
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

#Preview {
    SettingsView()
}
