@preconcurrency import AVFoundation
import Foundation
import os

/// Records microphone audio at 16 kHz mono Float32 — Whisper's native format.
///
/// Two usage modes:
///
/// 1. **End-to-end (step 2 / 3 URL-bounce path)** — `start()` acquires
///    everything and begins capturing; `stop()` returns samples and tears
///    the session down.
/// 2. **Split lifecycle (step 4 Flow mode)** — `startEngine()` acquires the
///    audio session + starts the engine but captures nothing. `installTap()`
///    begins capturing; `drainSamples()` removes the tap and returns audio;
///    `stopEngine()` releases the session. The engine stays running between
///    segments inside a Flow window so first-sample latency is minimal.
///
/// Interruption handling is present from the start (CLAUDE.md rule #6):
/// on interruption the engine stops and any partial audio is discarded.
/// The caller observes the failure via the `onInterruption` callback.
final class AudioRecordingService: @unchecked Sendable {

    enum RecordingError: LocalizedError {
        case permissionDenied
        case sessionConfigurationFailed(String)
        case engineStartFailed(String)
        case converterUnavailable
        case interrupted

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone permission is required. Enable it in Settings."
            case .sessionConfigurationFailed(let message):
                return "Audio session failed: \(message)"
            case .engineStartFailed(let message):
                return "Audio engine failed to start: \(message)"
            case .converterUnavailable:
                return "Could not create audio converter to 16 kHz mono."
            case .interrupted:
                return "Recording was interrupted by another app or a call."
            }
        }
    }

    /// Fired if the session is interrupted (call, Siri, another app). Invoked on the main thread.
    var onInterruption: (@MainActor @Sendable () -> Void)?

    private let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    private let samplesLock = OSAllocatedUnfairLock<[Float]>(initialState: [])

    /// Engine is running + audio session is active. A tap may or may not
    /// be installed; see `isTapInstalled`.
    private var isEngineRunning = false
    /// A tap is installed on the input node and samples are flowing into
    /// `samplesLock`.
    private var isTapInstalled = false

    // Configured once when the first recording starts.
    private var interruptionObserver: NSObjectProtocol?

    init() {
        registerForInterruptions()
    }

    deinit {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Permission

    /// Request microphone permission. Returns true if granted.
    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: - Recording — end-to-end (step 2 / 3 URL-bounce path)

    /// Acquire everything and begin capturing in one call. Symmetric with
    /// `stop()`. Used by the step-3 URL-bounce flow where one tap = one
    /// recording.
    func start() async throws {
        try await startEngine()
        try installTap()
    }

    /// Stop capturing, tear down the engine + session, return samples.
    func stop() -> [Float] {
        let samples = drainSamples()
        stopEngine()
        return samples
    }

    // MARK: - Recording — split lifecycle (step 4 Flow mode)

    /// Acquire the audio session and start the engine without installing a
    /// tap. After this returns, the engine is running and the mic hardware
    /// is active but no samples are being captured. Call `installTap()` to
    /// begin a segment.
    func startEngine() async throws {
        guard !isEngineRunning else { return }

        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw RecordingError.permissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        do {
            // `.default` mode rather than `.measurement`. `.measurement`
            // disables iOS's signal-processing stack (AGC, noise-suppress,
            // echo-cancel) — good on paper for whisper, but brittle in
            // practice: it rejects some device + BT routing configurations
            // and the engine throws CoreAudio error 2003329396 on start.
            // `.default` is permissive and whisper handles mild iOS AGC fine.
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch {
            throw RecordingError.sessionConfigurationFailed(error.localizedDescription)
        }

        // Reset the engine before reuse. When the same AVAudioEngine
        // instance has been started + stopped across multiple session
        // reconfigurations, the input node caches stale format state and
        // engine.start() throws 2003329396. `reset()` clears that cache.
        engine.reset()

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecordingError.converterUnavailable
        }
        self.targetFormat = targetFormat

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw RecordingError.converterUnavailable
        }
        self.converter = converter

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Retry once after a short delay — CoreAudio sometimes returns
            // transient errors when the audio route is still settling after
            // setActive. If the second attempt also fails, give up with the
            // original error.
            try? await Task.sleep(nanoseconds: 200_000_000)
            engine.reset()
            engine.prepare()
            do {
                try engine.start()
            } catch {
                throw RecordingError.engineStartFailed(error.localizedDescription)
            }
        }

        isEngineRunning = true
    }

    /// Stop the engine and deactivate the audio session. If a tap is still
    /// installed, pending samples are discarded.
    func stopEngine() {
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
            samplesLock.withLock { $0.removeAll(keepingCapacity: false) }
        }

        guard isEngineRunning else { return }
        isEngineRunning = false

        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        converter = nil
        targetFormat = nil
    }

    /// Install the input tap and start accumulating samples. Requires the
    /// engine to be running (`startEngine()` first). Resets any previously
    /// captured samples.
    func installTap() throws {
        guard isEngineRunning else {
            throw RecordingError.engineStartFailed("Engine is not running.")
        }
        guard !isTapInstalled else { return }

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        samplesLock.withLock { $0.removeAll(keepingCapacity: true) }

        // Tap callback runs on an AVFoundation thread; we do not hop.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            self?.process(inputBuffer: buffer)
        }
        isTapInstalled = true
    }

    /// Remove the tap and return the accumulated 16 kHz mono Float32 samples.
    /// The engine stays running — ready for the next segment. Safe to call
    /// even if no tap is installed (returns `[]`).
    func drainSamples() -> [Float] {
        guard isTapInstalled else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false

        return samplesLock.withLock { state -> [Float] in
            let copy = state
            state.removeAll(keepingCapacity: false)
            return copy
        }
    }

    /// True while the engine is running (between `startEngine()` and
    /// `stopEngine()`). FlowSessionManager reads this to know whether it
    /// needs a fresh acquisition.
    var engineIsRunning: Bool { isEngineRunning }

    /// True while samples are actively being captured.
    var tapIsInstalled: Bool { isTapInstalled }

    // MARK: - Private

    /// Convert a hardware-format PCM buffer to 16 kHz mono Float32 and append to `samples`.
    private func process(inputBuffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }

        // Output capacity estimate: input frames scaled by the sample-rate ratio, rounded up.
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 1024)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else { return }

        // One-shot flag: the input block must return the buffer exactly once per call
        // to avoid an infinite loop inside AVAudioConverter. This is a standard
        // AVAudioConverter idiom. Locked because AVAudioConverterInputBlock is
        // @Sendable under Swift 6 strict concurrency.
        let deliveredFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            let shouldDeliver = deliveredFlag.withLock { delivered -> Bool in
                if delivered { return false }
                delivered = true
                return true
            }
            if !shouldDeliver {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return inputBuffer
        }

        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
        guard status != .error, conversionError == nil else { return }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0, let channel = outputBuffer.floatChannelData?[0] else { return }

        let newSamples = Array(UnsafeBufferPointer(start: channel, count: frameCount))

        samplesLock.withLock { $0.append(contentsOf: newSamples) }
    }

    private func registerForInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let info = notification.userInfo,
                  let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else {
                return
            }

            switch type {
            case .began:
                // Discard partial audio; let caller know we lost the session.
                // stopEngine() also yanks any installed tap, so a Flow-mode
                // in-progress segment is cleanly torn down.
                self.stopEngine()
                if let handler = self.onInterruption {
                    Task { @MainActor in handler() }
                }
            case .ended:
                // Do nothing — step 2/3/4 do not auto-resume; user re-taps mic.
                break
            @unknown default:
                break
            }
        }
    }
}
