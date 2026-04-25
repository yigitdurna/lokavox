import Foundation
@preconcurrency import whisper

/// Owns a single whisper.cpp context and serialises all access to it via an
/// actor. The C library is not thread-safe — all `whisper_*` calls must be
/// made from one isolation domain.
///
/// Why whisper.cpp instead of WhisperKit (our step-2 choice): WhisperKit only
/// ships quantized CoreML variants for A18 iPhone chips (ANE compile-budget
/// limit). Quantization measurably hurt transcription quality on non-English
/// and unclear speech. whisper.cpp with Metal acceleration can load the exact
/// same `ggml-large-v3-turbo.bin` the Mac version uses — full FP16, Mac-parity
/// quality.
///
/// Threading: whisper.cpp's public header warns the library is not
/// thread-safe. The actor boundary is our serialisation guarantee. All
/// `whisper_*` calls in this file run on the actor executor.
actor WhisperEngine {
    enum EngineError: LocalizedError {
        case notLoaded
        case contextInitFailed
        case transcribeFailed(code: Int32)

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "Whisper model is not loaded yet."
            case .contextInitFailed:
                return "Failed to initialise whisper context from model file."
            case .transcribeFailed(let code):
                return "whisper_full failed with code \(code)."
            }
        }
    }

    // `nonisolated(unsafe)` so `deinit` (always nonisolated under Swift 6)
    // can call `whisper_free` without bouncing through the actor executor.
    // Safe: the only mutators are actor methods, and deinit runs only after
    // the last reference is released — no concurrent access possible.
    nonisolated(unsafe) private var context: OpaquePointer?
    private var modelFileURL: URL?
    /// Tracks whether the current `context` was initialised with GPU on.
    /// On CPU fallback we know we don't need to retry again.
    private var contextUsesGPU: Bool = false

    /// True once a model file has been loaded into memory.
    var isLoaded: Bool { context != nil }

    /// Captured diagnostics from the most recent transcribe call. Read from
    /// the actor via `snapshotDiagnostics()`; useful when the user reports
    /// "it worked but nothing printed" — lets the UI show exactly what
    /// whisper.cpp produced so we can tell junk output (punctuation only,
    /// whitespace) from real output.
    struct Diagnostics: Sendable {
        let rawOutput: String
        let trimmedOutput: String
        let segmentCount: Int32
        let usedGPU: Bool
        let returnCode: Int32
        let fellBackToCPU: Bool
        let sampleCount: Int
        /// Mean absolute sample amplitude. ~0 means silence or a broken
        /// capture pipeline; typical speech is 0.01–0.2.
        let samplePeakAbs: Float
        let sampleMeanAbs: Float
        /// The language string actually passed to whisper.cpp (e.g. "en",
        /// "tr").
        let languageUsed: String
        /// True iff `languageUsed` came from `whisper_lang_auto_detect()`
        /// rather than an explicit Settings choice or the locale fallback.
        /// Lets the diagnostics panel render "tr (auto)" so we can see at
        /// a glance whether real audio-based detection actually ran.
        let autoDetected: Bool
        /// The vocabulary / initial_prompt string actually passed to
        /// whisper.cpp. If user reports "vocab isn't biasing output" we
        /// can distinguish "never reached the engine" from "reached the
        /// engine but whisper's soft-biasing didn't pick it up".
        let initialPromptUsed: String
    }
    private var lastDiagnostics: Diagnostics?
    func snapshotDiagnostics() -> Diagnostics? { lastDiagnostics }

    /// Load a GGML whisper model from a pre-downloaded `.bin` file on disk.
    ///
    /// - Parameters:
    ///   - modelFileURL: absolute path to a `ggml-*.bin` model file.
    ///   - useGPU: if true, enable Metal acceleration. The caller is expected
    ///     to honour the user's Settings toggle and any platform overrides
    ///     (e.g. Simulator, which has broken Metal support in whisper.cpp —
    ///     pass `false` there).
    ///
    /// Safe to call more than once; replaces any existing context.
    func load(modelFileURL: URL, useGPU: Bool) async throws {
        releaseContext()

        self.modelFileURL = modelFileURL
        self.contextUsesGPU = useGPU

        guard let ctx = initContext(at: modelFileURL, useGPU: useGPU) else {
            self.modelFileURL = nil
            throw EngineError.contextInitFailed
        }
        self.context = ctx
    }

    /// Block the current task until a context exists, or `timeout` elapses.
    /// Returns true on success, false on timeout.
    func waitForLoaded(timeout: TimeInterval) async -> Bool {
        if context != nil { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if context != nil { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return context != nil
    }

    /// Transcribe 16 kHz mono Float32 PCM samples.
    ///
    /// - Parameters:
    ///   - audioSamples: 16 kHz mono Float32 audio, exactly as produced by
    ///     `AudioRecordingService`.
    ///   - initialPrompt: optional comma-separated vocabulary passed to
    ///     whisper.cpp via `params.initial_prompt`. Empty = no prompt.
    ///   - languageCode: Whisper language code (`"en"`, `"tr"`, ...), or nil
    ///     to let whisper.cpp auto-detect (`detect_language = true`).
    /// - Returns: concatenated transcript text with leading/trailing
    ///   whitespace trimmed.
    ///
    /// On whisper_full failure (non-zero return) we rebuild the context with
    /// GPU disabled and retry once. This catches the iOS 26 Metal
    /// `accessRevoked` path reported in whisper.cpp#3531 where GPU work is
    /// revoked when the app backgrounds. If the retry also fails, we throw.
    func transcribe(
        audioSamples: [Float],
        initialPrompt: String = "",
        languageCode: String? = nil
    ) async throws -> String {
        guard let ctx = context else { throw EngineError.notLoaded }

        let (peak, mean) = sampleStats(audioSamples)

        let firstAttempt = runTranscribe(
            context: ctx,
            audioSamples: audioSamples,
            initialPrompt: initialPrompt,
            languageCode: languageCode
        )

        if case let .success(text, raw, segments, code, langUsed, autoDetected) = firstAttempt {
            lastDiagnostics = Diagnostics(
                rawOutput: raw,
                trimmedOutput: text,
                segmentCount: segments,
                usedGPU: contextUsesGPU,
                returnCode: code,
                fellBackToCPU: false,
                sampleCount: audioSamples.count,
                samplePeakAbs: peak,
                sampleMeanAbs: mean,
                languageUsed: langUsed,
                autoDetected: autoDetected,
                initialPromptUsed: initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return text
        }

        // First pass failed. If we were on GPU, fall back to CPU and retry.
        if contextUsesGPU, let url = modelFileURL {
            releaseContext()
            guard let cpuCtx = initContext(at: url, useGPU: false) else {
                throw EngineError.contextInitFailed
            }
            self.context = cpuCtx
            self.contextUsesGPU = false

            let secondAttempt = runTranscribe(
                context: cpuCtx,
                audioSamples: audioSamples,
                initialPrompt: initialPrompt,
                languageCode: languageCode
            )
            switch secondAttempt {
            case let .success(text, raw, segments, code, langUsed, autoDetected):
                lastDiagnostics = Diagnostics(
                    rawOutput: raw,
                    trimmedOutput: text,
                    segmentCount: segments,
                    usedGPU: false,
                    returnCode: code,
                    fellBackToCPU: true,
                    sampleCount: audioSamples.count,
                    samplePeakAbs: peak,
                    sampleMeanAbs: mean,
                    languageUsed: langUsed,
                    autoDetected: autoDetected,
                    initialPromptUsed: initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                return text
            case .failure(let code):
                lastDiagnostics = Diagnostics(
                    rawOutput: "",
                    trimmedOutput: "",
                    segmentCount: 0,
                    usedGPU: false,
                    returnCode: code,
                    fellBackToCPU: true,
                    sampleCount: audioSamples.count,
                    samplePeakAbs: peak,
                    sampleMeanAbs: mean,
                    languageUsed: languageCode ?? fallbackLanguage(),
                    autoDetected: false,
                    initialPromptUsed: initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                throw EngineError.transcribeFailed(code: code)
            }
        }

        if case .failure(let code) = firstAttempt {
            lastDiagnostics = Diagnostics(
                rawOutput: "",
                trimmedOutput: "",
                segmentCount: 0,
                usedGPU: contextUsesGPU,
                returnCode: code,
                fellBackToCPU: false,
                sampleCount: audioSamples.count,
                samplePeakAbs: peak,
                sampleMeanAbs: mean,
                languageUsed: languageCode ?? fallbackLanguage(),
                autoDetected: false,
                initialPromptUsed: initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            throw EngineError.transcribeFailed(code: code)
        }
        throw EngineError.transcribeFailed(code: -1)
    }

    // MARK: - Internal

    private enum TranscribeResult {
        case success(trimmed: String, raw: String, segments: Int32, code: Int32, languageUsed: String, autoDetected: Bool)
        case failure(Int32)
    }

    private func initContext(at url: URL, useGPU: Bool) -> OpaquePointer? {
        var params = whisper_context_default_params()
        params.use_gpu = useGPU
        // `flash_attn` (fast Metal attention path) has been reported to
        // silently return zero segments on some model / OS combinations on
        // iOS. Keep it off until we have a reproducer. Modest speed cost.
        params.flash_attn = false
        return whisper_init_from_file_with_params(url.path, params)
    }

    /// Last-resort fallback language when the caller passed Auto and
    /// `whisper_lang_auto_detect()` either failed or wasn't applicable.
    /// Returns the iOS device's system language code, or "en" if even
    /// that lookup fails.
    private func fallbackLanguage() -> String {
        if let systemCode = Locale.current.language.languageCode?.identifier,
           !systemCode.isEmpty {
            return systemCode
        }
        return "en"
    }

    /// Run a real audio-based language-detection pass — the same approach
    /// `whisper-cli` uses for `-l auto`. Two C calls in sequence:
    /// `whisper_pcm_to_mel` to populate the encoder input, then
    /// `whisper_lang_auto_detect` which runs the encoder and projects to
    /// language probabilities. Returns the 2-letter code of the top match
    /// (e.g. "tr", "en"), or nil on hard failure.
    ///
    /// This is a different code path from `whisper_full`'s internal
    /// `detect_language = true` flag, which silently returns zero segments
    /// on this build/model (see CLAUDE.md step-6 gotcha #1). Cost: roughly
    /// one extra encoder pass per transcribe — ~100 ms on Metal.
    private func detectLanguage(ctx: OpaquePointer, samples: [Float], nThreads: Int32) -> String? {
        guard !samples.isEmpty else { return nil }

        let melResult = samples.withUnsafeBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return whisper_pcm_to_mel(ctx, base, Int32(buf.count), nThreads)
        }
        guard melResult == 0 else { return nil }

        let maxId = whisper_lang_max_id()
        var probs = [Float](repeating: 0, count: Int(maxId) + 1)

        let langId = probs.withUnsafeMutableBufferPointer { bufPtr -> Int32 in
            guard let base = bufPtr.baseAddress else { return -1 }
            return whisper_lang_auto_detect(ctx, 0, nThreads, base)
        }
        guard langId >= 0 else { return nil }

        guard let cstr = whisper_lang_str(langId) else { return nil }
        return String(cString: cstr)
    }

    /// Peak + mean absolute amplitude of the sample buffer. Cheap to compute
    /// — used only as a sanity check for the audio pipeline.
    private func sampleStats(_ samples: [Float]) -> (peak: Float, mean: Float) {
        guard !samples.isEmpty else { return (0, 0) }
        var peak: Float = 0
        var sum: Float = 0
        for s in samples {
            let a = s < 0 ? -s : s
            if a > peak { peak = a }
            sum += a
        }
        return (peak, sum / Float(samples.count))
    }

    private func releaseContext() {
        if let ctx = context {
            whisper_free(ctx)
        }
        context = nil
    }

    /// Runs `whisper_full` with the given options. Returns the joined segment
    /// text on success, or the raw return code on failure. No retries here —
    /// the caller (`transcribe(...)`) owns retry policy.
    private func runTranscribe(
        context ctx: OpaquePointer,
        audioSamples: [Float],
        initialPrompt: String,
        languageCode: String?
    ) -> TranscribeResult {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        // 4 thread ceiling on A18 — whisper.cpp regresses past 4 on
        // smaller SoCs. Leave 2 cores free for audio + system.
        let nThreads = Int32(max(1, min(4, ProcessInfo.processInfo.processorCount - 2)))
        params.n_threads = nThreads
        params.print_realtime = false
        params.print_progress = false
        params.print_special = false
        params.no_timestamps = true    // matches Mac whisper-cli `-nt`
        params.translate = false
        params.detect_language = false
        params.greedy.best_of = 1

        // Resolve the concrete whisper language code to pass into
        // `whisper_full`. Auto-detect (caller passes nil/empty) goes
        // through our own `pcm_to_mel + whisper_lang_auto_detect` pre-pass
        // because `whisper_full`'s internal detect_language = true path
        // produces zero segments on this build (see `detectLanguage`).
        let resolvedLang: String
        let autoDetected: Bool
        if let code = languageCode, !code.isEmpty {
            resolvedLang = code
            autoDetected = false
        } else if let detected = detectLanguage(ctx: ctx, samples: audioSamples, nThreads: nThreads) {
            resolvedLang = detected
            autoDetected = true
        } else {
            resolvedLang = fallbackLanguage()
            autoDetected = false
        }
        let lang = resolvedLang
        let prompt = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        let code: Int32 = lang.withCString { langPtr in
            params.language = langPtr

            let runFull: () -> Int32 = {
                audioSamples.withUnsafeBufferPointer { buf -> Int32 in
                    guard let base = buf.baseAddress else { return -1 }
                    return whisper_full(ctx, params, base, Int32(buf.count))
                }
            }

            if prompt.isEmpty {
                return runFull()
            }
            return prompt.withCString { promptPtr in
                params.initial_prompt = promptPtr
                return runFull()
            }
        }

        if code != 0 {
            return .failure(code)
        }

        // Collect segment text.
        let segmentCount = whisper_full_n_segments(ctx)
        var out = ""
        out.reserveCapacity(Int(segmentCount) * 64)
        for i in 0..<segmentCount {
            if let cstr = whisper_full_get_segment_text(ctx, i) {
                out += String(cString: cstr)
            }
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(trimmed: trimmed, raw: out, segments: segmentCount, code: code, languageUsed: lang, autoDetected: autoDetected)
    }

    deinit {
        // whisper_free is thread-safe; OpaquePointer is value-typed so this
        // nonisolated read is safe under Swift 6 strict concurrency.
        if let ctx = context {
            whisper_free(ctx)
        }
    }
}
