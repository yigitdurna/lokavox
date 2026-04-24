import SwiftUI
import UIKit

/// Step-4 keyboard controller. Supports two mic-tap paths:
///
/// - **Cold (Flow inactive)** — the mic is a SwiftUI `Link` to `lokavox://record`.
///   Tap bumps generation + launches the main app. Same as step 3.
/// - **Warm (Flow active)** — the main app is running in background with an
///   active audio session; the mic is a regular `Button` that posts a Darwin
///   notification (`com.lokavox.flow.request`) and toggles the App Group
///   `SessionState` between `requested` (start) and `stopRequested` (stop).
///   The main app reacts without the user ever bouncing back to LokaVox.
///
/// "Warm" is detected via `SessionStore.flowActive(now:)`: `flowExpiresAt >
/// now()` AND `heartbeatAt` within 3 s. If the main app is Jetsammed the
/// heartbeat goes stale and we fall back to cold.
final class KeyboardViewController: UIInputViewController {

    private let sessionStore = SessionStore.shared()
    private var host: UIHostingController<KeyboardView>!

    private var statusText: String = "Tap mic to dictate"
    private var micEnabled: Bool = true
    private var flowMode: KeyboardView.FlowMode = .cold
    private var flowRemainingSeconds: Int?

    /// Backup poll task — runs as a belt-and-braces fallback when a Darwin
    /// notification is missed (coalescing, suspended app, etc.). Cheap.
    nonisolated(unsafe) private var pollTask: Task<Void, Never>?
    nonisolated(unsafe) private var flowCountdownTask: Task<Void, Never>?
    private var flowStateObserver: DarwinNotifier.Token?

    private static let lastInsertedGenerationKey = "lokavox.keyboard.lastInsertedGeneration"
    private static let pollIntervalSeconds: TimeInterval = 0.5
    private static let pollTimeoutSeconds: TimeInterval = 20

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        let view = buildKeyboardView()
        host = UIHostingController(rootView: view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addChild(host)
        self.view.addSubview(host.view)
        host.didMove(toParent: self)

        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])

        let heightConstraint = self.view.heightAnchor.constraint(equalToConstant: 260)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true

        // Darwin state observer: main app fires this on any Flow transition.
        flowStateObserver = DarwinNotifier.observe(DarwinNotifier.Name.flowState) { [weak self] in
            self?.refreshAll()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshAll()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshAll()
        startCountdownIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPolling()
        stopCountdown()
    }

    deinit {
        pollTask?.cancel()
        flowCountdownTask?.cancel()
        flowStateObserver?.cancel()
    }

    // MARK: - SwiftUI wiring

    private func buildKeyboardView() -> KeyboardView {
        KeyboardView(
            flowMode: flowMode,
            onMicPreTap: { [weak self] in self?.handleMicPreTap() },
            onMicWarmStart: { [weak self] in self?.handleMicWarmStart() },
            onMicWarmStop: { [weak self] in self?.handleMicWarmStop() },
            onDeleteTap: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            onSpaceTap: { [weak self] in self?.textDocumentProxy.insertText(" ") },
            onReturnTap: { [weak self] in self?.textDocumentProxy.insertText("\n") },
            status: statusText,
            micEnabled: micEnabled,
            flowRemainingSeconds: flowRemainingSeconds
        )
    }

    private func refreshHost() {
        host?.rootView = buildKeyboardView()
    }

    private func setStatus(_ text: String) {
        statusText = text
        refreshHost()
    }

    private func setMicEnabled(_ enabled: Bool) {
        micEnabled = enabled
        refreshHost()
    }

    // MARK: - Unified refresh

    /// Compute full keyboard state from SessionStore + access flags. Runs on
    /// every viewWillAppear / viewDidAppear, after every Darwin notification,
    /// and on each poll tick.
    private func refreshAll() {
        // Full Access gating first — without it, nothing else matters.
        let pasteboardReadable = UIPasteboard.general.hasStrings || UIPasteboard.general.string != nil
        let observed = pasteboardReadable || hasFullAccess || sessionStore.hasFullAccessObserved
        if pasteboardReadable || hasFullAccess {
            sessionStore.setFullAccessObserved(true)
        }
        guard observed else {
            flowMode = .cold
            flowRemainingSeconds = nil
            micEnabled = false
            statusText = "Open the LokaVox app to grant Full Access"
            refreshHost()
            return
        }

        // Flow-active gating.
        let flowOn = sessionStore.flowActive()
        let state = sessionStore.state
        let generation = sessionStore.generation

        if flowOn {
            // We may have just received a state notification — drain any
            // pending done transcript first.
            if state == .done, generation > 0, generation != lastInsertedGeneration {
                insertDoneTranscript(generation: generation)
            }

            switch sessionStore.state {
            case .idle, .done:
                flowMode = .warmIdle
                statusText = "Tap mic — Flow is warm"
                micEnabled = true
            case .requested:
                flowMode = .warmRecording
                statusText = "Starting…"
                micEnabled = true
            case .recording:
                flowMode = .warmRecording
                statusText = "Recording… tap to stop"
                micEnabled = true
            case .stopRequested, .transcribing:
                flowMode = .warmTranscribing
                statusText = "Transcribing…"
                micEnabled = false
            case .error:
                // Something went wrong mid-flow — surface it, revert to cold.
                flowMode = .cold
                statusText = sessionStore.error.map { "Error: \($0)" } ?? "Error"
                micEnabled = true
            }
            flowRemainingSeconds = sessionStore.flowExpiresAt.map {
                max(0, Int($0.timeIntervalSinceNow))
            }
        } else {
            flowMode = .cold
            flowRemainingSeconds = nil
            micEnabled = true

            // Same cold drain logic as step 3.
            switch state {
            case .done:
                if generation > 0, generation != lastInsertedGeneration {
                    insertDoneTranscript(generation: generation)
                }
                stopPolling()
            case .error:
                if generation > 0, generation != lastInsertedGeneration {
                    let message = sessionStore.error ?? "Unknown error"
                    statusText = "Error: \(message)"
                    lastInsertedGeneration = generation
                }
                stopPolling()
            case .requested, .recording, .transcribing:
                statusText = statusFor(state: state)
                startPollingIfNeeded()
            case .idle, .stopRequested:
                if generation == lastInsertedGeneration || generation == 0 {
                    statusText = "Tap mic to dictate"
                }
            }
        }

        refreshHost()
    }

    // MARK: - Cold path (step 3 Link bounce)

    /// Fires *before* the SwiftUI Link navigates. Bumps the App Group
    /// generation so the main app reads a fresh session on foreground.
    private func handleMicPreTap() {
        stopPolling()
        _ = sessionStore.bumpGenerationAndMarkRequested()
        setStatus("Opening LokaVox…")
    }

    // MARK: - Warm path (step 4 Darwin)

    /// Flow active, mic idle → start a new segment without leaving the host app.
    private func handleMicWarmStart() {
        _ = sessionStore.bumpGenerationAndMarkRequested()
        DarwinNotifier.post(DarwinNotifier.Name.flowRequest)
        flowMode = .warmRecording
        statusText = "Starting…"
        refreshHost()
    }

    /// Flow active, recording → stop current segment.
    private func handleMicWarmStop() {
        sessionStore.markStopRequested()
        DarwinNotifier.post(DarwinNotifier.Name.flowRequest)
        flowMode = .warmTranscribing
        statusText = "Transcribing…"
        micEnabled = false
        refreshHost()
    }

    // MARK: - Transcript insertion

    private var lastInsertedGeneration: Int {
        get { UserDefaults.standard.integer(forKey: Self.lastInsertedGenerationKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastInsertedGenerationKey) }
    }

    private func insertDoneTranscript(generation: Int) {
        let transcript = sessionStore.transcript
        let latencyText = latencyDescription()

        if transcript.isEmpty {
            setStatus("No speech captured")
        } else {
            textDocumentProxy.insertText(transcript)
            setStatus(latencyText.map { "Inserted in \($0)" } ?? "Inserted")
        }
        lastInsertedGeneration = generation
    }

    private func statusFor(state: SessionState) -> String {
        switch state {
        case .requested: return "Opening LokaVox…"
        case .recording: return "Recording in LokaVox…"
        case .transcribing: return "Transcribing…"
        case .stopRequested: return "Stopping…"
        default: return ""
        }
    }

    private func latencyDescription() -> String? {
        guard let requested = sessionStore.requestedAt else { return nil }
        let end = sessionStore.completedAt ?? Date()
        let seconds = end.timeIntervalSince(requested)
        guard seconds > 0 else { return nil }
        return String(format: "%.1fs", seconds)
    }

    // MARK: - Polling (cold fallback)

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }

        let maxAttempts = Int(Self.pollTimeoutSeconds / Self.pollIntervalSeconds)
        let intervalNs = UInt64(Self.pollIntervalSeconds * 1_000_000_000)

        pollTask = Task { @MainActor [weak self] in
            for _ in 0..<maxAttempts {
                try? await Task.sleep(nanoseconds: intervalNs)
                guard !Task.isCancelled, let self else { return }
                self.refreshAll()
                if self.pollTask == nil { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.setStatus("Timed out waiting for transcript")
            self.pollTask = nil
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Flow countdown tick

    private func startCountdownIfNeeded() {
        guard flowCountdownTask == nil else { return }
        flowCountdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if self.sessionStore.flowActive() {
                    self.flowRemainingSeconds = self.sessionStore.flowExpiresAt.map {
                        max(0, Int($0.timeIntervalSinceNow))
                    }
                    self.refreshHost()
                } else {
                    // Flow ended — do a full refresh to flip UI state.
                    self.refreshAll()
                }
            }
        }
    }

    private func stopCountdown() {
        flowCountdownTask?.cancel()
        flowCountdownTask = nil
    }

    // MARK: - Required overrides

    override func textWillChange(_ textInput: UITextInput?) {}
    override func textDidChange(_ textInput: UITextInput?) {}
}
