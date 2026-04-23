import SwiftUI

struct ContentView: View {
    let vm: TranscriptionViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let message = vm.errorMessage {
                errorBanner(message)
            }

            VStack(spacing: 32) {
                modelStatusZone
                recordButtonZone
                transcriptZone
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await vm.bootstrap()
        }
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .foregroundStyle(.white)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                vm.clearError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.red)
    }

    // MARK: - Model status zone

    @ViewBuilder
    private var modelStatusZone: some View {
        switch vm.modelManager.state {
        case .idle:
            Text("Preparing…")
                .foregroundStyle(.secondary)
        case .downloading(let p):
            VStack(spacing: 6) {
                Text("Downloading model…")
                ProgressView(value: p)
                Text("\(Int(p * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 280)
        case .loading:
            VStack(spacing: 6) {
                Text("Loading model…")
                ProgressView()
            }
        case .ready:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Model ready")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .failed(let msg):
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Button("Retry") {
                    Task { await vm.bootstrap() }
                }
            }
            .frame(maxWidth: 280)
        }
    }

    // MARK: - Record button zone

    private var recordButtonZone: some View {
        let modelReady = vm.modelManager.state == .ready
        let state = vm.recordingState
        let disabled = !modelReady || state == .transcribing

        return Button {
            switch state {
            case .idle:
                Task { await vm.startRecording() }
            case .recording:
                Task { await vm.stopAndTranscribe() }
            case .transcribing:
                break
            }
        } label: {
            ZStack {
                Circle()
                    .fill(circleColor(modelReady: modelReady, state: state))
                    .frame(width: 100, height: 100)
                buttonContent(modelReady: modelReady, state: state)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func circleColor(modelReady: Bool, state: TranscriptionViewModel.RecordingState) -> Color {
        guard modelReady else { return Color.gray.opacity(0.3) }
        switch state {
        case .idle: return .blue
        case .recording: return .red
        case .transcribing: return Color.gray.opacity(0.3)
        }
    }

    @ViewBuilder
    private func buttonContent(modelReady: Bool, state: TranscriptionViewModel.RecordingState) -> some View {
        if !modelReady {
            Image(systemName: "mic.slash")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.secondary)
        } else {
            switch state {
            case .idle:
                Image(systemName: "mic.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
            case .recording:
                Image(systemName: "stop.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
            case .transcribing:
                ProgressView()
                    .tint(.white)
            }
        }
    }

    // MARK: - Transcript zone

    private var transcriptZone: some View {
        VStack(spacing: 8) {
            ScrollView {
                if vm.transcript.isEmpty {
                    Text("Transcript will appear here…")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(vm.transcript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .frame(maxHeight: 200)
            .padding(10)
            .background(Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let latencyText = latencySummary {
                Text(latencyText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var latencySummary: String? {
        var parts: [String] = []
        if let d = vm.modelManager.downloadDurationMs {
            parts.append("Download: \(d) ms")
        }
        if let l = vm.modelManager.loadDurationMs {
            parts.append("Load: \(l) ms")
        }
        if let t = vm.lastTranscribeLatencyMs {
            parts.append("Transcribe: \(t) ms")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
