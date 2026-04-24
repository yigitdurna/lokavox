import Foundation

/// Cross-process signalling via Darwin notifications (CoreFoundation).
///
/// Darwin notifications are the standard iOS pattern for keyboard-extension ↔
/// containing-app signalling: fire-and-forget, no entitlement required for
/// app-defined names, delivered to any non-suspended process. The payload
/// must travel out-of-band — use `SessionStore` (App Group `UserDefaults`)
/// for that, and use Darwin only as a "something changed, go look" kick.
///
/// ## Delivery guarantees (important)
/// - A suspended app **will not** receive notifications. LokaVox keeps the
///   main app un-suspended while Flow is active via `UIBackgroundModes: audio`
///   + an active `AVAudioSession`.
/// - Darwin coalesces: rapid posts may deliver fewer observer fires. Always
///   read the current state from `SessionStore` on fire; never infer from
///   fire count.
/// - The handler is always posted to the main actor. The observer is
///   registered against the main run loop via `CFNotificationCenter`'s default
///   flags.
///
/// References:
/// - Apple DTS, "Darwin notification not received when app backgrounded":
///   https://developer.apple.com/forums/thread/769398
/// - nonstrict.eu, "Darwin Notifications & App Extensions":
///   https://nonstrict.eu/blog/2023/darwin-notifications-app-extensions/
enum DarwinNotifier {

    /// Names used by LokaVox Flow mode.
    enum Name {
        /// Keyboard → main app: "please start/stop a segment; read SessionStore
        /// for the exact intent."
        static let flowRequest = "com.lokavox.flow.request"
        /// Main app → keyboard: "state changed; read SessionStore for details."
        static let flowState = "com.lokavox.flow.state"
    }

    /// Fire a Darwin notification by name. Safe to call from any thread; the
    /// underlying `CFNotificationCenterPostNotification` is thread-safe.
    static func post(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let cfName = CFNotificationName(name as CFString)
        CFNotificationCenterPostNotification(center, cfName, nil, nil, true)
    }

    /// Token returned by `observe`; keep it alive for the observation's
    /// lifetime, then call `cancel()` (or let it deinit).
    final class Token: @unchecked Sendable {
        private let name: String
        private var observer: UnsafeMutableRawPointer?
        private var handler: (@MainActor () -> Void)?

        init(name: String, handler: @escaping @MainActor () -> Void) {
            self.name = name
            self.handler = handler
            let unmanaged = Unmanaged.passUnretained(self)
            self.observer = unmanaged.toOpaque()

            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                self.observer,
                { _, observer, _, _, _ in
                    guard let observer else { return }
                    let token = Unmanaged<Token>.fromOpaque(observer).takeUnretainedValue()
                    token.dispatch()
                },
                name as CFString,
                nil,
                .deliverImmediately
            )
        }

        deinit { cancel() }

        func cancel() {
            guard let observer else { return }
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                observer,
                CFNotificationName(name as CFString),
                nil
            )
            self.observer = nil
            self.handler = nil
        }

        fileprivate func dispatch() {
            // Handlers run on the main actor. The CFNotificationCenter
            // callback thread is undocumented — hop explicitly to be safe.
            guard let handler else { return }
            Task { @MainActor in handler() }
        }
    }

    /// Subscribe to a Darwin notification. Retain the returned `Token` to
    /// keep the observation alive.
    @discardableResult
    static func observe(_ name: String, handler: @escaping @MainActor () -> Void) -> Token {
        Token(name: name, handler: handler)
    }
}
