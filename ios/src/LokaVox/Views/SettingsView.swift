import SwiftUI

/// Preferences screen mirroring the Mac LokaVox Preferences window —
/// vocabulary (fed to Whisper as `initialPrompt`) and find-and-replace
/// corrections applied after transcription.
struct SettingsView: View {
    @Bindable var settings: LokaVoxSettings

    /// Called when a toggle that requires the engine to re-initialise
    /// changes (e.g. GPU acceleration). Injected so the view doesn't need
    /// to hold a reference to the whole view model.
    var onEngineSettingChange: (() -> Void)? = nil

    @State private var newWord: String = ""
    @State private var showingAddCorrection: Bool = false
    @FocusState private var wordFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                flowSection
                languageSection
                writingStyleSection
                vocabularySection
                correctionsSection
                advancedSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Flow mode

    private var flowSection: some View {
        Section {
            Toggle("Flow mode", isOn: $settings.flowModeEnabled)
            if settings.flowModeEnabled {
                Picker("Keep mic warm for", selection: $settings.flowTimeout) {
                    ForEach(LokaVoxSettings.FlowTimeout.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
            }
        } header: {
            Text("Flow")
        } footer: {
            Text(settings.flowModeEnabled
                ? "After a dictation, the mic stays warm for the chosen duration so the next keyboard tap skips bouncing back to LokaVox. Turn this off if you'd rather every dictation be single-shot."
                : "Every keyboard dictation opens LokaVox, records, and swipes back. Turn Flow mode on to keep the mic warm between dictations.")
                .font(.footnote)
        }
    }

    // MARK: - Language

    private var languageSection: some View {
        Section {
            Picker("Language", selection: $settings.language) {
                ForEach(LokaVoxSettings.TranscriptionLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
        } header: {
            Text("Language")
        } footer: {
            Text("Pick the language you dictate in. \"Auto-detect\" uses your iPhone's system language as a default — fine if that matches what you speak, but pick explicitly here if not (e.g. Türkçe). Vocabulary biasing only works against the selected language.")
                .font(.footnote)
        }
    }

    // MARK: - Writing style

    private var writingStyleSection: some View {
        Section {
            Picker("Writing style", selection: $settings.writingStyle) {
                ForEach(LokaVoxSettings.WritingStyle.allCases) { style in
                    Text(style.rawValue).tag(style)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Writing style")
        } footer: {
            Text("Standard keeps Whisper's original casing and punctuation. Lowercase forces everything to lower case after fixups.")
                .font(.footnote)
        }
    }

    // MARK: - Vocabulary

    private var vocabularySection: some View {
        Section {
            // Chips
            if !settings.vocab.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(settings.vocab, id: \.self) { word in
                        HStack(spacing: 6) {
                            Text(word)
                                .font(.subheadline)
                            Button {
                                settings.vocab.removeAll { $0 == word }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(Capsule())
                    }
                }
            }

            HStack {
                TextField("Add word (Return to commit)", text: $newWord)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($wordFieldFocused)
                    .onSubmit(addWord)
                Button("Add") { addWord() }
                    .disabled(trimmedNewWord.isEmpty)
            }
        } header: {
            Text("Vocabulary")
        } footer: {
            Text("Proper names, jargon, or technical terms — passed to Whisper as an initial prompt to help it recognize them. One word or phrase per chip.")
                .font(.footnote)
        }
    }

    private var trimmedNewWord: String {
        newWord.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addWord() {
        let w = trimmedNewWord
        guard !w.isEmpty else { return }
        if !settings.vocab.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) {
            settings.vocab.append(w)
        }
        newWord = ""
        wordFieldFocused = true
    }

    // MARK: - Advanced (GPU)

    private var advancedSection: some View {
        Section {
            Toggle("GPU acceleration", isOn: Binding(
                get: { settings.gpuAccelerationEnabled },
                set: { newValue in
                    settings.gpuAccelerationEnabled = newValue
                    onEngineSettingChange?()
                }
            ))
        } header: {
            Text("Advanced")
        } footer: {
            Text("On means faster transcription using the iPhone's graphics chip. Off falls back to the CPU — slower but sometimes more stable. Leave on unless you hit a problem.")
                .font(.footnote)
        }
    }

    // MARK: - Corrections

    private var correctionsSection: some View {
        Section {
            ForEach($settings.fixups) { $fixup in
                HStack(spacing: 8) {
                    TextField("find", text: $fixup.from)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("replace with", text: $fixup.to)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .onDelete { indexSet in
                settings.fixups.remove(atOffsets: indexSet)
            }

            Button {
                settings.fixups.append(.init(from: "", to: ""))
            } label: {
                Label("Add correction", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Corrections")
        } footer: {
            Text("Find-and-replace rules applied after transcription. Word-boundary, case-insensitive. Spaces in the \"find\" side match any whitespace run.")
                .font(.footnote)
        }
    }
}

/// Minimal flowing layout for chip rows. Wraps to the next line when the
/// parent width is exceeded.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if rowWidth + size.width > width {
                totalHeight += rowHeight + spacing
                rowWidth = size.width + spacing
                rowHeight = size.height
            } else {
                rowWidth += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: width.isFinite ? width : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
