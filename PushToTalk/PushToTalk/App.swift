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
/// no subscription boilerplate. Stage 2+ components (hotkey, recorder,
/// transcriber) will write to this; views only read it.
@Observable
final class AppState {
    var phase: DictationPhase = .idle
}

@main
struct PushToTalkApp: App {
    /// @State on the App struct keeps this single instance alive for the
    /// whole app lifetime (the App struct itself is a value type that SwiftUI
    /// recreates freely; @State storage survives those recreations).
    @State private var appState = AppState()

    var body: some Scene {
        // MenuBarExtra is the whole UI — no WindowGroup, and LSUIElement=YES
        // in the target settings keeps the app out of the Dock and Cmd+Tab.
        MenuBarExtra {
            Text(appState.phase.label)

            Divider()

            // Stage 1 only: lets us see the icon react before any real
            // pipeline exists. Remove in Stage 2 when the hotkey drives phase.
            Button("Cycle State (Stage 1 debug)") {
                switch appState.phase {
                case .idle: appState.phase = .recording
                case .recording: appState.phase = .processing
                case .processing: appState.phase = .idle
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
