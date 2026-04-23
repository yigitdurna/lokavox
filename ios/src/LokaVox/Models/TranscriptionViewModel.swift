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

    private(set) var recordingState: RecordingState = .idle
    private(set) var transcript: String = ""
    private(set) var lastTranscribeLatencyMs: Int?
    private(set) var errorMessage: String?

    private let engine: WhisperEngine
    private let recorder: AudioRecordingService

    init() {
        let engine = WhisperEngine()
        self.engine = engine
        self.modelManager = ModelManagerService(engine: engine)
        self.recorder = AudioRecordingService()

        self.recorder.onInterruption = { [weak self] in
            guard let self else { return }
            self.recordingState = .idle
            self.errorMessage = "Recording was interrupted."
        }
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        await modelManager.prepare()
    }

    // MARK: - Recording

    func startRecording() async {
        guard recordingState == .idle else { return }
        guard modelManager.state == .ready else {
            errorMessage = "Model is not ready yet."
            return
        }

        let granted = await recorder.requestPermission()
        guard granted else {
            errorMessage = "Microphone permission denied. Enable it in Settings."
            return
        }

        errorMessage = nil
        do {
            try await recorder.start()
            recordingState = .recording
        } catch {
            errorMessage = error.localizedDescription
            recordingState = .idle
        }
    }

    func stopAndTranscribe() async {
        guard recordingState == .recording else { return }

        let samples = recorder.stop()
        recordingState = .transcribing

        guard !samples.isEmpty else {
            errorMessage = "No audio captured."
            recordingState = .idle
            return
        }

        let start = Date()
        do {
            let text = try await engine.transcribe(audioSamples: samples)
            lastTranscribeLatencyMs = Int(Date().timeIntervalSince(start) * 1000)
            transcript = text
            recordingState = .idle
        } catch {
            errorMessage = error.localizedDescription
            recordingState = .idle
        }
    }

    func clearError() {
        errorMessage = nil
    }
}
