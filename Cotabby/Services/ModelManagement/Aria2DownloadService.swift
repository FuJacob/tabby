import Foundation
import Logging

/// Errors that can occur during aria2c-managed downloads.
public enum Aria2DownloadError: LocalizedError, Equatable {
    case executableNotFound
    case cancelled
    case paused
    case processFailed(exitCode: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "aria2c executable was not found on the system."
        case .cancelled:
            return "Download was cancelled by the user."
        case .paused:
            return "Download was paused by the user."
        case .processFailed(let code, let message):
            return "aria2c download failed (exit code \(code)): \(message)"
        }
    }
}

/// Result returned upon successful completion of an aria2c download.
public struct Aria2DownloadResult {
    public let downloadedFileURL: URL
    public let stagingDirectoryURL: URL
}

/// Executes and monitors an `aria2c` subprocess for multi-connection resumable downloads.
///
/// Why this class exists:
/// `aria2c` provides segmented HTTP downloads (up to 8 parallel streams) and on-disk `.aria2` chunk metadata.
/// This service encapsulates `Foundation.Process` management, stdout progress pipe streaming,
/// and safe pause/resume/cancellation state transitions without exposing subprocess details to callers.
///
/// Collaborators:
/// - `Aria2Locator`: resolves the executable path.
/// - `Aria2OutputParser`: parses stdout lines into `Aria2Progress`.
/// - `ModelDownloadManager`: owns active `Aria2DownloadService` instances and binds progress to SwiftUI.
public final class Aria2DownloadService: @unchecked Sendable {
    private let progressHandler: @Sendable (Aria2Progress) -> Void
    private let lock = NSLock()
    private var process: Process?
    private var isUserPaused = false
    private var isUserCancelled = false

    public init(progressHandler: @escaping @Sendable (Aria2Progress) -> Void) {
        self.progressHandler = progressHandler
    }

    /// Downloads a model file from `url` into a dedicated staging directory.
    ///
    /// - Parameters:
    ///   - url: Remote URL to download.
    ///   - filename: Target model filename.
    ///   - stagingDirectory: Isolated staging directory for this download.
    /// - Returns: `Aria2DownloadResult` with the location of the completed file.
    public func download(
        from url: URL,
        filename: String,
        stagingDirectory: URL,
        executableURL: URL? = nil
    ) async throws -> Aria2DownloadResult {
        guard let aria2Executable = executableURL ?? Aria2Locator.executableURL() else {
            throw Aria2DownloadError.executableNotFound
        }

        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        let targetFileURL = stagingDirectory.appendingPathComponent(filename, isDirectory: false)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let proc = Process()
                proc.executableURL = aria2Executable

                // Arguments:
                // -c: Continue partial download if .aria2 file exists
                // -s 8: Split file into 8 segments
                // -x 8: Use up to 8 connections per server
                // -k 1M: Minimum split size is 1MB
                // --summary-interval=1: Emit progress to stdout every second
                // --allow-overwrite=true: Overwrite target if needed
                // --auto-file-renaming=false: Do not append .1 to filename
                // --dir: Destination directory
                // --out: Destination filename
                proc.arguments = [
                    "-c",
                    "-s", "8",
                    "-x", "8",
                    "-k", "1M",
                    "--summary-interval=1",
                    "--allow-overwrite=true",
                    "--auto-file-renaming=false",
                    "--dir=\(stagingDirectory.path)",
                    "--out=\(filename)",
                    url.absoluteString
                ]

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                proc.standardOutput = outputPipe
                proc.standardError = errorPipe

                var capturedErrorMessage = ""
                let errorLock = NSLock()

                // Read stderr in background for error diagnostics
                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                        errorLock.lock()
                        capturedErrorMessage += str
                        errorLock.unlock()
                    }
                }

                // Read stdout line by line and feed progress parser
                var outputBuffer = ""
                outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    guard let self else { return }
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

                    outputBuffer += text
                    let lines = outputBuffer.components(separatedBy: .newlines)
                    if lines.count > 1 {
                        for line in lines.dropLast() {
                            if let progress = Aria2OutputParser.parse(line: line) {
                                self.progressHandler(progress)
                            }
                        }
                        outputBuffer = lines.last ?? ""
                    }
                }

                proc.terminationHandler = { [weak self] p in
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil

                    guard let self else { return }
                    self.lock.lock()
                    let wasPaused = self.isUserPaused
                    let wasCancelled = self.isUserCancelled
                    self.process = nil
                    self.lock.unlock()

                    if wasPaused {
                        continuation.resume(throwing: Aria2DownloadError.paused)
                        return
                    }

                    if wasCancelled {
                        continuation.resume(throwing: Aria2DownloadError.cancelled)
                        return
                    }

                    if p.terminationStatus == 0 {
                        continuation.resume(
                            returning: Aria2DownloadResult(
                                downloadedFileURL: targetFileURL,
                                stagingDirectoryURL: stagingDirectory
                            )
                        )
                    } else {
                        errorLock.lock()
                        let msg = capturedErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                        errorLock.unlock()
                        continuation.resume(
                            throwing: Aria2DownloadError.processFailed(
                                exitCode: p.terminationStatus,
                                message: msg.isEmpty ? "Process terminated with exit code \(p.terminationStatus)" : msg
                            )
                        )
                    }
                }

                self.lock.lock()
                self.process = proc
                self.isUserPaused = false
                self.isUserCancelled = false
                self.lock.unlock()

                do {
                    try proc.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    /// Pauses the in-flight download gracefully, preserving `.aria2` metadata on disk.
    public func pause() {
        lock.lock()
        guard let proc = process, proc.isRunning else {
            lock.unlock()
            return
        }
        isUserPaused = true
        lock.unlock()

        // Send SIGINT so aria2c flushes its .aria2 control file before exiting
        proc.interrupt()
    }

    /// Cancels the in-flight download immediately.
    public func cancel() {
        lock.lock()
        guard let proc = process, proc.isRunning else {
            lock.unlock()
            return
        }
        isUserCancelled = true
        lock.unlock()

        proc.terminate()
    }
}
