import Foundation

/// Cross-process IPC between the LokaVox main app and the LokaVoxKeyboard
/// extension, backed by App Group `UserDefaults`.
///
/// Step 3 uses a single UserDefaults store (no JSON file) because the payload
/// (transcript text) is small, atomic KV writes are sufficient, and adding a
/// second backing store introduces ordering bugs between the two.
///
/// Dedup uses a monotonically increasing generation counter bumped by the
/// keyboard before each `lokavox://record` open. The keyboard tracks its own
/// `lastInsertedGeneration` in its process-local `UserDefaults.standard`.
enum SessionState: String {
    case idle
    case requested
    /// Step-4: keyboard asked main app to stop the current Flow segment.
    /// Only meaningful while Flow is active. Main app transitions to
    /// `.transcribing` once it has removed the input tap.
    case stopRequested
    case recording
    case transcribing
    case done
    case error
}

struct SessionStore {
    let defaults: UserDefaults
    let isAppGroupAvailable: Bool

    // MARK: - Keys

    private enum Key {
        static let generation = "session.generation"
        static let state = "session.state"
        static let transcript = "session.transcript"
        static let error = "session.error"
        static let requestedAt = "session.requestedAtEpoch"
        static let completedAt = "session.completedAtEpoch"
        static let hasFullAccessObserved = "keyboard.hasFullAccessObserved"
        // Step-4 Flow-mode fields.
        static let flowExpiresAt = "session.flowExpiresAtEpoch"
        static let heartbeatAt = "session.heartbeatAtEpoch"
    }

    // MARK: - Construction

    /// Returns a `SessionStore` backed by the App Group suite when available.
    /// Falls back to `UserDefaults.standard` so the app can still launch in a
    /// degraded state rather than crashing. Callers should check
    /// `isAppGroupAvailable` when they need real IPC.
    static func shared() -> SessionStore {
        if let defaults = UserDefaults(suiteName: LokaVoxConstants.appGroupIdentifier) {
            return SessionStore(defaults: defaults, isAppGroupAvailable: true)
        }
        NSLog("[LokaVox] App Group \(LokaVoxConstants.appGroupIdentifier) is not configured — check both targets' Signing & Capabilities.")
        return SessionStore(defaults: .standard, isAppGroupAvailable: false)
    }

    // MARK: - Reads

    var generation: Int {
        defaults.integer(forKey: Key.generation)
    }

    var state: SessionState {
        guard let raw = defaults.string(forKey: Key.state),
              let s = SessionState(rawValue: raw) else {
            return .idle
        }
        return s
    }

    var transcript: String {
        defaults.string(forKey: Key.transcript) ?? ""
    }

    var error: String? {
        defaults.string(forKey: Key.error)
    }

    var requestedAt: Date? {
        let epoch = defaults.double(forKey: Key.requestedAt)
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }

    var completedAt: Date? {
        let epoch = defaults.double(forKey: Key.completedAt)
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }

    var hasFullAccessObserved: Bool {
        defaults.bool(forKey: Key.hasFullAccessObserved)
    }

    // MARK: - Flow (step 4)

    /// Epoch when the current Flow window ends, or `nil` if Flow is inactive.
    /// Main app is the sole writer; keyboard reads for UI gating.
    var flowExpiresAt: Date? {
        let epoch = defaults.double(forKey: Key.flowExpiresAt)
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }

    /// Last heartbeat timestamp from the main app. Staleness here is how
    /// the keyboard detects Jetsam or a crashed main app.
    var heartbeatAt: Date? {
        let epoch = defaults.double(forKey: Key.heartbeatAt)
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }

    /// Both: Flow window not expired AND heartbeat fresh within `freshness`
    /// seconds. The keyboard uses this to decide between Darwin path (warm)
    /// and `Link` URL-bounce path (cold).
    func flowActive(now: Date = Date(), freshness: TimeInterval = 3) -> Bool {
        guard let expires = flowExpiresAt, expires > now else { return false }
        guard let beat = heartbeatAt, now.timeIntervalSince(beat) < freshness else {
            return false
        }
        return true
    }

    // MARK: - Writes (keyboard side)

    /// Bump the generation counter and mark the session as `requested`.
    /// Returns the new generation so the caller can stash it locally if desired.
    @discardableResult
    func bumpGenerationAndMarkRequested() -> Int {
        let next = defaults.integer(forKey: Key.generation) + 1
        defaults.set(next, forKey: Key.generation)
        defaults.set(SessionState.requested.rawValue, forKey: Key.state)
        defaults.set(Date().timeIntervalSince1970, forKey: Key.requestedAt)
        defaults.set("", forKey: Key.transcript)
        defaults.removeObject(forKey: Key.error)
        defaults.removeObject(forKey: Key.completedAt)
        return next
    }

    func setFullAccessObserved(_ value: Bool) {
        // Optimistic cache per TypeWhisper pattern: only cache `true`, never
        // `false` — `hasFullAccess` can return stale negatives right after the
        // user toggles access on.
        if value {
            defaults.set(true, forKey: Key.hasFullAccessObserved)
        }
    }

    /// Keyboard-side write used inside an active Flow window to ask the
    /// main app to stop the in-progress segment. No generation bump — we're
    /// stopping the current generation, not starting a new one.
    func markStopRequested() {
        defaults.set(SessionState.stopRequested.rawValue, forKey: Key.state)
    }

    // MARK: - Writes (main-app side — Flow)

    /// Set / refresh the Flow expiry timestamp. Main app only.
    func setFlowExpiresAt(_ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: Key.flowExpiresAt)
    }

    /// Heartbeat ping. Main app writes this at ~1.5s cadence while Flow is
    /// alive so the keyboard can detect Jetsam.
    func writeHeartbeat(at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: Key.heartbeatAt)
    }

    /// Tear down Flow visibility. Clears expiry + heartbeat so the keyboard
    /// reverts to Link-based cold entry on the next tap.
    func clearFlow() {
        defaults.removeObject(forKey: Key.flowExpiresAt)
        defaults.removeObject(forKey: Key.heartbeatAt)
    }

    // MARK: - Writes (main-app side)

    /// Transition to a non-terminal state (`recording` / `transcribing`).
    func mark(state: SessionState) {
        defaults.set(state.rawValue, forKey: Key.state)
    }

    /// Overwrite just the transcript text, leaving `state` and `completedAt`
    /// untouched. Used when the user edits the transcript in the main app
    /// after stopping — the edited version should be the one the keyboard
    /// inserts on return.
    func updateTranscript(_ text: String) {
        defaults.set(text, forKey: Key.transcript)
    }

    /// Transition to `done` with the final transcript.
    func markDone(transcript: String) {
        defaults.set(transcript, forKey: Key.transcript)
        defaults.removeObject(forKey: Key.error)
        defaults.set(Date().timeIntervalSince1970, forKey: Key.completedAt)
        defaults.set(SessionState.done.rawValue, forKey: Key.state)
    }

    /// Transition to `error` with a user-facing message.
    func markError(_ message: String) {
        defaults.set(message, forKey: Key.error)
        defaults.set(Date().timeIntervalSince1970, forKey: Key.completedAt)
        defaults.set(SessionState.error.rawValue, forKey: Key.state)
    }
}
