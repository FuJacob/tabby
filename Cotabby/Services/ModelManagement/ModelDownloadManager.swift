import AppKit
import Combine
import Foundation
import Logging
import UniformTypeIdentifiers

/// One model's current install/download lifecycle state in local storage.
enum ModelDownloadState: Equatable {
    case idle
    case downloading(progress: Double?, speedFormatted: String? = nil, etaFormatted: String? = nil)
    case paused(progress: Double?)
    case downloaded
    case failed(String)

    var statusText: String {
        switch self {
        case .idle:
            return "Not installed"
        case .downloading(let progress, let speed, let eta):
            if let progress {
                let percent = Int((progress * 100).rounded())
                if let speed, let eta {
                    return "Downloading \(percent)% (\(speed) · ETA \(eta))"
                } else if let speed {
                    return "Downloading \(percent)% (\(speed))"
                }
                return "Downloading \(percent)%"
            }
            return "Downloading"
        case .paused(let progress):
            if let progress {
                return "Paused (\(Int((progress * 100).rounded()))%)"
            }
            return "Paused"
        case .downloaded:
            return "Installed"
        case .failed(let message):
            return message
        }
    }

    var progressFraction: Double? {
        switch self {
        case .downloading(let progress, _, _):
            guard let progress else {
                return nil
            }
            return min(max(progress, 0), 1)
        case .paused(let progress):
            guard let progress else {
                return nil
            }
            return min(max(progress, 0), 1)
        case .idle, .downloaded, .failed:
            return nil
        }
    }

    var isDownloading: Bool {
        if case .downloading = self {
            return true
        }
        return false
    }

    var isPaused: Bool {
        if case .paused = self {
            return true
        }
        return false
    }
}

/// Downloads model files on demand into a user-writable runtime directory.
/// This decouples app shipping from model shipping so model updates do not require app updates.
///
/// Uses `aria2c` for segmented, resumable transfers when available and falls back to URLSession.
@MainActor
final class ModelDownloadManager: ObservableObject {
    @Published private(set) var modelStates: [String: ModelDownloadState] = [:]

    var onModelDirectoryChanged: (() -> Void)?

    private let runtimeDirectoryURL: URL
    private var runtimeSearchDirectories: [URL]
    /// GGUF filenames discovered across every search directory, recomputed whenever the search set
    /// or on-disk contents change. Cached so the per-catalog-model install check in
    /// `refreshModelStates` does not re-walk the (recursively scanned) directories once per model.
    private var installedModelFilenames: Set<String> = []
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var activeModelsByFilename: [String: DownloadableRuntimeModel] = [:]
    private var activeAria2Services: [String: Aria2DownloadService] = [:]
    private var activeSessionDelegates: [String: ModelDownloadSessionDelegate] = [:]
    private var urlSessionResumeDataByFilename: [String: Data] = [:]

    private enum RequestedOutcome: Equatable {
        case paused
        case cancelled
    }
    private var requestedOutcomes: [String: RequestedOutcome] = [:]

    init(runtimeDirectoryURL: URL? = nil) {
        let primaryDirectoryURL =
            runtimeDirectoryURL ?? BundledRuntimeLocator.userRuntimeDirectoryURL()
        self.runtimeDirectoryURL = primaryDirectoryURL
        runtimeSearchDirectories = Self.resolveSearchDirectories(primary: primaryDirectoryURL)

        refreshModelStates()
    }

    /// Cotabby's own directory first (authoritative + download target), then any additive sources
    /// (the LM Studio library when enabled), deduped by normalized path.
    private static func resolveSearchDirectories(primary: URL) -> [URL] {
        var directories = [primary]
        for directoryURL in BundledRuntimeLocator.runtimeSearchDirectories() {
            let normalizedPath = directoryURL.standardizedFileURL.path
            if !directories.contains(where: { $0.standardizedFileURL.path == normalizedPath }) {
                directories.append(directoryURL)
            }
        }
        return directories
    }

    /// Reloads the set of search directories (e.g. after the LM Studio toggle changes in Settings).
    /// Updates the installed-filename cache and all model states to match the new search paths.
    func refreshSearchDirectories() {
        runtimeSearchDirectories = Self.resolveSearchDirectories(primary: runtimeDirectoryURL)
        refreshModelStates()
    }

    var models: [DownloadableRuntimeModel] {
        RuntimeModelCatalog.downloadableModels
    }

    func state(for model: DownloadableRuntimeModel) -> ModelDownloadState {
        modelStates[model.filename] ?? (isInstalled(model: model) ? .downloaded : .idle)
    }

    /// Re-reads installed models from all active search directories and updates `@Published` state.
    /// Preserves in-flight `.downloading` and `.paused` states so a refresh during transfer never drops the progress bar.
    func refreshModelStates() {
        recomputeInstalledModelFilenames()
        let catalogFilenames = Set(models.map(\.filename))

        for model in models {
            let currentState = modelStates[model.filename]
            if case .downloading = currentState {
                continue
            }
            if case .paused = currentState {
                continue
            }

            if isInstalled(model: model) {
                modelStates[model.filename] = .downloaded
            } else if currentState == .downloaded {
                modelStates[model.filename] = .idle
            }
        }

        // HuggingFace models are created dynamically rather than appearing in the curated catalog.
        // Reconcile those keys too, or a deleted dynamic model remains stuck in `.downloaded`.
        let dynamicFilenames = modelStates.keys.filter { !catalogFilenames.contains($0) }
        for filename in dynamicFilenames {
            switch modelStates[filename] {
            case .downloading, .paused:
                continue
            case .idle, .downloaded, .failed, nil:
                if isInstalled(filename: filename) {
                    modelStates[filename] = .downloaded
                } else {
                    modelStates.removeValue(forKey: filename)
                }
            }
        }
    }

    /// True when any configured directory holds a file matching `filename` or any known alias.
    func isModelInstalled(filename: String) -> Bool {
        isInstalled(filename: filename)
    }

    /// Returns the active downloaded model options from the primary directory.
    func installedModelOptions() -> [RuntimeModelOption] {
        let discovered = BundledRuntimeLocator.discoverGGUFModelURLs(in: runtimeDirectoryURL)
        return discovered.map {
            RuntimeModelOption(
                filename: $0.lastPathComponent,
                url: $0
            )
        }.sorted { $0.displayName < $1.displayName }
    }

    /// The path shown in Settings and opened by "Open Folder". This is always Cotabby's own writable
    /// directory because that is where downloads and imports land; additive sources such as LM Studio
    /// are read-only and surfaced only through the model picker, not this control.
    var modelsDirectoryPath: String {
        runtimeDirectoryURL.path
    }

    /// Returns `true` only when the model lives in Cotabby's user-writable model directory.
    func canDeleteModel(filename: String) -> Bool {
        FileManager.default.fileExists(atPath: modelFileURL(filename: filename).path)
    }

    /// Removes one model from the user-managed runtime directory.
    func deleteModel(filename: String) {
        let targetURL = modelFileURL(filename: filename)

        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: targetURL)
            refreshModelStates()
            onModelDirectoryChanged?()
        } catch {
            CotabbyLogger.models.error("Failed to delete model \(filename): \(error.localizedDescription)")
        }
    }

    /// Deletes a downloaded model file from the primary runtime directory.
    func deleteModel(_ model: RuntimeModelOption) throws {
        deleteModel(filename: model.filename)
    }

    func download(_ model: DownloadableRuntimeModel) {
        guard downloadTasks[model.filename] == nil else {
            CotabbyLogger.models.debug("Download already in progress for \(model.filename)")
            return
        }

        if isInstalled(model: model) {
            CotabbyLogger.models.debug("Model \(model.filename) already installed, skipping download")
            modelStates[model.filename] = .downloaded
            return
        }

        requestedOutcomes.removeValue(forKey: model.filename)
        let previousModel = activeModelsByFilename[model.filename]
        let isSameSource = previousModel?.downloadURL == model.downloadURL
        if let previousModel, !isSameSource {
            // Resume data is source-specific even when two repositories use the same leaf filename.
            try? FileManager.default.removeItem(at: aria2StagingDirectoryURL(for: previousModel))
            urlSessionResumeDataByFilename.removeValue(forKey: model.filename)
        }

        let initialProgress = isSameSource ? modelStates[model.filename]?.progressFraction : nil
        CotabbyLogger.models.info("Starting download for \(model.filename)")
        modelStates[model.filename] = .downloading(progress: initialProgress)
        activeModelsByFilename[model.filename] = model
        let task = Task { [weak self] in
            guard let self else {
                return
            }

            await self.performDownload(model)
        }
        downloadTasks[model.filename] = task
    }

    /// Pauses an in-flight download, saving partial metadata so it can be resumed later.
    func pause(filename: String) {
        guard downloadTasks[filename] != nil else {
            return
        }
        requestedOutcomes[filename] = .paused
        if let aria2Service = activeAria2Services[filename] {
            aria2Service.pause()
        } else if let delegate = activeSessionDelegates[filename] {
            delegate.pause()
        } else if let task = downloadTasks[filename] {
            task.cancel()
        }
    }

    /// Resumes a previously paused download.
    func resume(_ model: DownloadableRuntimeModel) {
        download(model)
    }

    /// User-initiated cancel of an in-flight or paused model download.
    func cancel(filename: String) {
        requestedOutcomes[filename] = .cancelled
        if let aria2Service = activeAria2Services[filename] {
            aria2Service.cancel()
        } else if let delegate = activeSessionDelegates[filename] {
            delegate.cancel()
        }

        urlSessionResumeDataByFilename.removeValue(forKey: filename)

        if let task = downloadTasks[filename] {
            // Let the backend stop before deleting its files. Removing a staging directory while
            // aria2c is still flushing its control file can recreate debris or corrupt the pause.
            task.cancel()
        } else {
            if let model = activeModelsByFilename[filename] {
                removeResumeArtifacts(for: model)
            } else {
                try? FileManager.default.removeItem(
                    at: legacyAria2StagingDirectoryURL(filename: filename)
                )
            }
            requestedOutcomes.removeValue(forKey: filename)
            activeModelsByFilename.removeValue(forKey: filename)
            modelStates[filename] = isInstalled(filename: filename) ? .downloaded : .idle
        }
    }

    func openModelsDirectory() {
        do {
            try ensureRuntimeDirectoryExists()
        } catch {
            CotabbyLogger.models.error(
                "Failed to ensure runtime directory before opening: \(error.localizedDescription)",
                metadata: ["directory": .string(runtimeDirectoryURL.path)]
            )
            return
        }

        NSWorkspace.shared.open(runtimeDirectoryURL)
    }

    func importModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.prompt = "Import"
        panel.message = "Choose .gguf models to import into Cotabby"

        guard panel.runModal() == .OK else {
            return
        }

        let sourceURLs = panel.urls
        guard !sourceURLs.isEmpty else {
            return
        }

        let destinationDirectory = runtimeDirectoryURL

        Task.detached {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(
                    at: destinationDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                CotabbyLogger.models.error(
                    "Failed to create the model directory: \(error.localizedDescription)",
                    metadata: ["destination": .string(destinationDirectory.path)]
                )
                return
            }

            var importedAnyModel = false
            for sourceURL in sourceURLs {
                let targetURL = destinationDirectory.appendingPathComponent(
                    sourceURL.lastPathComponent,
                    isDirectory: false
                )
                do {
                    // Resolve symlinks before comparing. A selected alias can otherwise point at
                    // the installed target and make a delete-then-copy sequence delete its source.
                    let canonicalSource = sourceURL.resolvingSymlinksInPath().standardizedFileURL
                    let canonicalTarget = targetURL.resolvingSymlinksInPath().standardizedFileURL
                    if canonicalSource == canonicalTarget {
                        continue
                    }

                    // Import is intentionally non-destructive. Replacing an installed multi-GB
                    // model without an explicit overwrite prompt risks losing a known-good file.
                    if fileManager.fileExists(atPath: targetURL.path) {
                        continue
                    }

                    let stagingURL = destinationDirectory.appendingPathComponent(
                        ".import-\(UUID().uuidString)",
                        isDirectory: false
                    )
                    defer { try? fileManager.removeItem(at: stagingURL) }
                    try fileManager.copyItem(at: sourceURL, to: stagingURL)

                    // Another import may have won the race while this copy was running.
                    guard !fileManager.fileExists(atPath: targetURL.path) else {
                        continue
                    }
                    try fileManager.moveItem(at: stagingURL, to: targetURL)
                    importedAnyModel = true
                    CotabbyLogger.models.info(
                        "Imported model: \(sourceURL.lastPathComponent)",
                        metadata: ["destination": .string(targetURL.path)]
                    )
                } catch {
                    CotabbyLogger.models.error(
                        "Failed to import \(sourceURL.lastPathComponent): \(error.localizedDescription)",
                        metadata: [
                            "source": .string(sourceURL.path),
                            "destination": .string(targetURL.path)
                        ]
                    )
                }
            }

            guard importedAnyModel else {
                return
            }
            await MainActor.run { [weak self] in
                self?.refreshModelStates()
                self?.onModelDirectoryChanged?()
            }
        }
    }

    private func performDownload(_ model: DownloadableRuntimeModel) async {
        defer {
            downloadTasks[model.filename] = nil
            activeAria2Services.removeValue(forKey: model.filename)
            activeSessionDelegates.removeValue(forKey: model.filename)
            requestedOutcomes.removeValue(forKey: model.filename)
            switch modelStates[model.filename] {
            case .paused, .failed:
                break
            case .idle, .downloading, .downloaded, nil:
                activeModelsByFilename.removeValue(forKey: model.filename)
            }
        }

        do {
            let aria2ExecutableURL = await resolveAria2Executable()

            if requestedOutcomes[model.filename] == .paused {
                throw Aria2DownloadError.paused
            }
            if requestedOutcomes[model.filename] == .cancelled || Task.isCancelled {
                throw CancellationError()
            }

            if let aria2ExecutableURL {
                try await performAria2Download(model, executableURL: aria2ExecutableURL)
            } else {
                try await performURLSessionDownload(model)
            }

            CotabbyLogger.models.info("Download complete for \(model.filename)")
            // Keep the discovered-filename cache in step with the new file on disk so an immediate
            // re-`download(_:)` of the same model is recognized as installed instead of re-fetched.
            recomputeInstalledModelFilenames()
            modelStates[model.filename] = .downloaded
            onModelDirectoryChanged?()
        } catch {
            if DownloadOutcomeClassifier.isUserPause(error) {
                CotabbyLogger.models.info("Download paused by user for \(model.filename)")
                let currentProgress = modelStates[model.filename]?.progressFraction
                modelStates[model.filename] = .paused(progress: currentProgress)
            } else if DownloadOutcomeClassifier.isUserCancellation(error) {
                CotabbyLogger.models.info("Download cancelled by user for \(model.filename)")
                removeResumeArtifacts(for: model)
                modelStates[model.filename] = isInstalled(model: model) ? .downloaded : .idle
            } else {
                CotabbyLogger.models.error("Download failed for \(model.filename): \(error.localizedDescription)")
                modelStates[model.filename] = .failed(error.localizedDescription)
            }
        }
    }

    /// Provisioning is an optimization, so a genuine setup failure selects URLSession. Task
    /// cancellation is also absorbed here long enough for `performDownload` to publish pause or
    /// cancel according to the manager's recorded user intent.
    private func resolveAria2Executable() async -> URL? {
        if let executableURL = Aria2Locator.executableURL() {
            return executableURL
        }

        do {
            return try await Aria2Provisioner.shared.provisionIfNeeded()
        } catch {
            if !Task.isCancelled {
                CotabbyLogger.models.debug(
                    "aria2 is unavailable; using URLSession: \(error.localizedDescription)"
                )
            }
            return nil
        }
    }

    private func performAria2Download(
        _ model: DownloadableRuntimeModel,
        executableURL: URL
    ) async throws {
        try ensureRuntimeDirectoryExists()
        let destinationURL = modelFileURL(filename: model.filename)
        let stagingDir = aria2StagingDirectoryURL(for: model)

        let service = Aria2DownloadService { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.downloadTasks[model.filename] != nil else { return }
                self.modelStates[model.filename] = .downloading(
                    progress: progress.progressFraction,
                    speedFormatted: progress.speedFormatted,
                    etaFormatted: progress.etaFormatted
                )
            }
        }
        activeAria2Services[model.filename] = service

        let downloadedFile = try await service.download(
            from: model.downloadURL,
            filename: model.filename,
            stagingDirectory: stagingDir,
            executableURL: executableURL
        )

        let fileManager = FileManager.default
        do {
            try await Self.validateAndPromoteStagedFile(
                downloadedFile,
                to: destinationURL,
                declaredContentLength: model.expectedSizeBytes,
                expectedSize: model.expectedSizeBytes,
                expectedSHA256: model.sha256
            )
            try? fileManager.removeItem(at: stagingDir)
        } catch {
            try? fileManager.removeItem(at: stagingDir)
            throw error
        }
    }

    private func performURLSessionDownload(_ model: DownloadableRuntimeModel) async throws {
        try ensureRuntimeDirectoryExists()
        let destinationURL = modelFileURL(filename: model.filename)
        let delegate = ModelDownloadSessionDelegate { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.downloadTasks[model.filename] != nil else { return }
                self.modelStates[model.filename] = .downloading(progress: progress)
            }
        }
        activeSessionDelegates[model.filename] = delegate

        let resumeData = urlSessionResumeDataByFilename[model.filename]
        let downloadResult: ModelDownloadSessionDelegate.DownloadResult
        do {
            downloadResult = try await delegate.download(
                from: model.downloadURL,
                resumeData: resumeData
            )
        } catch let interruption as URLSessionDownloadInterruption {
            switch interruption {
            case .paused(let newResumeData):
                if let newResumeData {
                    urlSessionResumeDataByFilename[model.filename] = newResumeData
                }
                throw Aria2DownloadError.paused
            }
        } catch {
            // Invalid or stale resume data must not poison every subsequent Retry attempt.
            urlSessionResumeDataByFilename.removeValue(forKey: model.filename)
            throw error
        }
        let fileManager = FileManager.default
        let temporaryURL = downloadResult.temporaryURL

        urlSessionResumeDataByFilename.removeValue(forKey: model.filename)

        do {
            try Task.checkCancellation()
            try validate(response: downloadResult.response)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        let stagingURL = runtimeDirectoryURL.appendingPathComponent(
            "\(model.filename).staging-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try fileManager.moveItem(at: temporaryURL, to: stagingURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        let responseLength = downloadResult.response.expectedContentLength
        let declaredContentLength = downloadResult.expectedFileSize > 0
            ? downloadResult.expectedFileSize
            : responseLength
        do {
            try await Self.validateAndPromoteStagedFile(
                stagingURL,
                to: destinationURL,
                declaredContentLength: declaredContentLength,
                expectedSize: model.expectedSizeBytes,
                expectedSHA256: model.sha256
            )
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    /// Promotes a validated staged file into the install location. When a model already exists there,
    /// an atomic replace is used so a crash or error mid-promotion can never destroy the existing good
    /// model before the replacement is committed (the old delete-then-move could leave nothing
    /// installed). `replaceItemAt` removes the staged file as part of the swap.
    private nonisolated static func validateAndPromoteStagedFile(
        _ stagingURL: URL,
        to destinationURL: URL,
        declaredContentLength: Int64?,
        expectedSize: Int64?,
        expectedSHA256: String?
    ) async throws {
        let validationTask = Task.detached(priority: .utility) {
            if let declaredContentLength {
                try ModelFileValidator.validateCompleteness(
                    of: stagingURL,
                    declaredContentLength: declaredContentLength
                )
            }
            try ModelFileValidator.validateSize(of: stagingURL, expectedBytes: expectedSize)
            try ModelFileValidator.validateSHA256(of: stagingURL, expectedSHA256: expectedSHA256)
            try Self.promoteStagedFile(at: stagingURL, to: destinationURL)
        }

        try await withTaskCancellationHandler {
            try await validationTask.value
        } onCancel: {
            validationTask.cancel()
        }
    }

    private nonisolated static func promoteStagedFile(
        at stagingURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            return
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw LlamaRuntimeError.unavailable(
                "Model download failed with status code \(httpResponse.statusCode)."
            )
        }
    }

    private func ensureRuntimeDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: runtimeDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func modelFileURL(filename: String) -> URL {
        runtimeDirectoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    /// Resolves an isolated, URL-unique staging directory for a model download to prevent cross-repo collisions.
    private func aria2StagingDirectoryURL(for model: DownloadableRuntimeModel) -> URL {
        Aria2StagingDirectoryResolver.directory(
            in: runtimeDirectoryURL,
            downloadURL: model.downloadURL,
            filename: model.filename
        )
    }

    /// Older builds used a filename-only directory. It is safe to remove that one exact path,
    /// but never enumerate suffix matches because other repositories may use the same filename.
    private func legacyAria2StagingDirectoryURL(filename: String) -> URL {
        Aria2StagingDirectoryResolver.legacyDirectory(
            in: runtimeDirectoryURL,
            filename: filename
        )
    }

    /// Removes only the active source's resume state after its backend has stopped.
    private func removeResumeArtifacts(for model: DownloadableRuntimeModel) {
        urlSessionResumeDataByFilename.removeValue(forKey: model.filename)
        try? FileManager.default.removeItem(at: aria2StagingDirectoryURL(for: model))
        try? FileManager.default.removeItem(
            at: legacyAria2StagingDirectoryURL(filename: model.filename)
        )
    }

    private func isInstalled(model: DownloadableRuntimeModel) -> Bool {
        model.allKnownFilenames.contains(where: isInstalled(filename:))
    }

    private func isInstalled(filename: String) -> Bool {
        installedModelFilenames.contains(filename)
    }

    /// Rebuilds the discovered-filename cache by recursively scanning every search directory.
    private func recomputeInstalledModelFilenames() {
        var filenames: Set<String> = []
        for directoryURL in runtimeSearchDirectories {
            for modelURL in BundledRuntimeLocator.discoverGGUFModelURLs(in: directoryURL) {
                filenames.insert(modelURL.lastPathComponent)
            }
        }
        installedModelFilenames = filenames
    }
}
