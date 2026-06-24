import AppKit
import SwiftUI
import os

/// UserDefaults keys, shared between SettingsView (@AppStorage) and the
/// pipeline (reads at dictation time).
enum Prefs {
    static let hotkey = "hotkey"
    static let rewriteHotkey = "rewriteHotkey"  // HotkeyChoice rawValue or "off"
    static let soundsEnabled = "soundsEnabled"
    static let cleanupEnabled = "cleanupEnabled"
    static let cleanupPrompt = "cleanupPrompt"
    static let voiceCommands = "voiceCommands"
    static let memorySaverMinutes = "memorySaverMinutes"  // 0 = never unload
    static let customVocabulary = "customVocabulary"  // comma-separated words
    static let corrections = "corrections"  // [Correction] as JSON
}

/// What a hold of a hotkey means: plain dictation, or rewriting the
/// current selection per a spoken instruction.
enum DictationMode {
    case dictate
    case rewrite
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
    case unloaded
    case failed(String)

    var text: String {
        switch self {
        case .loading: "loading…"
        case .downloading(let percent): "downloading… \(percent)%"
        case .ready: "ready"
        case .unloaded: "unloaded (idle)"
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
    /// Whether the current hold is dictation or selection-rewrite — drives
    /// the HUD's wording and icon.
    var mode: DictationMode = .dictate
    /// Which stage of processing is actually running, for the HUD caption.
    enum ProcessingStep { case transcribing, cleaning }
    var processingStep: ProcessingStep = .transcribing

    /// Caption for the HUD's processing face, naming the stage that is
    /// actually running. "Transcribing…" would be a lie while a
    /// memory-saver-unloaded model reloads (the one genuinely slow step)
    /// or during the LLM cleanup pass (seconds on long dictations).
    var processingCaption: String {
        for status in [whisperStatus, cleanupStatus] {
            switch status {
            case .loading: return "Loading model…"
            case .downloading(let percent): return "Downloading model… \(percent)%"
            default: break
            }
        }
        if mode == .rewrite { return "Rewriting…" }
        return processingStep == .cleaning ? "Cleaning up…" : "Transcribing…"
    }

    /// Stage timings land in the unified system log (Console.app, or
    /// `log show --predicate 'subsystem == "Kyler-Zheng.PushToTalk"'`) —
    /// print() is invisible outside Xcode, which made slowness reports
    /// undiagnosable. Numbers only, never transcript content: the unified
    /// log persists to disk, and transcripts must not outlive the process.
    private static let log = Logger(
        subsystem: "Kyler-Zheng.PushToTalk", category: "pipeline")

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
    /// Selection capture kicked off at rewrite-key press; awaited by the
    /// rewrite pipeline after release.
    @ObservationIgnored private var selectionTask: Task<String?, Never>?
    /// The app that was frontmost when the current hold began — i.e. where
    /// the user means the text to go. Captured at key-down, snapshotted into
    /// each pipeline at key-up, and re-focused right before the paste so a
    /// slow transcription can't drop the text into whatever window the user
    /// drifted to while waiting.
    @ObservationIgnored private var targetApp: NSRunningApplication?
    /// Memory saver bookkeeping.
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var idleTimer: Timer?

    func start() {
        UserDefaults.standard.register(defaults: [
            Prefs.soundsEnabled: true,
            Prefs.cleanupEnabled: true,
            Prefs.rewriteHotkey: HotkeyChoice.rightCommand.rawValue,
            Prefs.memorySaverMinutes: 15,
        ])

        if let raw = UserDefaults.standard.string(forKey: Prefs.hotkey),
           let choice = HotkeyChoice(rawValue: raw) {
            hotkey.hotkey = choice
            hotkeyLabel = choice.label
        }
        if let raw = UserDefaults.standard.string(forKey: Prefs.rewriteHotkey) {
            hotkey.rewriteHotkey = HotkeyChoice(rawValue: raw)  // nil for "off"
        }
        hotkey.onPress = { [weak self] in self?.beginDictation() }
        hotkey.onRelease = { [weak self] in self?.endDictation() }
        hotkey.onRewritePress = { [weak self] in self?.beginRewrite() }
        hotkey.onRewriteRelease = { [weak self] in self?.endRewrite() }
        hotkeyReady = hotkey.start()

        // Memory saver: check once a minute whether the models have sat
        // idle long enough to be worth their ~4 GB.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            DispatchQueue.main.async { AppState.shared.checkIdleUnload() }
        }

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

    func setRewriteHotkey(_ raw: String) {
        hotkey.rewriteHotkey = HotkeyChoice(rawValue: raw)  // nil for "off"
        UserDefaults.standard.set(raw, forKey: Prefs.rewriteHotkey)
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
        // Ignore if the other hotkey already has a recording going.
        guard phase != .recording else { return }
        mode = .dictate
        // Snapshot where the user is *now* — we're a background agent, so
        // pressing the hotkey doesn't steal frontmost from their target app.
        // This is where the paste must land, however long transcription takes.
        targetApp = NSWorkspace.shared.frontmostApplication
        lastActivity = Date()
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
        guard phase == .recording, mode == .dictate else { return }
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
        processingStep = .transcribing
        phase = .processing
        // Snapshot per-pipeline: if the user fires another dictation while
        // this one is still transcribing, beginDictation overwrites
        // targetApp — carry our own copy into the task so the paste returns
        // to the right window.
        let target = targetApp
        pipelineTask = Task { [previous = pipelineTask] in
            // Serialization point: wait for the previous dictation's
            // pipeline before starting ours.
            _ = await previous?.result
            await self.process(samples, target: target)
        }
    }

    private func process(_ samples: [Float], target: NSRunningApplication?) async {
        do {
            // A memory-saver-unloaded model reloads inside transcribe();
            // reflect that in the menu instead of looking frozen.
            if case .unloaded = whisperStatus { whisperStatus = .loading }
            var started = Date()
            var text = try await transcriber.transcribe(
                samples,
                vocabulary: UserDefaults.standard.string(forKey: Prefs.customVocabulary))
            whisperStatus = .ready
            let whisperTime = Date().timeIntervalSince(started)
            // Learned corrections run before everything downstream — voice
            // command matching and cleanup both see the fixed text.
            text = CorrectionStore.apply(to: text)
            if text.isEmpty {
                // Whisper on borderline audio: skip rather than paste junk.
                print("  (empty transcript)")
            } else if let command = VoiceCommandStore.match(text) {
                // Voice command: paste the mapped text instead of the
                // transcript; cleanup is skipped (it's a command, not prose).
                print("  voice command: \"\(text)\" → \"\(command.replacement)\""
                      + (command.pressReturn ? " ⏎" : ""))
                let duration = Double(samples.count) / AudioRecorder.sampleRate
                history.insert(
                    DictationRecord(text: command.replacement, date: Date(), duration: duration),
                    at: 0)
                if history.count > 20 { history.removeLast(history.count - 20) }

                if !paster.hasPermission {
                    print("  (paste skipped: Accessibility not granted)")
                    pasteReady = false
                } else {
                    finishProcessing()
                    await paster.paste(command.replacement, into: target)
                    if command.pressReturn { paster.pressReturn() }
                    play("Pop")
                }
            } else {
                print(String(format: "  whisper [%.2fs]: \"%@\"", whisperTime, text))
                let audioSeconds = Double(samples.count) / AudioRecorder.sampleRate

                // Short utterances paste raw — keeps them instant
                // (prototype: CLEANUP_MIN_WORDS).
                let words = text.split(whereSeparator: \.isWhitespace).count
                Self.log.notice("whisper: \(whisperTime, format: .fixed(precision: 2))s for \(audioSeconds, format: .fixed(precision: 1))s of audio, \(words) words")
                let defaults = UserDefaults.standard
                if defaults.bool(forKey: Prefs.cleanupEnabled), words >= Cleaner.minWords {
                    if case .unloaded = cleanupStatus { cleanupStatus = .loading }
                    processingStep = .cleaning
                    started = Date()
                    do {
                        let prompt = defaults.string(forKey: Prefs.cleanupPrompt)
                            ?? Cleaner.systemPrompt
                        text = try await cleaner.cleanup(text, prompt: prompt)
                        cleanupStatus = .ready
                        print(String(format: "  cleanup [%.2fs]: \"%@\"",
                                     Date().timeIntervalSince(started), text))
                    } catch {
                        // Cleanup is best-effort; the transcript still lands.
                        print("  cleanup failed (pasting raw): \(error)")
                    }
                    Self.log.notice("cleanup: \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s for \(words) words")
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
                    Self.log.notice("pasting \(text.count) chars")
                    finishProcessing()
                    await paster.paste(text, into: target)
                    play("Pop")
                }
            }
        } catch {
            print("  transcription failed: \(error)")
            Self.log.error("transcription failed: \(error)")
        }
        // Don't clobber the phase (or the HUD) if the user is already
        // holding the key for the next dictation.
        if phase == .processing {
            phase = .idle
            overlay?.hide()
        }
        lastActivity = Date()
    }

    /// Ends the user-visible part of a dictation the moment the paste is
    /// about to post — paste() keeps running ~0.4 s after Cmd+V to restore
    /// the clipboard, and holding the "Transcribing…" pill through that
    /// delay made every dictation feel slower than it was. The pipeline
    /// task itself keeps running; the next dictation still serializes
    /// behind the restore.
    private func finishProcessing() {
        if phase == .processing {
            phase = .idle
            overlay?.hide()
        }
        lastActivity = Date()
    }

    // MARK: Rewrite mode

    private func beginRewrite() {
        guard phase != .recording else { return }
        mode = .rewrite
        targetApp = NSWorkspace.shared.frontmostApplication
        lastActivity = Date()
        phase = .recording
        hudLevels = Self.restingLevels
        play("Tink")

        // Snapshot the selection now, while we record the instruction —
        // by release time both are ready.
        selectionTask = Task { await self.paster.captureSelection() }

        do {
            try recorder.start()
        } catch {
            print("recorder failed to start: \(error)")
        }

        if overlay == nil { overlay = OverlayPanel(state: self) }
        overlay?.show()
    }

    private func endRewrite() {
        guard phase == .recording, mode == .rewrite else { return }
        let samples = recorder.stop()

        let duration = Double(samples.count) / AudioRecorder.sampleRate
        guard duration >= Self.minRecordSeconds else {
            print(String(format: "  (ignored %.2fs rewrite tap)", duration))
            phase = .idle
            overlay?.hide()
            return
        }

        phase = .processing
        let selection = selectionTask
        let target = targetApp
        pipelineTask = Task { [previous = pipelineTask] in
            _ = await previous?.result
            await self.processRewrite(samples, selection: await selection?.value, target: target)
        }
    }

    private func processRewrite(_ samples: [Float], selection: String?, target: NSRunningApplication?) async {
        do {
            if case .unloaded = whisperStatus { whisperStatus = .loading }
            let instruction = CorrectionStore.apply(
                to: try await transcriber.transcribe(
                    samples,
                    vocabulary: UserDefaults.standard.string(forKey: Prefs.customVocabulary)))
            whisperStatus = .ready
            guard !instruction.isEmpty else {
                print("  (rewrite: empty instruction)")
                return finishRewrite()
            }
            guard let selection, !selection.isEmpty else {
                print("  (rewrite: no text selected)")
                return finishRewrite()
            }
            print("  rewrite: \"\(instruction)\" on \(selection.count) chars")

            if case .unloaded = cleanupStatus { cleanupStatus = .loading }
            let started = Date()
            guard let rewritten = try await cleaner.rewrite(selection, instruction: instruction) else {
                cleanupStatus = .ready
                print("  (rewrite refused by rails — leaving text unchanged)")
                return finishRewrite()
            }
            cleanupStatus = .ready
            print(String(format: "  rewrite [%.2fs]: \"%@\"",
                         Date().timeIntervalSince(started), rewritten))

            history.insert(
                DictationRecord(text: rewritten, date: Date(),
                                duration: Double(samples.count) / AudioRecorder.sampleRate),
                at: 0)
            if history.count > 20 { history.removeLast(history.count - 20) }

            if !paster.hasPermission {
                print("  (paste skipped: Accessibility not granted)")
                pasteReady = false
            } else {
                finishRewrite()
                // The original selection is still highlighted in the target
                // app, so this paste replaces it.
                await paster.paste(rewritten, into: target)
                play("Pop")
            }
        } catch {
            print("  rewrite failed: \(error)")
            Self.log.error("rewrite failed: \(error)")
        }
        finishRewrite()
    }

    private func finishRewrite() {
        if phase == .processing {
            phase = .idle
            overlay?.hide()
        }
        mode = .dictate
        lastActivity = Date()
    }

    // MARK: Learning from fixes

    /// Called when the user saves an edited transcript from the menu's
    /// history. The diff against the original becomes correction rules
    /// (applied to every future transcript), and corrected words that carry
    /// capitals feed the custom vocabulary so Whisper starts expecting them.
    func saveFix(for record: DictationRecord, editedText: String) {
        let edited = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !edited.isEmpty else { return }

        let pairs = CorrectionStore.extract(from: record.text, to: edited)
        if !pairs.isEmpty {
            var all = CorrectionStore.load()
            for pair in pairs {
                if let index = all.firstIndex(where: {
                    $0.heard.caseInsensitiveCompare(pair.heard) == .orderedSame
                }) {
                    // Re-fixing the same mishearing: the latest fix wins.
                    all[index].corrected = pair.corrected
                } else {
                    all.append(pair)
                }
            }
            CorrectionStore.save(all)
            addToVocabulary(CorrectionStore.vocabularyCandidates(in: pairs))
        }

        // Reflect the fix in the menu so the row shows what it should have
        // said (and copy copies the good version).
        if let index = history.firstIndex(where: { $0.id == record.id }) {
            history[index] = DictationRecord(
                text: edited, date: record.date, duration: record.duration)
        }
    }

    private func addToVocabulary(_ words: [String]) {
        guard !words.isEmpty else { return }
        let defaults = UserDefaults.standard
        let vocabulary = defaults.string(forKey: Prefs.customVocabulary) ?? ""
        let existing = Set(vocabulary
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let new = words.filter { !existing.contains($0.lowercased()) }
        guard !new.isEmpty else { return }

        let addition = new.joined(separator: ", ")
        defaults.set(
            vocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? addition : "\(vocabulary), \(addition)",
            forKey: Prefs.customVocabulary)
    }

    // MARK: Memory saver

    /// Unload resident models after the configured idle period; the next
    /// dictation's ensureLoaded() brings them back transparently (paying a
    /// few seconds, once). A deliberate, user-configurable exception to
    /// Gotcha 8's models-stay-resident rule.
    func checkIdleUnload() {
        let minutes = UserDefaults.standard.integer(forKey: Prefs.memorySaverMinutes)
        guard minutes > 0, phase == .idle,
              Date().timeIntervalSince(lastActivity) > Double(minutes) * 60
        else { return }

        var unloadWhisper = false, unloadCleaner = false
        if case .ready = whisperStatus { unloadWhisper = true }
        if case .ready = cleanupStatus { unloadCleaner = true }
        guard unloadWhisper || unloadCleaner else { return }

        print("(memory saver: unloading models after \(minutes) min idle)")
        Self.log.notice("memory saver: unloading models after \(minutes) min idle — next dictation pays a reload")
        if unloadWhisper { whisperStatus = .unloaded }
        if unloadCleaner { cleanupStatus = .unloaded }
        Task {
            if unloadWhisper { await transcriber.unload() }
            if unloadCleaner { await cleaner.unload() }
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
