import SwiftUI

/// UserDefaults keys, shared between SettingsView (@AppStorage) and the
/// pipeline (reads at dictation time).
enum Prefs {
    static let hotkey = "hotkey"
    static let soundsEnabled = "soundsEnabled"
    static let cleanupEnabled = "cleanupEnabled"
    static let cleanupPrompt = "cleanupPrompt"
}

/// Where the dictation pipeline currently is. The pipeline moves this
/// through idle → recording → processing → idle; the menu bar icon and the
/// HUD both mirror it.
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
        case .idle: "Idle — hold the hotkey to dictate"
        case .recording: "Recording…"
        case .processing: "Transcribing…"
        }
    }
}

/// Lifecycle of a resident model, surfaced in the menu (Gotcha 8: models
/// load once at launch, so the user needs to see "warming up" somewhere).
enum ModelStatus {
    case loading
    case downloading(percent: Int)
    case ready
    case failed(String)

    var text: String {
        switch self {
        case .loading: "loading…"
        case .downloading(let percent): "downloading… \(percent)%"
        case .ready: "ready"
        case .failed(let reason): "failed: \(reason)"
        }
    }
}

/// One finished dictation, for the menu's history list. In-memory only —
/// transcripts are never written to disk (the app's whole premise is that
/// nothing leaves the machine, or even outlives the process).
struct DictationRecord: Identifiable {
    let id = UUID()
    let text: String
    let date: Date
    let duration: TimeInterval
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
    var cleanupStatus: ModelStatus = .loading
    /// False until Accessibility is granted (needed to post the Cmd+V).
    var pasteReady = false
    /// Newest first, capped at 20, in-memory only.
    var history: [DictationRecord] = []
    /// Mirror of the active hotkey's display name (the manager itself is
    /// @ObservationIgnored, so views can't observe it directly).
    var hotkeyLabel = HotkeyChoice.rightOption.label

    private static let restingLevels = [CGFloat](repeating: 0, count: 12)
    /// Port of the prototype's MIN_RECORD_SECONDS: near-empty audio makes
    /// Whisper hallucinate phrases like "Thank you." (Gotcha 6).
    private static let minRecordSeconds = 0.3

    // Not UI state, so exempt them from observation tracking.
    @ObservationIgnored private let hotkey = HotkeyManager()
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let transcriber = Transcriber()
    @ObservationIgnored private let cleaner = Cleaner()
    @ObservationIgnored private let paster = Paster()
    @ObservationIgnored private var overlay: OverlayPanel?
    /// Tail of the processing chain — the prototype's `_busy` lock, in Task
    /// form. Each dictation awaits the previous one, so rapid-fire
    /// dictations queue in order instead of interleaving.
    @ObservationIgnored private var pipelineTask: Task<Void, Never>?

    func start() {
        UserDefaults.standard.register(defaults: [
            Prefs.soundsEnabled: true,
            Prefs.cleanupEnabled: true,
        ])

        if let raw = UserDefaults.standard.string(forKey: Prefs.hotkey),
           let choice = HotkeyChoice(rawValue: raw) {
            hotkey.hotkey = choice
            hotkeyLabel = choice.label
        }
        hotkey.onPress = { [weak self] in self?.beginDictation() }
        hotkey.onRelease = { [weak self] in self?.endDictation() }
        hotkeyReady = hotkey.start()

        recorder.onLevel = { [weak self] level in self?.pushLevel(CGFloat(level)) }
        // Settle the mic permission dialog at launch, not mid-dictation.
        recorder.requestPermission()

        // Same for Accessibility (the synthetic Cmd+V needs it).
        pasteReady = paster.requestPermission()

        // Warm-load the models so the first dictation doesn't pay the load
        // cost (Gotcha 8). Sequential like the prototype: Whisper first
        // (the must-have), then the cleanup LLM. Dictations that finish
        // before a load simply queue behind it.
        Task {
            do {
                try await transcriber.warmLoad { fraction in
                    // Progress arrives on a background thread; hop to main
                    // before touching observable state.
                    Task { @MainActor in
                        AppState.shared.setDownloadProgress(fraction, for: \.whisperStatus)
                    }
                }
                whisperStatus = .ready
            } catch {
                whisperStatus = .failed(error.localizedDescription)
            }
            do {
                try await cleaner.warmLoad { fraction in
                    Task { @MainActor in
                        AppState.shared.setDownloadProgress(fraction, for: \.cleanupStatus)
                    }
                }
                cleanupStatus = .ready
            } catch {
                cleanupStatus = .failed(error.localizedDescription)
            }
        }
    }

    func retryHotkey() {
        hotkeyReady = hotkey.start()
    }

    func setHotkey(_ choice: HotkeyChoice) {
        hotkey.hotkey = choice
        hotkeyLabel = choice.label
        UserDefaults.standard.set(choice.rawValue, forKey: Prefs.hotkey)
    }

    /// Coalesce noisy Progress callbacks into whole-percent menu updates.
    func setDownloadProgress(_ fraction: Double, for status: ReferenceWritableKeyPath<AppState, ModelStatus>) {
        let percent = Int(fraction * 100)
        if case .downloading(let current) = self[keyPath: status], current == percent { return }
        // Don't regress a model that already finished (a late callback
        // can land after .ready is set).
        if case .ready = self[keyPath: status] { return }
        self[keyPath: status] = .downloading(percent: percent)
    }

    func retryPaste() {
        pasteReady = paster.hasPermission
    }

    func openInputMonitoringSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        NSWorkspace.shared.open(URL(string: pane)!)
    }

    func openAccessibilitySettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        NSWorkspace.shared.open(URL(string: pane)!)
    }

    private func beginDictation() {
        phase = .recording
        hudLevels = Self.restingLevels
        play("Tink")

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

        let duration = Double(samples.count) / AudioRecorder.sampleRate
        guard duration >= Self.minRecordSeconds else {
            print(String(format: "  (ignored %.2fs tap)", duration))
            phase = .idle
            overlay?.hide()
            return
        }

        // Keep the HUD up — it switches to its "Transcribing…" face via the
        // phase change, and hides when the pipeline goes idle.
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
            var started = Date()
            var text = try await transcriber.transcribe(samples)
            let whisperTime = Date().timeIntervalSince(started)
            if text.isEmpty {
                // Whisper on borderline audio: skip rather than paste junk.
                print("  (empty transcript)")
            } else {
                print(String(format: "  whisper [%.2fs]: \"%@\"", whisperTime, text))

                // Short utterances paste raw — keeps them instant
                // (prototype: CLEANUP_MIN_WORDS).
                let words = text.split(whereSeparator: \.isWhitespace).count
                let defaults = UserDefaults.standard
                if defaults.bool(forKey: Prefs.cleanupEnabled), words >= Cleaner.minWords {
                    started = Date()
                    do {
                        let prompt = defaults.string(forKey: Prefs.cleanupPrompt)
                            ?? Cleaner.systemPrompt
                        text = try await cleaner.cleanup(text, prompt: prompt)
                        print(String(format: "  cleanup [%.2fs]: \"%@\"",
                                     Date().timeIntervalSince(started), text))
                    } catch {
                        // Cleanup is best-effort; the transcript still lands.
                        print("  cleanup failed (pasting raw): \(error)")
                    }
                }

                // Record before pasting so the transcript is recoverable
                // from the menu even if the paste itself can't run.
                let duration = Double(samples.count) / AudioRecorder.sampleRate
                history.insert(
                    DictationRecord(text: text, date: Date(), duration: duration), at: 0)
                if history.count > 20 { history.removeLast(history.count - 20) }

                if !paster.hasPermission {
                    print("  (paste skipped: Accessibility not granted)")
                    pasteReady = false
                } else {
                    await paster.paste(text)
                    play("Pop")
                }
            }
        } catch {
            print("  transcription failed: \(error)")
        }
        // Don't clobber the phase (or the HUD) if the user is already
        // holding the key for the next dictation.
        if phase == .processing {
            phase = .idle
            overlay?.hide()
        }
    }

    private func pushLevel(_ level: CGFloat) {
        guard phase == .recording else { return }
        hudLevels.removeFirst()
        hudLevels.append(level)
    }

    /// System sound feedback (prototype: Tink on start, Pop on paste).
    private func play(_ name: String) {
        guard UserDefaults.standard.bool(forKey: Prefs.soundsEnabled) else { return }
        NSSound(named: name)?.play()
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
        // .window style turns the dropdown into a real SwiftUI panel
        // (MenuView) instead of a text-only menu.
        MenuBarExtra {
            MenuView(state: appState)
        } label: {
            Image(systemName: appState.phase.symbolName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
