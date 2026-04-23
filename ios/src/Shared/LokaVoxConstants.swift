import Foundation

/// Constants shared between the LokaVox main app and the LokaVoxKeyboard extension.
/// Compiled into both targets via the `Shared/` source path in `project.yml`; no
/// shared framework is required.
enum LokaVoxConstants {
    /// App Group identifier used for cross-target IPC (UserDefaults + file container).
    static let appGroupIdentifier = "group.com.lokavox.shared"
}
