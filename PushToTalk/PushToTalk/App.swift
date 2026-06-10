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

/// Lifecycle of a resident model, surfaced in the menu (Gotcha 8: models
/// load once at launch, so the user needs to see "warming up" somewhere).
enum ModelStatus {
    case loading
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .loading: "Whisper: loading…"
        case .ready: "Whisper: ready"
        case .failed(let reason): "Whisper failed: \(reason)"
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
    /// Rolling window of recent mic levels (0–1) for the HUD bars; newest
    /// at the end. Fixed length so the bars never jump in count.
    var hudLevels: [CGFloat] = AppState.restingLevels
    var whisperStatus: ModelStatus = .loading

    private static let restingLevels = [CGFloat](repeating: 0, count: 12)
    /// Port of the prototype's MIN_RECORD_SECONDS: near-empty audio makes
    /// Whisper hallucinate phrases like "Thank you." (Gotcha 6).
    private static let minRecordSeconds = 0.3

    // Not UI state, so exempt them from observation tracking.
    @ObservationIgnored private let hotkey = HotkeyManager()
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let transcriber = Transcriber()
    @ObservationIgnored private var overlay: OverlayPanel?
    /// Tail of the processing chain — the prototype's `_busy` lock, in Task
    /// form. Each dictation awaits the previous one, so rapid-fire
    /// dictations queue in order instead of interleaving.
    @ObservationIgnored private var pipelineTask: Task<Void, Never>?

    func start() {
        hotkey.onPress = { [weak self] in self?.beginDictation() }
        hotkey.onRelease = { [weak self] in self?.endDictation() }
        hotkeyReady = hotkey.start()

        recorder.onLevel = { [weak self] level in self?.pushLevel(CGFloat(level)) }
        // Settle the mic permission dialog at launch, not mid-dictation.
        recorder.requestPermission()

        // Warm-load Whisper now so the first dictation doesn't pay the
        // model load (Gotcha 8). Dictations that finish before this does
        // simply queue behind the load and transcribe once it's ready.
        Task {
            do {
                try await transcriber.warmLoad()
                whisperStatus = .ready
            } catch {
                whisperStatus = .failed(error.localizedDescription)
            }
        }
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
        hudLevels = Self.restingLevels

        do {
            try recorder.start()
        } catch {
            // Most likely: mic permission missing, so there's no input
            // format to record from. The HUD still shows; bars stay flat.
            print("recorder failed to start: \(error)")
        }

        // Created lazily so no window work happens during app startup.
        if overlay == nil { overlay = OverlayPanel(state: self) }
        overlay?.show()
    }

    private func endDictation() {
        let samples = recorder.stop()
        overlay?.hide()

        let duration = Double(samples.count) / AudioRecorder.sampleRate
        guard duration >= Self.minRecordSeconds else {
            print(String(format: "  (ignored %.2fs tap)", duration))
            phase = .idle
            return
        }

        phase = .processing
        pipelineTask = Task { [previous = pipelineTask] in
            // Serialization point: wait for the previous dictation's
            // pipeline before starting ours.
            _ = await previous?.result
            await self.process(samples)
        }
    }

    private func process(_ samples: [Float]) async {
        do {
            let started = Date()
            let text = try await transcriber.transcribe(samples)
            let elapsed = Date().timeIntervalSince(started)
            if text.isEmpty {
                // Whisper on borderline audio: skip rather than paste junk.
                print("  (empty transcript)")
            } else {
                print(String(format: "  whisper [%.2fs]: \"%@\"", elapsed, text))
            }
        } catch {
            print("  transcription failed: \(error)")
        }
        // Don't clobber the phase if the user is already holding the key
        // for the next dictation.
        if phase == .processing { phase = .idle }
    }

    private func pushLevel(_ level: CGFloat) {
        guard phase == .recording else { return }
        hudLevels.removeFirst()
        hudLevels.append(level)
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
            Text(appState.whisperStatus.label)

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
