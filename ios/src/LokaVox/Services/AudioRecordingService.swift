@preconcurrency import AVFoundation
import Foundation
import os

/// Records microphone audio at 16 kHz mono Float32 — Whisper's native format.
/// Intentionally minimal for step 2: start, stop, return samples.
/// Flow mode, audio-level metering, silence detection, and pause/resume
/// are added in later steps.
///
/// Interruption handling is present from the start (CLAUDE.md rule #6):
/// on interruption the engine stops and any partial audio is discarded.
/// The caller observes the failure via the delegate callback.
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

    private var isRecording = false

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

    // MARK: - Recording

    func start() async throws {
        guard !isRecording else { return }

        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw RecordingError.permissionDenied
        }

        // Configure the session. `.record` is enough for step 2; no playback mixing yet.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: [])
        } catch {
            throw RecordingError.sessionConfigurationFailed(error.localizedDescription)
        }

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

        samplesLock.withLock { $0.removeAll(keepingCapacity: true) }

        // Install input tap. Tap callback runs on an AVFoundation thread; we do not hop.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            self?.process(inputBuffer: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw RecordingError.engineStartFailed(error.localizedDescription)
        }

        isRecording = true
    }

    /// Stop recording and return the accumulated 16 kHz mono Float32 samples.
    /// Deactivates the audio session.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        let out = samplesLock.withLock { state -> [Float] in
            let copy = state
            state.removeAll(keepingCapacity: false)
            return copy
        }

        converter = nil
        targetFormat = nil

        return out
    }

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
                _ = self.stop()
                if let handler = self.onInterruption {
                    Task { @MainActor in handler() }
                }
            case .ended:
                // Do nothing — step 2 does not auto-resume; user re-taps record.
                break
            @unknown default:
                break
            }
        }
    }
}
