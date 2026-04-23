import Foundation
import Observation
import WhisperKit

/// Downloads and loads the Whisper model for LokaVox.
/// Writes the model into the app's Documents directory.
@MainActor
@Observable
final class ModelManagerService {
    /// Identifier used by WhisperKit to locate the variant folder inside
    /// argmaxinc/whisperkit-coreml on HuggingFace.
    ///
    /// Using the v20240930 turbo recompile, quantized to 632 MB. The plain
    /// `openai_whisper-large-v3_turbo` was built against an older ANE
    /// compiler and fails on current iPhone ANE with "Program load failure
    /// (0x20004) — Must re-compile the E5 bundle". The v20240930 variants
    /// are Argmax's iPhone-ANE rebuild; the `_632MB` quantization keeps
    /// turbo quality while fitting in the ANE compile budget that the
    /// non-quantized turbo blows past.
    static let modelVariant = "openai_whisper-large-v3-v20240930_turbo_632MB"

    enum State: Equatable {
        case idle
        case downloading(progress: Double)
        case loading
        case ready
        case failed(String)
    }

    /// Key under which we persist the resolved model folder path so subsequent
    /// launches skip the download step. Stored in `UserDefaults.standard`
    /// (per-app), not the App Group suite — App Group `UserDefaults` emits a
    /// `kCFPreferencesAnyUser`-with-container error and silently fails to
    /// persist on iOS 17+. The keyboard extension does not need this key.
    private static let cachedModelPathKey = "LokaVox.cachedModelFolderPath"

    private(set) var state: State = .idle
    private(set) var downloadDurationMs: Int?
    private(set) var loadDurationMs: Int?

    private let engine: WhisperEngine

    init(engine: WhisperEngine) {
        self.engine = engine
    }

    /// Root directory where WhisperKit is asked to stage downloaded model
    /// files. Lives in the app's Documents directory (per-app, not App Group).
    /// Why: App Group container caches were observed being evicted mid-compile
    /// by iOS, corrupting the partial ANE state; the per-app Documents
    /// directory is not subject to the same aggressive reclaim. Once the
    /// keyboard needs to read these files we will revisit (likely a copy or
    /// shared file coordinator).
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
    /// - Idempotent: if a cached model folder exists on disk, skips download.
    /// - After this returns, `state == .ready` on success or `.failed` on error.
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

        let cached = cachedModelFolder() ?? findExistingVariantFolder(under: modelsRoot)
        let modelFolder: URL
        if let cached {
            UserDefaults.standard.set(cached.path, forKey: Self.cachedModelPathKey)
            modelFolder = cached
        } else {
            state = .downloading(progress: 0)
            let downloadStart = Date()
            do {
                let resolved = try await WhisperKit.download(
                    variant: Self.modelVariant,
                    downloadBase: modelsRoot,
                    useBackgroundSession: false,
                    progressCallback: { @Sendable [weak self] progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if case .downloading = self.state {
                                self.state = .downloading(progress: fraction)
                            }
                        }
                    }
                )
                downloadDurationMs = Int(Date().timeIntervalSince(downloadStart) * 1000)
                UserDefaults.standard.set(resolved.path, forKey: Self.cachedModelPathKey)
                modelFolder = resolved
            } catch {
                state = .failed("Model download failed: \(error.localizedDescription)")
                return
            }
        }

        state = .loading
        let loadStart = Date()
        do {
            try await engine.load(modelFolder: modelFolder)
            loadDurationMs = Int(Date().timeIntervalSince(loadStart) * 1000)
            state = .ready
        } catch {
            // Cached path may point at corrupt files (e.g. interrupted ANE
            // compile). Clear it so the next launch re-downloads cleanly.
            UserDefaults.standard.removeObject(forKey: Self.cachedModelPathKey)
            state = .failed("Model load failed: \(error.localizedDescription)")
        }
    }

    /// Walks the models root looking for a directory named `Self.modelVariant`.
    /// Used as a one-shot recovery path when we know a prior run wrote the
    /// variant somewhere under `modelsRoot` but we didn't record the exact URL.
    private func findExistingVariantFolder(under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let url as URL in enumerator {
            if url.lastPathComponent == Self.modelVariant,
               (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
               let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
               !contents.isEmpty {
                return url
            }
        }
        return nil
    }

    /// Returns the previously-downloaded model folder if it still exists on disk
    /// AND matches the current `modelVariant`. Invalidates the cached path on miss
    /// (folder gone, variant mismatched after a swap).
    private func cachedModelFolder() -> URL? {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: Self.cachedModelPathKey) else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists && isDir.boolValue && url.lastPathComponent == Self.modelVariant {
            return url
        }
        defaults.removeObject(forKey: Self.cachedModelPathKey)
        return nil
    }
}
