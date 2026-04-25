import SwiftUI

struct ContentView: View {
    let vm: TranscriptionViewModel

    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let message = vm.errorMessage {
                    errorBanner(message)
                }

                if vm.flow.state != .inactive {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        flowBanner
                    }
                } else if let urlStatus = vm.urlSessionStatus {
                    urlSessionBanner(urlStatus)
                }

                VStack(spacing: 32) {
                    modelStatusZone
                    recordButtonZone
                    transcriptZone
                    diagnosticsZone
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("LokaVox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(settings: vm.settings) {
                    Task { await vm.reloadEngineForSettingsChange() }
                }
            }
            .task {
                await vm.bootstrap()
            }
        }
    }

    // MARK: - Flow banner (step 4)

    private var flowBanner: some View {
        HStack(spacing: 10) {
            flowStatusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(flowHeadline)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                if let sub = flowSubline {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if canEndFlow {
                Button {
                    Task { await vm.endFlow() }
                } label: {
                    Text("End")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.2))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(flowBannerColor)
    }

    private var flowStatusDot: some View {
        Circle()
            .fill(.white)
            .frame(width: 8, height: 8)
            .opacity(flowDotOpacity)
    }

    private var flowHeadline: String {
        switch vm.flow.state {
        case .inactive: return ""
        case .idle: return "Flow active"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .exiting: return "Ending Flow…"
        case .failed(let message): return message
        }
    }

    private var flowSubline: String? {
        guard vm.flow.state == .idle, let expires = vm.flow.flowExpiresAt else {
            return nil
        }
        let remaining = max(0, Int(expires.timeIntervalSinceNow))
        let m = remaining / 60
        let s = remaining % 60
        return String(format: "Mic stays warm for %d:%02d. Keep using the LokaVox keyboard.", m, s)
    }

    private var flowBannerColor: Color {
        switch vm.flow.state {
        case .recording: return .red
        case .failed: return .orange
        default: return Color.green.opacity(0.8)
        }
    }

    private var flowDotOpacity: Double {
        switch vm.flow.state {
        case .idle: return 1
        case .recording, .transcribing: return 1
        default: return 0.7
        }
    }

    private var canEndFlow: Bool {
        switch vm.flow.state {
        case .idle, .recording, .transcribing: return true
        default: return false
        }
    }

    // MARK: - URL-session banner (keyboard bounce-to-app)

    private func urlSessionBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .foregroundStyle(.white)
            Text(message)
                .foregroundStyle(.white)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                vm.clearURLSessionStatus()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.blue)
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
        case .verifying:
            VStack(spacing: 6) {
                Text("Verifying model…")
                ProgressView()
            }
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
        // Allow starting even if the model is still loading — transcription
        // waits for readiness, not recording. Only block when no model exists
        // yet (still downloading) or whisper itself is mid-transcribe.
        let modelBlocksStart: Bool = {
            switch vm.modelManager.state {
            case .idle, .downloading, .verifying, .failed: return true
            case .loading, .ready: return false
            }
        }()
        let state = vm.recordingState
        let disabled = modelBlocksStart || state == .transcribing

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
                    .fill(circleColor(enabled: !modelBlocksStart, state: state))
                    .frame(width: 100, height: 100)
                buttonContent(enabled: !modelBlocksStart, state: state)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func circleColor(enabled: Bool, state: TranscriptionViewModel.RecordingState) -> Color {
        guard enabled else { return Color.gray.opacity(0.3) }
        switch state {
        case .idle: return .blue
        case .recording: return .red
        case .transcribing: return Color.gray.opacity(0.3)
        }
    }

    @ViewBuilder
    private func buttonContent(enabled: Bool, state: TranscriptionViewModel.RecordingState) -> some View {
        if !enabled {
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
            ZStack(alignment: .topLeading) {
                if vm.transcript.isEmpty {
                    Text("Transcript will appear here…")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(
                    get: { vm.transcript },
                    set: { vm.transcript = $0 }
                ))
                .scrollContentBackground(.hidden)
                .padding(6)
            }
            .frame(minHeight: 120, maxHeight: 220)
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

    // MARK: - Diagnostics (temporary, for the "nothing prints" bug hunt)

    @ViewBuilder
    private var diagnosticsZone: some View {
        if let diag = vm.flow.lastEngineDiagnostics {
            VStack(alignment: .leading, spacing: 6) {
                Text("Engine diagnostics")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Group {
                    diagRow("GPU", diag.usedGPU ? "yes" : "no", extra: diag.fellBackToCPU ? " (fallback)" : "")
                    diagRow("Samples", "\(diag.sampleCount)")
                    diagRow("Peak amp", String(format: "%.4f", diag.samplePeakAbs))
                    diagRow("Mean amp", String(format: "%.4f", diag.sampleMeanAbs))
                    diagRow("Language", diag.languageUsed + languageDetectionSuffix(diag: diag))
                    diagRow("Vocab sent", diag.initialPromptUsed.isEmpty ? "(none)" : "\"\(diag.initialPromptUsed)\"")
                    diagRow("Segments", "\(diag.segmentCount)")
                    diagRow("whisper_full code", "\(diag.returnCode)")
                    diagRow("Raw bytes", "\(diag.rawOutput.utf8.count)")
                    diagRow("Trimmed bytes", "\(diag.trimmedOutput.utf8.count)")
                    diagRow("Raw text", diag.rawOutput.isEmpty ? "(empty)" : "\"\(diag.rawOutput)\"")
                }
                .font(.caption2.monospaced())
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Render the language origin as a parenthesised suffix:
    /// - `(auto)` when whisper.cpp's `whisper_lang_auto_detect` ran on this transcribe.
    /// - `(cached)` when we reused a Flow-session-cached detection from a prior segment.
    /// - empty when the user picked an explicit language in Settings.
    private func languageDetectionSuffix(diag: WhisperEngine.Diagnostics) -> String {
        if diag.autoDetected { return " (auto)" }
        if vm.flow.lastTranscribeUsedCachedLanguage { return " (cached)" }
        return ""
    }

    private func diagRow(_ label: String, _ value: String, extra: String = "") -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label + ":")
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value + extra)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
