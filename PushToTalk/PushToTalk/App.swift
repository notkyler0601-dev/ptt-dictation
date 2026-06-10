import SwiftUI

/// Where the dictation pipeline currently is. Later stages move this through
/// idle → recording → processing → idle; the menu bar icon mirrors it.
enum DictationPhase {
    case idle
    case recording
    case processing

    /// SF Symbol shown in the menu bar. Menu bar icons render as monochrome
    /// "template" images, so states are distinguished by shape, not color.
    var symbolName: String {
        switch self {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .processing: "waveform"
        }
    }

    var label: String {
        switch self {
        case .idle: "Idle — hold right Option to dictate"
        case .recording: "Recording…"
        case .processing: "Transcribing…"
        }
    }
}

/// App-wide state. @Observable (macOS 14's Observation framework) makes any
/// SwiftUI view that *reads* a property re-render when that property changes —
/// no subscription boilerplate. Pipeline components write to this; views
/// only read it.
@Observable
final class AppState {
    /// Singleton because SwiftUI may re-evaluate the App struct's property
    /// initializers; the event tap must only ever be wired up against one
    /// long-lived instance.
    static let shared = AppState()

    var phase: DictationPhase = .idle
    /// False when the event tap couldn't start (Input Monitoring not yet
    /// granted) — drives the warning section in the menu.
    var hotkeyReady = false

    // Not UI state, so exempt them from observation tracking.
    @ObservationIgnored private let hotkey = HotkeyManager()
    @ObservationIgnored private var overlay: OverlayPanel?

    func start() {
        hotkey.onPress = { [weak self] in self?.beginDictation() }
        hotkey.onRelease = { [weak self] in self?.endDictation() }
        hotkeyReady = hotkey.start()
    }

    func retryHotkey() {
        hotkeyReady = hotkey.start()
    }

    func openInputMonitoringSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        NSWorkspace.shared.open(URL(string: pane)!)
    }

    private func beginDictation() {
        phase = .recording
        // Created lazily so no window work happens during app startup.
        if overlay == nil { overlay = OverlayPanel() }
        overlay?.show()
    }

    private func endDictation() {
        // Stage 4 will insert .processing between these two.
        phase = .idle
        overlay?.hide()
    }
}

@main
struct PushToTalkApp: App {
    @State private var appState = AppState.shared

    init() {
        // App.init is the earliest launch hook a pure-SwiftUI app has
        // (no AppDelegate). Idempotent: start() no-ops if already running.
        AppState.shared.start()
    }

    var body: some Scene {
        // MenuBarExtra is the whole UI — no WindowGroup, and LSUIElement=YES
        // in the target settings keeps the app out of the Dock and Cmd+Tab.
        MenuBarExtra {
            Text(appState.phase.label)

            if !appState.hotkeyReady {
                Divider()
                Text("⚠️ Needs Input Monitoring permission")
                Button("Open Privacy Settings…") {
                    appState.openInputMonitoringSettings()
                }
                Button("Retry") {
                    appState.retryHotkey()
                }
            }

            Divider()

            // LSUIElement apps have no Dock icon or app menu, so without this
            // button the only way to quit would be Activity Monitor.
            Button("Quit PushToTalk") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: appState.phase.symbolName)
        }
    }
}
