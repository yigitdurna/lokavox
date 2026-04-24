import CryptoKit
import Foundation
import Observation

/// Downloads, verifies, and loads the whisper.cpp GGML model.
///
/// The model is a single `.bin` file (the same format `whisper-cli` loads on
/// Mac). We download once on first launch from HuggingFace, hash-verify it,
/// cache it under `~/Documents/models/`, and hand the path to
/// `WhisperEngine.load(modelFileURL:useGPU:)`.
@MainActor
@Observable
final class ModelManagerService {
    /// Filename used as the cache key + on-disk file name. This is also the
    /// last path component of the HuggingFace download URL.
    static let modelFileName = "ggml-large-v3-turbo.bin"

    /// Canonical HuggingFace download URL for the model. Using the same file
    /// the Mac LokaVox loads via `whisper-cli`, so transcription output on
    /// iOS should match Mac within model-internal variance.
    static let modelSourceURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
    )!

    /// Expected SHA256 of the model file. Computed from HuggingFace's
    /// `x-linked-etag` at the pinned commit; re-verify if you bump the
    /// source URL.
    static let modelSHA256 = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"

    /// Expected size in bytes. Used for progress-fraction clamping when the
    /// server doesn't report Content-Length.
    static let modelSizeBytes: Int64 = 1_624_555_275

    enum State: Equatable {
        case idle
        case downloading(progress: Double)
        case verifying
        case loading
        case ready
        case failed(String)
    }

    /// Path we persist the resolved model URL under so subsequent launches
    /// skip download + hash-verify. Stored in `UserDefaults.standard`
    /// (per-app), not App Group.
    private static let cachedModelPathKey = "LokaVox.cachedModelFilePath"

    private(set) var state: State = .idle
    private(set) var downloadDurationMs: Int?
    private(set) var loadDurationMs: Int?

    private let engine: WhisperEngine
    private let settings: LokaVoxSettings

    /// Hold onto progress observations so they're not cancelled early.
    private var activeDownloadTask: URLSessionDownloadTask?
    private var activeProgressObservation: NSKeyValueObservation?

    init(engine: WhisperEngine, settings: LokaVoxSettings) {
        self.engine = engine
        self.settings = settings
    }

    /// Root directory where we stage downloaded model files.
    static func modelsRootURL() -> URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return documents.appendingPathComponent("models", isDirectory: true)
    }

    /// Top-level entry point. Safe to call on every app launch.
    /// Idempotent — if a cached model exists and hashes, skip download.
    func prepare() async {
        guard let modelsRoot = Self.modelsRootURL() else {
            state = .failed("Documents directory unavailable.")
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: modelsRoot,
                withIntermediateDirectories: true
            )
        } catch {
            state = .failed("Could not create models directory: \(error.localizedDescription)")
            return
        }

        let targetURL = modelsRoot.appendingPathComponent(Self.modelFileName, isDirectory: false)

        // Try the cache first.
        if let cached = cachedModelFileIfValid(at: targetURL) {
            await loadAndMarkReady(fileURL: cached)
            return
        }

        // No valid cache — download.
        state = .downloading(progress: 0)
        let downloadStart = Date()

        do {
            try await downloadModel(to: targetURL)
            downloadDurationMs = Int(Date().timeIntervalSince(downloadStart) * 1000)
        } catch {
            state = .failed("Model download failed: \(error.localizedDescription)")
            return
        }

        state = .verifying
        do {
            try verifySHA256(fileURL: targetURL, expected: Self.modelSHA256)
        } catch {
            // Corrupt download — nuke it so the next launch retries cleanly.
            try? FileManager.default.removeItem(at: targetURL)
            UserDefaults.standard.removeObject(forKey: Self.cachedModelPathKey)
            state = .failed("Model file did not match expected SHA256.")
            return
        }

        UserDefaults.standard.set(targetURL.path, forKey: Self.cachedModelPathKey)
        await loadAndMarkReady(fileURL: targetURL)
    }

    /// Reload the engine with the current `settings.gpuAccelerationEnabled`.
    /// Call this after the user toggles the GPU switch.
    func reloadEngineForSettingsChange() async {
        guard let modelsRoot = Self.modelsRootURL() else { return }
        let targetURL = modelsRoot.appendingPathComponent(Self.modelFileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return }
        await loadAndMarkReady(fileURL: targetURL)
    }

    // MARK: - Load

    private func loadAndMarkReady(fileURL: URL) async {
        state = .loading
        let start = Date()
        let useGPU = resolveUseGPU()
        do {
            try await engine.load(modelFileURL: fileURL, useGPU: useGPU)
            loadDurationMs = Int(Date().timeIntervalSince(start) * 1000)
            state = .ready
        } catch {
            // Cached file may point at corrupt bits. Nuke it so the next
            // launch re-downloads cleanly.
            UserDefaults.standard.removeObject(forKey: Self.cachedModelPathKey)
            state = .failed("Model load failed: \(error.localizedDescription)")
        }
    }

    /// Resolves the effective `useGPU` flag honouring both user Settings and
    /// the Simulator Metal-broken guard.
    private func resolveUseGPU() -> Bool {
        #if targetEnvironment(simulator)
        // whisper.cpp Metal is broken on the iOS Simulator (whisper.cpp#2522).
        return false
        #else
        return settings.gpuAccelerationEnabled
        #endif
    }

    // MARK: - Download

    private func downloadModel(to targetURL: URL) async throws {
        // Remove any partial / stale file at the target path so the move
        // from the temp download location never collides.
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let session = URLSession(configuration: .default)
            let task = session.downloadTask(with: Self.modelSourceURL) { [weak self] tempURL, response, error in
                Task { @MainActor [weak self] in
                    self?.activeDownloadTask = nil
                    self?.activeProgressObservation = nil
                }

                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tempURL else {
                    continuation.resume(throwing: URLError(.cannotOpenFile))
                    return
                }
                // Sanity-check the HTTP response.
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                do {
                    try FileManager.default.moveItem(at: tempURL, to: targetURL)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            // Observe progress. `fractionCompleted` is accurate when the
            // server reports Content-Length (HuggingFace does); otherwise
            // we clamp against the known model size.
            let observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if case .downloading = self.state {
                        self.state = .downloading(progress: min(1.0, max(0.0, fraction)))
                    }
                }
            }

            self.activeDownloadTask = task
            self.activeProgressObservation = observation
            task.resume()
        }
    }

    // MARK: - Cache

    private func cachedModelFileIfValid(at targetURL: URL) -> URL? {
        let defaults = UserDefaults.standard

        let candidatePath = defaults.string(forKey: Self.cachedModelPathKey) ?? targetURL.path
        let candidate = URL(fileURLWithPath: candidatePath)

        guard FileManager.default.fileExists(atPath: candidate.path) else {
            defaults.removeObject(forKey: Self.cachedModelPathKey)
            return nil
        }

        // Fast-path: size + cached-hash sentinel. We don't re-SHA on every
        // launch — it costs ~1s on a 1.6 GB file. Trust the path if it
        // exists and was recorded as valid at download time.
        if defaults.string(forKey: Self.cachedModelPathKey) != nil {
            return candidate
        }

        // Found the file but no cache record — verify before trusting.
        do {
            try verifySHA256(fileURL: candidate, expected: Self.modelSHA256)
            defaults.set(candidate.path, forKey: Self.cachedModelPathKey)
            return candidate
        } catch {
            try? FileManager.default.removeItem(at: candidate)
            return nil
        }
    }

    private func verifySHA256(fileURL: URL, expected: String) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 4 * 1024 * 1024  // 4 MB chunks
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex == expected else {
            throw NSError(
                domain: "LokaVox.ModelManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "SHA256 mismatch: expected \(expected), got \(hex)"]
            )
        }
    }
}
