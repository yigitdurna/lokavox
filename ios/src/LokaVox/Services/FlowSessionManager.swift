import Foundation
import Observation

/// Owns the 5-minute Flow window. Coordinates per-segment capture with
/// the already-running WhisperEngine, publishes state + heartbeat to the
/// App Group for the keyboard, and listens for keyboard Darwin signals.
///
/// Lifecycle:
///
///     cold → enterFlowFromURL() → .idle(flow-active)
///       ↔ beginSegment() → .recording
///       ↔ endSegmentAndTranscribe() → .transcribing → .idle
///     (5 min elapsed, interruption, or manual) → exitFlow() → cold
///
/// The main app stays un-suspended in background because `UIBackgroundModes: audio`
/// is set and the AVAudioSession is `.record`-active. That is what lets the
/// keyboard signal us without bouncing the user back.
@MainActor
@Observable
final class FlowSessionManager {

    enum State: Equatable {
        case inactive
        case idle
        case recording
        case transcribing
        case exiting
        case failed(String)
    }

    enum ExitReason: Equatable {
        case timeout
        case interruption
        case manual
        case error(String)
    }

    private(set) var state: State = .inactive
    private(set) var flowExpiresAt: Date?
    private(set) var lastTranscript: String = ""
    private(set) var lastLatencyMs: Int?
    /// Diagnostic snapshot from the last transcription attempt (success or
    /// failure). Used by the main-app UI to show the user what whisper.cpp
    /// actually produced — useful when the keyboard claims "inserted" but
    /// the host app looks blank.
    private(set) var lastEngineDiagnostics: WhisperEngine.Diagnostics?

    // MARK: - Tunables

    /// Hard cap on a single segment — protects against forgotten-open mic.
    static let segmentCapSeconds: TimeInterval = 60
    /// Heartbeat cadence while Flow is active.
    static let heartbeatIntervalSeconds: TimeInterval = 1.5

    /// Current Flow window length, pulled from user settings at entry /
    /// extension time. Falls back to 5 minutes if settings is unreachable.
    private var flowWindowSeconds: TimeInterval {
        settings.flowTimeout.seconds
    }

    // MARK: - Dependencies

    private let engine: WhisperEngine
    private let recorder: AudioRecordingService
    private let settings: LokaVoxSettings
    private let sessionStore: SessionStore

    // MARK: - Internal

    // Timers + observer storage. Only mutated on the main actor.
    // `@ObservationIgnored` excludes them from the `@Observable` macro
    // wrappers so access from explicit-teardown methods is straightforward.
    // Cleanup: we rely on ARC + each type's own deinit — dropping our strong
    // reference to `DarwinNotifier.Token` invokes its own `deinit` which
    // removes the CFNotificationCenter observer, and `DispatchSourceTimer`
    // stops firing when its last reference is released. All firing handlers
    // capture `[weak self]` so a late fire during dealloc is a no-op.
    @ObservationIgnored private var requestObserver: DarwinNotifier.Token?
    @ObservationIgnored private var heartbeatTimer: DispatchSourceTimer?
    @ObservationIgnored private var flowExpiryTimer: DispatchSourceTimer?
    @ObservationIgnored private var segmentCapTimer: DispatchSourceTimer?

    /// Latest generation counter read from SessionStore when a segment began.
    /// Used to tag the transcript write so the keyboard dedupes correctly.
    private var activeGeneration: Int?

    /// Fires when Flow exits for any reason — the view model uses this to
    /// clear URL-banner state. Set on the main actor.
    var onExit: ((ExitReason) -> Void)?

    // MARK: - Init

    init(
        engine: WhisperEngine,
        recorder: AudioRecordingService,
        settings: LokaVoxSettings,
        sessionStore: SessionStore
    ) {
        self.engine = engine
        self.recorder = recorder
        self.settings = settings
        self.sessionStore = sessionStore

        self.recorder.onInterruption = { [weak self] in
            guard let self else { return }
            self.handleInterruption()
        }

        self.requestObserver = DarwinNotifier.observe(DarwinNotifier.Name.flowRequest) { [weak self] in
            self?.handleFlowRequest()
        }
    }

    // MARK: - Entry

    /// Unified "user wants to start recording right now" entry. If Flow is
    /// inactive, acquire the audio session, start the engine, enter Flow,
    /// then begin the first segment. If Flow is already idle (warm), just
    /// begin a segment. Safe no-op if we're already mid-segment.
    ///
    /// Callers:
    /// - `LokaVoxApp.onOpenURL("lokavox://record")` — keyboard cold tap.
    /// - In-app record button in `ContentView`.
    ///
    /// - Returns: true if a segment is now in progress (or entered Flow
    ///   successfully). False means an unrecoverable error — caller should
    ///   surface it.
    @discardableResult
    func startSegment() async -> Bool {
        switch state {
        case .recording, .transcribing, .exiting:
            return true  // Already doing the thing.
        case .idle:
            await beginSegment()
            return true
        case .inactive, .failed:
            break  // Fall through to Flow entry.
        }

        let granted = await recorder.requestPermission()
        guard granted else {
            sessionStore.markError("Microphone permission denied.")
            state = .failed("Microphone permission denied.")
            return false
        }

        do {
            try await recorder.startEngine()
        } catch {
            sessionStore.markError(error.localizedDescription)
            state = .failed(error.localizedDescription)
            return false
        }

        let expires = Date().addingTimeInterval(flowWindowSeconds)
        flowExpiresAt = expires
        sessionStore.setFlowExpiresAt(expires)
        sessionStore.writeHeartbeat()
        startHeartbeat()
        scheduleFlowExpiry(at: expires)

        state = .idle
        await beginSegment()
        return true
    }

    // MARK: - Segment lifecycle

    /// Install the tap, transition to `.recording`, and publish state.
    func beginSegment() async {
        guard state == .idle else { return }

        let generation = sessionStore.generation
        activeGeneration = generation

        do {
            try recorder.installTap()
        } catch {
            sessionStore.markError(error.localizedDescription)
            state = .failed(error.localizedDescription)
            await exitFlow(reason: .error(error.localizedDescription))
            return
        }

        state = .recording
        sessionStore.mark(state: .recording)
        DarwinNotifier.post(DarwinNotifier.Name.flowState)

        scheduleSegmentCap()
    }

    /// Remove the tap, run Whisper, publish transcript + state, extend the
    /// Flow window. The engine stays running — we're still in Flow.
    func endSegmentAndTranscribe() async {
        guard state == .recording else { return }
        cancelSegmentCap()

        let samples = recorder.drainSamples()
        state = .transcribing
        sessionStore.mark(state: .transcribing)
        DarwinNotifier.post(DarwinNotifier.Name.flowState)

        guard !samples.isEmpty else {
            // Nothing captured — still publish `done` (empty) so the keyboard
            // clears its "transcribing" spinner, then stay in Flow.
            sessionStore.markDone(transcript: "")
            DarwinNotifier.post(DarwinNotifier.Name.flowState)
            completeSegment(transcript: "")
            return
        }

        let start = Date()
        do {
            // Model may still be loading (cold launch path where the user
            // started speaking before `bootstrap()` finished). Block here
            // rather than at segment start so the user can dictate while
            // the model warms up.
            let ready = await engine.waitForLoaded(timeout: 180)
            guard ready else {
                throw WhisperEngine.EngineError.notLoaded
            }

            let raw = try await engine.transcribe(
                audioSamples: samples,
                initialPrompt: settings.initialPrompt,
                languageCode: settings.language.whisperCode
            )
            lastEngineDiagnostics = await engine.snapshotDiagnostics()
            lastLatencyMs = Int(Date().timeIntervalSince(start) * 1000)
            let text = settings.postProcess(raw)
            lastTranscript = text
            sessionStore.markDone(transcript: text)
            DarwinNotifier.post(DarwinNotifier.Name.flowState)
            completeSegment(transcript: text)
        } catch {
            lastEngineDiagnostics = await engine.snapshotDiagnostics()
            sessionStore.markError(error.localizedDescription)
            DarwinNotifier.post(DarwinNotifier.Name.flowState)
            state = .failed(error.localizedDescription)
            await exitFlow(reason: .error(error.localizedDescription))
        }
    }

    /// After a successful (or empty) segment:
    /// - If Flow mode is enabled in settings, bump the Flow window and stay
    ///   warm in `.idle`.
    /// - If disabled, exit Flow immediately so the next keyboard tap goes
    ///   cold via `Link` (step-3 bounce-to-app behaviour).
    private func completeSegment(transcript _: String) {
        activeGeneration = nil

        guard settings.flowModeEnabled else {
            Task { [weak self] in
                await self?.exitFlow(reason: .manual)
            }
            return
        }

        let newExpiry = Date().addingTimeInterval(flowWindowSeconds)
        flowExpiresAt = newExpiry
        sessionStore.setFlowExpiresAt(newExpiry)
        scheduleFlowExpiry(at: newExpiry)
        state = .idle
    }

    // MARK: - Exit

    /// Manual or timeout/interruption exit. Tears down engine, clears Flow
    /// visibility, transitions to `.inactive`.
    func exitFlow(reason: ExitReason) async {
        // Idempotent — safe to call from multiple triggers.
        guard state != .inactive else { return }
        state = .exiting
        cancelSegmentCap()
        cancelFlowExpiry()
        cancelHeartbeat()

        if recorder.tapIsInstalled {
            _ = recorder.drainSamples()
        }
        if recorder.engineIsRunning {
            recorder.stopEngine()
        }

        flowExpiresAt = nil
        sessionStore.clearFlow()

        // If the last publishable state was mid-segment, surface the exit as
        // an error so the keyboard doesn't stay stuck on "recording…".
        if case .error(let msg) = reason {
            sessionStore.markError(msg)
        } else if reason == .interruption {
            sessionStore.markError("Recording was interrupted.")
        } else {
            // Clean timeout / manual — leave whatever the last segment wrote
            // (usually `done`) in place. Keyboard already inserted it.
            sessionStore.mark(state: .idle)
        }
        DarwinNotifier.post(DarwinNotifier.Name.flowState)

        state = .inactive
        onExit?(reason)
    }

    // MARK: - Darwin request handler

    /// Fired by DarwinNotifier when the keyboard posts `flow.request`.
    /// Coalescing-safe: we read the canonical state from SessionStore rather
    /// than inferring intent from fire count.
    private func handleFlowRequest() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let requested = self.sessionStore.state
            let currentGen = self.sessionStore.generation

            switch self.state {
            case .inactive, .exiting, .failed:
                // Flow has ended; nothing to do. Keyboard's next tap should
                // go via `Link` — but it may have posted before noticing the
                // heartbeat went stale. Mark error so UI clears cleanly.
                self.sessionStore.markError("Flow has ended — tap mic again to start fresh.")
                DarwinNotifier.post(DarwinNotifier.Name.flowState)
            case .idle:
                // Start a new segment if keyboard asked for `requested`.
                // Any other state from an idle main app = stale write; ignore.
                if requested == .requested, currentGen > 0 {
                    await self.beginSegment()
                }
            case .recording:
                // Second tap on the mic → stop. Keyboard writes
                // `stopRequested`, but accept `requested` too (double-tap
                // ambiguity — treat as "stop").
                if requested == .stopRequested || requested == .requested {
                    await self.endSegmentAndTranscribe()
                }
            case .transcribing:
                // Drop keyboard taps while Whisper is busy. Keyboard UI is
                // gated to disabled in this state anyway.
                break
            }
        }
    }

    private func handleInterruption() {
        Task { @MainActor [weak self] in
            await self?.exitFlow(reason: .interruption)
        }
    }

    // MARK: - Timers

    private func startHeartbeat() {
        cancelHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.heartbeatIntervalSeconds,
            repeating: Self.heartbeatIntervalSeconds
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.sessionStore.writeHeartbeat()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func cancelHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func scheduleFlowExpiry(at date: Date) {
        cancelFlowExpiry()
        let delay = max(0, date.timeIntervalSinceNow)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.exitFlow(reason: .timeout) }
        }
        timer.resume()
        flowExpiryTimer = timer
    }

    private func cancelFlowExpiry() {
        flowExpiryTimer?.cancel()
        flowExpiryTimer = nil
    }

    private func scheduleSegmentCap() {
        cancelSegmentCap()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.segmentCapSeconds)
        timer.setEventHandler { [weak self] in
            guard let self, self.state == .recording else { return }
            Task { await self.endSegmentAndTranscribe() }
        }
        timer.resume()
        segmentCapTimer = timer
    }

    private func cancelSegmentCap() {
        segmentCapTimer?.cancel()
        segmentCapTimer = nil
    }
}
