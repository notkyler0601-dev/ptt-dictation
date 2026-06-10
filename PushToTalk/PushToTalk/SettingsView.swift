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
