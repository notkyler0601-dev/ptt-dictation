import SwiftUI

/// The panel shown when clicking the menu bar icon (MenuBarExtra .window
/// style — a real SwiftUI surface instead of a text-only dropdown).
/// Status header, model rows, permission banners with fix buttons, recent
/// dictations with copy, and Settings/Quit.
struct MenuView: View {
    var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                modelRow("Whisper", state.whisperStatus)
                modelRow("Cleanup LLM", state.cleanupStatus)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if !state.hotkeyReady {
                banner(
                    "Input Monitoring permission needed for the hotkey.",
                    buttonTitle: "Open Settings",
                    action: { state.openInputMonitoringSettings() },
                    retry: { state.retryHotkey() })
            }
            if !state.pasteReady {
                banner(
                    "Accessibility permission needed to paste.",
                    buttonTitle: "Open Settings",
                    action: { state.openAccessibilitySettings() },
                    retry: { state.retryPaste() })
            }

            Divider()
            history
            Divider()

            HStack {
                Button("Settings…") {
                    openSettings()
                    // LSUIElement app: without activation the Settings
                    // window opens behind the frontmost app.
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(phaseColor.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: state.phase.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(phaseColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("PushToTalk")
                    .font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var statusLine: String {
        switch state.phase {
        case .idle: "Hold \(state.hotkeyLabel) to dictate"
        case .recording: "Recording…"
        case .processing: "Transcribing…"
        }
    }

    private var phaseColor: Color {
        switch state.phase {
        case .idle: .secondary
        case .recording: .red
        case .processing: .orange
        }
    }

    private func modelRow(_ name: String, _ status: ModelStatus) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 7, height: 7)
            Text(name)
                .font(.callout)
            Spacer()
            Text(status.text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statusColor(_ status: ModelStatus) -> Color {
        switch status {
        case .ready: .green
        case .loading, .downloading: .orange
        case .failed: .red
        }
    }

    private func banner(
        _ message: String, buttonTitle: String,
        action: @escaping () -> Void, retry: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
            HStack {
                Button(buttonTitle, action: action)
                Button("Retry", action: retry)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent dictations")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)

            if state.history.isEmpty {
                Text("Hold \(state.hotkeyLabel) and speak — transcripts appear here. Kept in memory only; cleared on quit.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(state.history) { record in
                            historyRow(record)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 230)
            }
        }
    }

    private func historyRow(_ record: DictationRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.text)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(record.date, style: .time)
                Text(String(format: "· %.1fs", record.duration))
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(record.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy transcript")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    MenuView(state: AppState())
}
