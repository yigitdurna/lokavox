import Foundation
@preconcurrency import WhisperKit

/// Owns the WhisperKit instance and serializes all access to it.
/// Isolating it inside an actor keeps the non-Sendable `WhisperKit` class
/// out of other isolation domains.
actor WhisperEngine {
    enum EngineError: LocalizedError {
        case notLoaded
        var errorDescription: String? {
            switch self {
            case .notLoaded: return "Whisper model is not loaded yet."
            }
        }
    }

    private var whisperKit: WhisperKit?

    /// True once a model folder has been loaded into memory.
    var isLoaded: Bool { whisperKit != nil }

    /// Load WhisperKit from a pre-downloaded model folder on disk.
    /// - Parameter modelFolder: directory containing the CoreML model bundles.
    /// Safe to call more than once; replaces any existing instance.
    func load(modelFolder: URL) async throws {
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            prewarm: true,    // forces deterministic ANE compilation up front
            download: false   // we download separately via ModelManagerService
        )
        let kit = try await WhisperKit(config)
        self.whisperKit = kit
    }

    /// Transcribe 16 kHz mono Float32 PCM samples. English, no timestamps.
    /// - Returns: concatenated transcript text with leading/trailing whitespace trimmed.
    func transcribe(audioSamples: [Float]) async throws -> String {
        guard let whisperKit else { throw EngineError.notLoaded }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: audioSamples,
            decodeOptions: options
        )
        let joined = results.map(\.text).joined(separator: " ")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
