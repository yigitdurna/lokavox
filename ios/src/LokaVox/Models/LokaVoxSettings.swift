import Foundation
import Observation

/// User preferences ported from the Mac LokaVox Preferences window.
///
/// - `vocab`: list of domain words fed to Whisper as `initialPrompt`.
///   Helps Whisper transcribe proper names, jargon, technical terms.
/// - `fixups`: post-transcription find/replace rules. Applied with
///   word-boundary, case-insensitive matching; spaces in `from` match any
///   whitespace run. Mirrors the Mac version's `fixups_compiled()` semantics.
///
/// Persisted as JSON in `UserDefaults.standard` (per-app, not App Group).
/// The keyboard extension doesn't need these — transcription runs only in
/// the main app, and corrections are applied before the transcript is
/// written to the App Group.
@MainActor
@Observable
final class LokaVoxSettings {

    struct Fixup: Codable, Identifiable, Equatable {
        var from: String
        var to: String
        var id = UUID()

        private enum CodingKeys: String, CodingKey { case from, to }
    }

    /// Mirrors the Mac LokaVox Preferences "Writing style" control.
    /// Applied after fixups.
    enum WritingStyle: String, Codable, CaseIterable, Identifiable {
        case standard = "Standard"
        case lowercase = "Lowercase"
        var id: String { rawValue }
    }

    /// Flow-window duration presets. Picked via `Picker` rather than a free
    /// stepper so the user can't accidentally set something pathological.
    enum FlowTimeout: Int, Codable, CaseIterable, Identifiable {
        case oneMinute = 60
        case threeMinutes = 180
        case fiveMinutes = 300
        case tenMinutes = 600
        case thirtyMinutes = 1800

        var id: Int { rawValue }

        var seconds: TimeInterval { TimeInterval(rawValue) }

        var displayName: String {
            switch self {
            case .oneMinute: return "1 minute"
            case .threeMinutes: return "3 minutes"
            case .fiveMinutes: return "5 minutes"
            case .tenMinutes: return "10 minutes"
            case .thirtyMinutes: return "30 minutes"
            }
        }
    }

    /// Transcription language choice. `auto` lets Whisper detect from the
    /// first few seconds — slightly slower, occasionally wrong on short
    /// clips. Explicit choices are faster and more reliable.
    enum TranscriptionLanguage: String, Codable, CaseIterable, Identifiable {
        case auto
        case english
        case turkish

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .auto: return "Auto-detect"
            case .english: return "English"
            case .turkish: return "Türkçe"
            }
        }

        /// Whisper-compatible language code, or `nil` for auto-detect.
        var whisperCode: String? {
            switch self {
            case .auto: return nil
            case .english: return "en"
            case .turkish: return "tr"
            }
        }
    }

    /// Whisper-on-silence hallucinations. If the whole transcript (lowercased,
    /// punctuation trimmed) matches one of these, drop it. Ported verbatim
    /// from the Mac version's `_HALLUCINATIONS` set so iOS and macOS behave
    /// the same when Whisper invents text from near-silence.
    private static let hallucinations: Set<String> = [
        "thank you",
        "thanks for watching",
        "thanks for listening",
        "subscribe",
        "like and subscribe",
        "bye",
        "you",
        "the end",
        "thanks",
        "thank you for watching"
    ]

    private static let storageKey = "LokaVox.settings.v1"

    var vocab: [String] {
        didSet { save() }
    }

    var fixups: [Fixup] {
        didSet { save() }
    }

    var writingStyle: WritingStyle {
        didSet { save() }
    }

    var language: TranscriptionLanguage {
        didSet { save() }
    }

    /// When true, the mic stays warm for `flowTimeout` after a segment so
    /// subsequent keyboard taps don't bounce the user back to the LokaVox
    /// app. When false, every dictation is single-shot (step-3 behaviour):
    /// tap in keyboard → bounce to app → record → swipe back → insert.
    var flowModeEnabled: Bool {
        didSet { save() }
    }

    /// How long the mic stays warm after the last segment, when
    /// `flowModeEnabled` is true.
    var flowTimeout: FlowTimeout {
        didSet { save() }
    }

    /// If true, whisper.cpp runs on the iPhone GPU via Metal — much faster
    /// per transcription. If false, it runs on CPU only. The user-facing
    /// escape hatch for the iOS 26 Metal-when-backgrounded crash
    /// (whisper.cpp#3531): CPU is slower but cannot trigger that path.
    var gpuAccelerationEnabled: Bool {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            self.vocab = decoded.vocab
            self.fixups = decoded.fixups
            self.writingStyle = decoded.writingStyle ?? .standard
            self.language = decoded.language ?? .auto
            self.flowModeEnabled = decoded.flowModeEnabled ?? true
            self.flowTimeout = decoded.flowTimeout ?? .fiveMinutes
            self.gpuAccelerationEnabled = decoded.gpuAccelerationEnabled ?? true
        } else {
            self.vocab = []
            self.fixups = []
            self.writingStyle = .standard
            self.language = .auto
            self.flowModeEnabled = true
            self.flowTimeout = .fiveMinutes
            self.gpuAccelerationEnabled = true
        }
    }

    /// Space-separated vocab, single-line — this is the format Whisper's
    /// `initialPrompt` expects. Empty if no vocab set.
    var initialPrompt: String {
        vocab.joined(separator: ", ")
    }

    /// Apply hallucination filter, fixups, and writing style to a
    /// transcribed string, in order:
    /// 1. Hallucination denylist — if the whole transcript (lowercased,
    ///    punctuation trimmed) matches a known Whisper-on-silence phrase,
    ///    replace it with an empty string.
    /// 2. Fixups — word-boundary, case-insensitive; spaces match `\s+`.
    /// 3. Writing style.
    func postProcess(_ input: String) -> String {
        let normalised = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!,"))
        if Self.hallucinations.contains(normalised) {
            return ""
        }

        var text = input
        for fixup in fixups {
            let trimmedFrom = fixup.from.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedFrom.isEmpty else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: trimmedFrom)
                .replacingOccurrences(of: "\\ ", with: "\\s+")
            let pattern = "\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(
                in: text,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: fixup.to)
            )
        }
        if writingStyle == .lowercase {
            text = text.lowercased()
        }
        return text
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        let vocab: [String]
        let fixups: [Fixup]
        let writingStyle: WritingStyle?
        let language: TranscriptionLanguage?
        let flowModeEnabled: Bool?
        let flowTimeout: FlowTimeout?
        let gpuAccelerationEnabled: Bool?
    }

    private func save() {
        let snapshot = Stored(
            vocab: vocab,
            fixups: fixups,
            writingStyle: writingStyle,
            language: language,
            flowModeEnabled: flowModeEnabled,
            flowTimeout: flowTimeout,
            gpuAccelerationEnabled: gpuAccelerationEnabled
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
