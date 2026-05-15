import SwiftUI

/// Step-4 keyboard UI. The mic button shape depends on the Flow state
/// provided by the controller:
///
/// - `.cold` — SwiftUI `Link(lokavox://record)`. Only a system-dispatched
///   Link can open the main app from a keyboard extension on iOS 18+.
/// - `.warmIdle` — regular `Button`; posts a Darwin notification to the
///   backgrounded main app without leaving the host app.
/// - `.warmRecording` — red `Button`; second tap stops the segment.
/// - `.warmTranscribing` — disabled spinner; mic is in whisper hands.
struct KeyboardView: View {
    enum FlowMode: Equatable {
        case cold
        case warmIdle
        case warmRecording
        case warmTranscribing
    }

    let flowMode: FlowMode

    /// Fires before the cold-path Link navigates.
    let onMicPreTap: () -> Void
    /// Warm Flow, mic idle → start a new segment.
    let onMicWarmStart: () -> Void
    /// Warm Flow, recording → stop the segment.
    let onMicWarmStop: () -> Void

    let onDeleteTap: () -> Void
    let onSpaceTap: () -> Void
    let onReturnTap: () -> Void

    let status: String
    let micEnabled: Bool
    /// Seconds remaining in the Flow window. Shown as a pill above the mic
    /// whenever Flow is warm. Nil hides the pill.
    let flowRemainingSeconds: Int?

    private let recordURL = URL(string: "lokavox://record")!

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                if let seconds = flowRemainingSeconds, flowMode != .cold {
                    flowPill(seconds: seconds)
                }
                micButton
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                Spacer(minLength: 0)
            }

            bottomRow
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 6) {
            utilityKey(systemImage: "delete.backward.fill", action: onDeleteTap, accessibilityLabel: "Delete")
            spaceKey
            utilityKey(systemImage: "return", action: onReturnTap, accessibilityLabel: "Return")
        }
        .frame(height: 44)
    }

    private var spaceKey: some View {
        Button(action: onSpaceTap) {
            Text("space")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func utilityKey(
        systemImage: String,
        action: @escaping () -> Void,
        accessibilityLabel: String
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.primary)
                .frame(minWidth: 56, maxWidth: 56, maxHeight: .infinity)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var micButton: some View {
        switch flowMode {
        case .cold:
            if micEnabled {
                Link(destination: recordURL) {
                    micLabel(color: .blue, icon: "mic.fill")
                }
                .simultaneousGesture(TapGesture().onEnded { onMicPreTap() })
            } else {
                micLabel(color: .blue, icon: "mic.fill").opacity(0.4)
            }
        case .warmIdle:
            Button(action: onMicWarmStart) {
                micLabel(color: .green, icon: "mic.fill")
            }
            .disabled(!micEnabled)
        case .warmRecording:
            Button(action: onMicWarmStop) {
                micLabel(color: .red, icon: "stop.fill", recording: true)
            }
            .disabled(!micEnabled)
        case .warmTranscribing:
            micLabel(color: Color.gray, icon: "ellipsis", transcribing: true)
                .opacity(0.85)
        }
    }

    private func micLabel(
        color: Color,
        icon: String,
        recording: Bool = false,
        transcribing: Bool = false
    ) -> some View {
        Image(systemName: icon)
            .font(.system(size: 38, weight: .semibold))
            .foregroundStyle(.white)
            .symbolEffect(.pulse, options: .repeating, isActive: transcribing)
            .frame(width: 104, height: 104)
            .background(
                Circle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: color.opacity(0.88), location: 0),
                                .init(color: color, location: 0.55),
                                .init(color: color.opacity(0.92), location: 1)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
            )
            .shadow(color: color.opacity(0.45), radius: 14, x: 0, y: 8)
            .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
            .scaleEffect(recording && pulse ? 1.06 : 1.0)
            .onAppear {
                if recording {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
            }
            .onChange(of: recording) { _, isOn in
                if isOn {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        pulse = false
                    }
                }
            }
    }

    private func flowPill(seconds: Int) -> some View {
        let m = seconds / 60
        let s = seconds % 60
        return HStack(spacing: 6) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            Text(String(format: "Flow %d:%02d", m, s))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(Capsule())
    }
}
