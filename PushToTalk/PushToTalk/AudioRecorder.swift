import AVFoundation
import Accelerate

/// Captures mic audio between hotkey press and release.
///
/// Mirrors the prototype's Recorder: the engine runs only while the key is
/// held, so the mic (and the orange privacy indicator) is live only during
/// dictation. Starting costs a few tens of ms — inaudible at speech pace.
final class AudioRecorder {
    /// Latest input level (0–1), called on the main thread per tap buffer
    /// (~10–12×/s). Drives the HUD bars.
    var onLevel: ((Float) -> Void)?

    /// Whisper's native input rate. Everything downstream assumes this.
    static let sampleRate: Double = 16_000

    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    // The tap callback runs on an internal audio queue while stop() is
    // called from main — guard the shared sample buffer.
    private let lock = NSLock()

    enum RecorderError: Error {
        case noInputFormat
    }

    /// Ask for mic access up front (at launch) so the system dialog doesn't
    /// eat the first dictation.
    func requestPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    func start() throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        // A 0 Hz native format means no usable input (typically mic
        // permission not granted yet) — AVAudioConverter would crash on it.
        guard native.sampleRate > 0,
              let converter = AVAudioConverter(from: native, to: Self.outputFormat)
        else { throw RecorderError.noInputFormat }
        // One converter per recording session: a sample-rate converter keeps
        // internal filter state between buffers, so the same instance must
        // see the whole stream for seam-free resampling.
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: native) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops the engine and returns everything captured, as 16 kHz mono
    /// Float32 — exactly what Whisper wants.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil

        lock.lock()
        defer { lock.unlock() }
        let captured = samples
        samples = []
        return captured
    }

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let converter, buffer.frameLength > 0 else { return }

        // Level for the HUD, from the raw buffer before any conversion.
        if let channel = buffer.floatChannelData?[0] {
            let rms = vDSP.rootMeanSquare(
                UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            // Speech RMS lives roughly in 0.01–0.3; scale so normal talking
            // visibly moves the bars and loud speech saturates.
            let level = min(1, rms * 10)
            DispatchQueue.main.async { self.onLevel?(level) }
        }

        // Convert this chunk to 16 kHz mono. The output buffer is freshly
        // allocated and ours; the *input* buffer belongs to the engine and is
        // reused after this callback returns (Gotcha 5), so all data must be
        // out of it before we return — which the convert call does.
        let ratio = Self.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 16
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return }

        var fed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            // Feed exactly this one buffer, then report "dry for now" (NOT
            // end-of-stream, which would flush the resampler's state and
            // click at every chunk boundary).
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }

        guard conversionError == nil,
              converted.frameLength > 0,
              let channel = converted.floatChannelData?[0]
        else { return }

        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(
            start: channel, count: Int(converted.frameLength)))
        lock.unlock()
    }
}
