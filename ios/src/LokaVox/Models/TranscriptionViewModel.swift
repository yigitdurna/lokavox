import Foundation
import Observation

@MainActor
@Observable
final class TranscriptionViewModel {
    enum RecordingState: Equatable {
        case idle
        case recording
        case transcribing
    }

    let modelManager: ModelManagerService
    let settings: LokaVoxSettings
    let flow: FlowSessionManager

    /// Legacy convenience derived from `flow.state`. ContentView's record
    /// button uses this tri-state to drive label + colour.
    var recordingState: RecordingState {
        switch flow.state {
        case .recording: return .recording
        case .transcribing: return .transcribing
        case .inactive, .idle, .exiting, .failed: return .idle
        }
    }

    /// User-editable post-transcription. Binding-friendly so the main-app
    /// `TextEditor` can write directly. Edits propagate to the App Group so
    /// the keyboard inserts the *edited* version if it drains before the
    /// user swipes back.
    var transcript: String = "" {
        didSet {
            guard oldValue != transcript else { return }
            sessionStore.updateTranscript(transcript)
        }
    }

    private(set) var lastTranscribeLatencyMs: Int?
    private(set) var errorMessage: String?

    /// User-facing status set while servicing a `lokavox://record` URL or
    /// holding a warm Flow. The main-app UI shows this as a banner.
    private(set) var urlSessionStatus: String?

    private let engine: WhisperEngine
    private let recorder: AudioRecordingService
    private let sessionStore = SessionStore.shared()

    init() {
        let engine = WhisperEngine()
        let recorder = AudioRecordingService()
        let settings = LokaVoxSettings()
        let store = SessionStore.shared()

        self.engine = engine
        self.recorder = recorder
        self.settings = settings
        self.modelManager = ModelManagerService(engine: engine, settings: settings)
        self.flow = FlowSessionManager(
            engine: engine,
            recorder: recorder,
            settings: settings,
            sessionStore: store
        )

        self.flow.onExit = { [weak self] reason in
            self?.handleFlowExit(reason: reason)
        }
    }

    /// Re-initialise the whisper context with the current `settings.
    /// gpuAccelerationEnabled` value. Called from Settings when the user
    /// toggles the GPU switch.
    func reloadEngineForSettingsChange() async {
        await modelManager.reloadEngineForSettingsChange()
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        await modelManager.prepare()
    }

    // MARK: - URL-driven session entry

    /// Triggered by `LokaVoxApp.onOpenURL("lokavox://record")`. Enters Flow
    /// and starts capture *immediately*, without waiting for the model to be
    /// ready — the wait happens at transcribe time instead, which lets the
    /// user begin speaking while the model warms up. Subsequent keyboard
    /// taps bypass the URL and signal the running engine directly.
    func handleRecordRequest() async {
        urlSessionStatus = nil
        errorMessage = nil

        if case .failed(let msg) = modelManager.state {
            sessionStore.markError(msg)
            urlSessionStatus = "Model failed to load: \(msg)"
            return
        }

        let ok = await flow.startSegment()
        if ok {
            urlSessionStatus = "Recording — tap Stop when done, or keep using the LokaVox keyboard."
        } else if case .failed(let message) = flow.state {
            urlSessionStatus = message
        }

        observeFlowTranscriptSync()
    }

    // MARK: - Recording (in-app UI)

    /// In-app record button tap 1 — route through Flow. The model may still
    /// be loading; the transcribe step waits for readiness, not the start
    /// step, so the user can begin speaking immediately.
    func startRecording() async {
        if case .failed(let msg) = modelManager.state {
            errorMessage = msg
            return
        }
        errorMessage = nil
        let ok = await flow.startSegment()
        if !ok, case .failed(let message) = flow.state {
            errorMessage = message
        }
        observeFlowTranscriptSync()
    }

    /// In-app record button tap 2 — stop + transcribe via Flow. Stays warm.
    func stopAndTranscribe() async {
        await flow.endSegmentAndTranscribe()
        lastTranscribeLatencyMs = flow.lastLatencyMs
        syncTranscriptFromFlow()
    }

    /// Manual "End Flow" control — tears down engine, deactivates session.
    func endFlow() async {
        await flow.exitFlow(reason: .manual)
    }

    // MARK: - Flow → ViewModel sync

    /// Poll flow.lastTranscript into vm.transcript. Called at segment boundaries.
    private func syncTranscriptFromFlow() {
        let next = flow.lastTranscript
        if transcript != next {
            transcript = next
        }
    }

    /// One-shot observation bootstrap. Safe to call repeatedly.
    private var transcriptSyncObservationInstalled = false
    private func observeFlowTranscriptSync() {
        guard !transcriptSyncObservationInstalled else { return }
        transcriptSyncObservationInstalled = true
        Task { @MainActor [weak self] in
            // Simple pull loop at segment-end cadence. Cheap while Flow is
            // active. Terminates when Flow goes inactive and the view model
            // deallocates (weak self nil-check breaks the loop).
            while let self {
                if self.flow.state == .transcribing {
                    // Wait for endSegmentAndTranscribe to publish.
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    continue
                }
                self.syncTranscriptFromFlow()
                if self.flow.state == .inactive {
                    self.transcriptSyncObservationInstalled = false
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: - UI helpers

    func clearError() {
        errorMessage = nil
    }

    func clearURLSessionStatus() {
        urlSessionStatus = nil
    }

    // MARK: - Flow lifecycle

    private func handleFlowExit(reason: FlowSessionManager.ExitReason) {
        switch reason {
        case .timeout:
            urlSessionStatus = "Flow ended. Tap the keyboard mic to start a new session."
        case .interruption:
            errorMessage = "Recording was interrupted."
            urlSessionStatus = "Flow ended. Tap the keyboard mic to resume."
        case .manual:
            urlSessionStatus = nil
        case .error(let message):
            errorMessage = message
            urlSessionStatus = nil
        }
    }

    // MARK: - Background safeguard

    /// Step 4: if Flow is active, do nothing — `UIBackgroundModes: audio`
    /// keeps us alive intentionally so the keyboard can signal new segments.
    /// If Flow is NOT active (e.g. a cold URL-bounce segment without Flow
    /// entry), fall back to the step-3 stuck-mic safeguard.
    func handleAppBackgrounded() {
        if flow.state != .inactive {
            return  // Flow is load-bearing; don't tear it down.
        }
        // Pre-Flow or post-Flow-exit stray recording — kill it.
        if recorder.tapIsInstalled {
            _ = recorder.drainSamples()
        }
        if recorder.engineIsRunning {
            recorder.stopEngine()
        }
    }
}
