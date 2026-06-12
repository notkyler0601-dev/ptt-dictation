import Foundation
// @preconcurrency: WhisperKit hasn't adopted Sendable annotations yet, so
// without this every hand-off of the pipeline across our actor boundary
// warns. It relaxes exactly those checks for this one module's types.
@preconcurrency import WhisperKit

/// WhisperKit wrapper. Loads once at launch and stays resident (Gotcha 8);
/// the per-dictation latency budget assumes a warm model.
///
/// An `actor` (not a class): all of its state is touched from whatever
/// threads the async pipeline runs on, and actor isolation makes those
/// accesses safe without manual locks. This also opts it out of the
/// target's default MainActor isolation — model loading and inference
/// must never run on the UI thread.
actor Transcriber {
    /// OpenAI's large-v3-turbo. In the argmaxinc/whisperkit-coreml repo
    /// this lives under its release date, "large-v3-v20240930" — the repo's
    /// own "_turbo"-suffixed folders are a different thing (WhisperKit's
    /// compressed variants of older models), so don't "fix" this name.
    static let modelName = "large-v3-v20240930"

    enum TranscriberError: Error {
        case notLoaded
    }

    /// UserDefaults key for the model folder the first successful load
    /// resolved. Later loads (next launch, or a reload after the memory
    /// saver unloads) go straight to this folder — loading from an explicit
    /// folder never touches the network.
    private static let cachedFolderKey = "whisperModelFolder"

    /// The resident pipeline. Stays inside the actor; a non-Sendable type
    /// that never crosses an isolation boundary needs no Sendable proof.
    private var pipe: WhisperKit?
    /// "Load in progress" latch — every early caller awaits the same task,
    /// so concurrent first calls can't trigger two downloads.
    private var loading: Task<Void, Error>?

    /// Kick off (or join) the one-time model load. First run downloads
    /// ~1.5 GB from Hugging Face and compiles for the Neural Engine (can
    /// take a few minutes); later launches load from cache in seconds.
    /// `progress` reports download fraction (0–1), from a background thread.
    func warmLoad(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await ensureLoaded(progress: progress)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await ensureLoaded()
        guard let pipe else { throw TranscriberError.notLoaded }
        let results = try await pipe.transcribe(audioArray: samples)
        // One result per ~30 s Whisper window; short dictations yield one.
        return results.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Memory saver: drop the resident pipeline (~1.5 GB back to the OS).
    /// The next transcribe() reloads from disk cache automatically via
    /// ensureLoaded — a few seconds, once.
    func unload() {
        pipe = nil
        loading = nil
    }

    private func ensureLoaded(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        if pipe != nil { return }
        if loading == nil {
            // Task {} inside an actor inherits its isolation, so writing
            // self.pipe from the task body is actor-safe.
            loading = Task {
                self.pipe = try await Self.loadPipeline(progress: progress)
            }
        }
        do {
            try await loading?.value
        } catch {
            // Failed load (e.g. no network on first run): clear so a later
            // dictation can retry instead of being stuck with a dead task.
            loading = nil
            throw error
        }
    }

    private static func loadPipeline(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> WhisperKit {
        let defaults = UserDefaults.standard

        // Fast path: a previous load already resolved the model folder.
        // WhisperKit.download "skips" cached files but still does a Hugging
        // Face listing round-trip to decide that — on a slow or flaky
        // connection that check stalled every post-memory-saver reload,
        // leaving dictations stuck on "Transcribing…". An explicit folder
        // skips the hub entirely.
        if let cached = defaults.string(forKey: cachedFolderKey),
           FileManager.default.fileExists(atPath: cached) {
            let config = WhisperKitConfig(model: modelName, prewarm: true)
            config.modelFolder = cached
            do {
                return try await WhisperKit(config)
            } catch {
                // Folder went stale (partial delete, WhisperKit layout
                // change): forget it and fall through to a fresh download.
                print("whisper cached-folder load failed, redownloading: \(error)")
                defaults.removeObject(forKey: cachedFolderKey)
            }
        }

        let config = WhisperKitConfig(model: modelName, prewarm: true)
        // Download explicitly so we can surface progress. If the check
        // fails (e.g. offline with a full cache), fall back to letting
        // init resolve the model by name.
        do {
            let folder = try await WhisperKit.download(
                variant: modelName,
                progressCallback: { progress($0.fractionCompleted) }
            )
            config.modelFolder = folder.path
        } catch {
            print("whisper download check failed (trying cache): \(error)")
        }
        let pipe = try await WhisperKit(config)
        // Only remember the folder once a load from it has succeeded.
        if let folder = config.modelFolder {
            defaults.set(folder, forKey: cachedFolderKey)
        }
        return pipe
    }
}
