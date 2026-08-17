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

    /// Determinate progress is only available when the server reports content length.
    /// We surface it separately so views can choose between a linear bar and an indeterminate one.
    var progressFraction: Double? {
        switch self {
        case .downloading(let progress, _, _), .paused(let progress):
            guard let progress else { return nil }
            return min(max(progress, 0), 1)
        default:
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
/// Uses `aria2c` multi-connection segmented downloads when available for 4x–10x speedup and native pause/resume,
/// gracefully falling back to `URLSession` when `aria2c` is not installed on the system.
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
    private var activeAria2Services: [String: Aria2DownloadService] = [:]
    private var activeSessionDelegates: [String: ModelDownloadSessionDelegate] = [:]
    private var urlSessionResumeDataByFilename: [String: Data] = [:]

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

    var models: [DownloadableRuntimeModel] {
        RuntimeModelCatalog.downloadableModels
    }

    /// The path shown in Settings and opened by "Open Folder". This is always Cotabby's own writable
    /// directory because that is where downloads and imports land; additive sources such as LM Studio
    /// are read-only and surfaced only through the model picker, not this control.
    var modelsDirectoryPath: String {
        runtimeDirectoryURL.path
    }

    /// Re-reads the current search directories (including the LM Studio source when toggled) and
    /// refreshes model states.
    func refreshSearchDirectories() {
        runtimeSearchDirectories = Self.resolveSearchDirectories(primary: runtimeDirectoryURL)
        refreshModelStates()
    }

    func state(for model: DownloadableRuntimeModel) -> ModelDownloadState {
        modelStates[model.filename] ?? .idle
    }

    func refreshModelStates() {
        recomputeInstalledModelFilenames()
        let catalogFilenames = Set(models.map(\.filename))

        for model in models {
            if downloadTasks[model.filename] != nil {
                if case .downloading(let progress, let speed, let eta) = modelStates[model.filename] {
                    modelStates[model.filename] = .downloading(progress: progress, speedFormatted: speed, etaFormatted: eta)
                } else if case .paused(let progress) = modelStates[model.filename] {
                    modelStates[model.filename] = .paused(progress: progress)
                } else {
                    modelStates[model.filename] = .downloading(progress: nil)
                }
            } else if case .paused(let progress) = modelStates[model.filename] {
                modelStates[model.filename] = .paused(progress: progress)
            } else if isInstalled(model: model) {
                modelStates[model.filename] = .downloaded
            } else {
                modelStates[model.filename] = .idle
            }
        }

        var keysToRemove: [String] = []
        for (filename, state) in modelStates where !catalogFilenames.contains(filename) {
            if downloadTasks[filename] != nil {
                continue
            }
            switch state {
            case .downloading, .paused:
                break
            case .downloaded, .idle, .failed:
                if isInstalled(filename: filename) {
                    modelStates[filename] = .downloaded
                } else {
                    keysToRemove.append(filename)
                }
            }
        }
        for key in keysToRemove {
            modelStates.removeValue(forKey: key)
        }
    }

    func isModelInstalled(filename: String) -> Bool {
        isInstalled(filename: filename)
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

        let initialProgress = modelStates[model.filename]?.progressFraction
        CotabbyLogger.models.info("Starting download for \(model.filename)")
        modelStates[model.filename] = .downloading(progress: initialProgress)
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
        if let aria2Service = activeAria2Services[filename] {
            aria2Service.cancel()
        } else if let delegate = activeSessionDelegates[filename] {
            delegate.cancel()
        }

        urlSessionResumeDataByFilename.removeValue(forKey: filename)

        // Clean up any aria2 staging directory for this model
        let stagingDir = aria2StagingDirectoryURL(filename: filename)
        try? FileManager.default.removeItem(at: stagingDir)

        if let task = downloadTasks[filename] {
            task.cancel()
        } else {
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
        panel.title = "Select a GGUF Model"
        if let ggufType = UTType(filenameExtension: "gguf", conformingTo: .data) {
            panel.allowedContentTypes = [ggufType]
        }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }

        do {
            try ensureRuntimeDirectoryExists()
        } catch {
            CotabbyLogger.models.error(
                "Failed to ensure runtime directory before import: \(error.localizedDescription)",
                metadata: ["directory": .string(runtimeDirectoryURL.path)]
            )
            return
        }

        // Copy files off the main thread so multi-gigabyte GGUFs don't freeze the UI.
        let sourceURLs = panel.urls
        let destinationDirectory = runtimeDirectoryURL
        Task.detached {
            let fileManager = FileManager.default
            for sourceURL in sourceURLs {
                let destinationURL = destinationDirectory.appendingPathComponent(
                    sourceURL.lastPathComponent, isDirectory: false
                )
                if fileManager.fileExists(atPath: destinationURL.path) { continue }
                do {
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                } catch {
                    CotabbyLogger.models.error(
                        "Failed to import \(sourceURL.lastPathComponent): \(error.localizedDescription)",
                        metadata: [
                            "source": .string(sourceURL.path),
                            "destination": .string(destinationURL.path)
                        ]
                    )
                }
            }
            await MainActor.run { [weak self] in
                self?.refreshModelStates()
                self?.onModelDirectoryChanged?()
            }
        }
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

    private func performDownload(_ model: DownloadableRuntimeModel) async {
        defer {
            downloadTasks[model.filename] = nil
            activeAria2Services.removeValue(forKey: model.filename)
            activeSessionDelegates.removeValue(forKey: model.filename)
        }

        do {
            if !Aria2Locator.isAvailable {
                // Attempt on-demand provisioning of aria2c if not already available on the system
                try? await Aria2Provisioner.shared.provisionIfNeeded()
            }

            if Aria2Locator.isAvailable {
                try await performAria2Download(model)
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
                let stagingDir = aria2StagingDirectoryURL(filename: model.filename)
                try? FileManager.default.removeItem(at: stagingDir)
                modelStates[model.filename] = isInstalled(model: model) ? .downloaded : .idle
            } else {
                CotabbyLogger.models.error("Download failed for \(model.filename): \(error.localizedDescription)")
                modelStates[model.filename] = .failed(error.localizedDescription)
            }
        }
    }

    private func performAria2Download(_ model: DownloadableRuntimeModel) async throws {
        try ensureRuntimeDirectoryExists()
        let destinationURL = modelFileURL(filename: model.filename)
        let stagingDir = aria2StagingDirectoryURL(filename: model.filename)

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

        let result = try await service.download(
            from: model.downloadURL,
            filename: model.filename,
            stagingDirectory: stagingDir
        )

        let fileManager = FileManager.default
        let downloadedFile = result.downloadedFileURL

        do {
            if let expectedSize = model.expectedSizeBytes {
                try ModelFileValidator.validateCompleteness(
                    of: downloadedFile, declaredContentLength: expectedSize
                )
            }
            try ModelFileValidator.validateSize(
                of: downloadedFile, expectedBytes: model.expectedSizeBytes
            )
            try ModelFileValidator.validateSHA256(
                of: downloadedFile, expectedSHA256: model.sha256
            )
            try Self.promoteStagedFile(at: downloadedFile, to: destinationURL, fileManager: fileManager)
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
        let downloadResult = try await delegate.download(from: model.downloadURL, resumeData: resumeData)
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

        do {
            try ModelFileValidator.validateCompleteness(
                of: stagingURL, declaredContentLength: downloadResult.response.expectedContentLength
            )
            try ModelFileValidator.validateSize(
                of: stagingURL, expectedBytes: model.expectedSizeBytes
            )
            try ModelFileValidator.validateSHA256(
                of: stagingURL, expectedSHA256: model.sha256
            )
            try Self.promoteStagedFile(at: stagingURL, to: destinationURL, fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    /// Promotes a validated staged file into the install location. When a model already exists there,
    /// an atomic replace is used so a crash or error mid-promotion can never destroy the existing good
    /// model before the replacement is committed (the old delete-then-move could leave nothing
    /// installed). `replaceItemAt` removes the staged file as part of the swap.
    private static func promoteStagedFile(
        at stagingURL: URL, to destinationURL: URL, fileManager: FileManager
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

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LlamaRuntimeError.unavailable(
                "Model download failed with status code \(httpResponse.statusCode).")
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

    private func aria2StagingDirectoryURL(filename: String) -> URL {
        runtimeDirectoryURL.appendingPathComponent(".aria2-staging-\(filename)", isDirectory: true)
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

/// Bridges `URLSessionDownloadDelegate` callbacks into one async result plus incremental progress updates.
private final class ModelDownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct DownloadResult {
        let temporaryURL: URL
        let response: URLResponse
    }

    private let progressHandler: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<DownloadResult, Error>?
    private var downloadedFileURL: URL?
    private var response: URLResponse?
    private var hasCompleted = false
    private var activeDownloadTask: URLSessionDownloadTask?
    private var finishError: Error?
    private var isUserPaused = false

    init(progressHandler: @escaping @Sendable (Double?) -> Void) {
        self.progressHandler = progressHandler
    }

    func download(from url: URL, resumeData: Data? = nil) async throws -> DownloadResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let task: URLSessionDownloadTask
                if let resumeData {
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    task = session.downloadTask(with: url)
                }
                self.activeDownloadTask = task
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.activeDownloadTask?.cancel()
        }
    }

    func pause() {
        isUserPaused = true
        activeDownloadTask?.cancel(byProducingResumeData: { _ in })
    }

    func cancel() {
        isUserPaused = false
        activeDownloadTask?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress: Double?
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            progress = nil
        }

        progressHandler(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            downloadedFileURL = try DownloadFileRescuer.rescue(temporaryFileAt: location)
        } catch {
            finishError = error
        }
        response = downloadTask.response
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !hasCompleted else {
            return
        }
        hasCompleted = true

        defer {
            continuation = nil
            session.finishTasksAndInvalidate()
        }

        if isUserPaused {
            continuation?.resume(throwing: Aria2DownloadError.paused)
            return
        }

        if let failure = error ?? finishError {
            if let holdingURL = downloadedFileURL {
                DownloadFileRescuer.cleanup(holdingFileAt: holdingURL)
                downloadedFileURL = nil
            }
            continuation?.resume(throwing: failure)
            return
        }

        guard let downloadedFileURL, let response else {
            continuation?.resume(throwing: URLError(.badServerResponse))
            return
        }

        continuation?.resume(
            returning: DownloadResult(temporaryURL: downloadedFileURL, response: response))
    }
}
