import Foundation
import Logging

nonisolated enum Aria2ProvisioningError: LocalizedError, Equatable {
    case homebrewUnavailable
    case installFailed
    case installTimedOut

    var errorDescription: String? {
        switch self {
        case .homebrewUnavailable:
            return "Homebrew is not available, so Cotabby will use its standard downloader."
        case .installFailed:
            return "Homebrew could not install aria2. Cotabby will use its standard downloader."
        case .installTimedOut:
            return "Installing aria2 timed out. Cotabby will use its standard downloader."
        }
    }
}

/// Coalesces one bounded Homebrew installation when aria2c is not already available.
/// A verified standalone macOS artifact is not published by aria2, so Macs without Homebrew
/// deliberately fall back to URLSession instead of copying a dynamically linked bottle binary.
nonisolated final class Aria2Provisioner: @unchecked Sendable {
    typealias BrewLocator = @Sendable () -> URL?
    typealias Installer = @Sendable (URL) async throws -> Bool

    static let shared = Aria2Provisioner()

    private let fileManager: FileManager
    private let brewLocator: BrewLocator
    private let installer: Installer
    private let lock = NSLock()
    private var activeTask: Task<URL, Error>?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        brewLocator = Self.defaultBrewExecutable
        installer = Self.installWithHomebrew
    }

    init(
        fileManager: FileManager,
        brewLocator: @escaping BrewLocator,
        installer: @escaping Installer
    ) {
        self.fileManager = fileManager
        self.brewLocator = brewLocator
        self.installer = installer
    }

    /// Returns an existing executable or installs aria2 once for all concurrent callers.
    func provisionIfNeeded() async throws -> URL {
        if let existingURL = Aria2Locator.executableURL(fileManager: fileManager) {
            return existingURL
        }

        let selection: (task: Task<URL, Error>, isOwner: Bool) = lock.withLock {
            if let activeTask {
                return (activeTask, false)
            }

            let fileManager = self.fileManager
            let brewLocator = self.brewLocator
            let installer = self.installer
            let task = Task<URL, Error> {
                try await Self.performProvision(
                    fileManager: fileManager,
                    brewLocator: brewLocator,
                    installer: installer
                )
            }
            activeTask = task
            return (task, true)
        }

        defer {
            if selection.isOwner {
                lock.withLock {
                    activeTask = nil
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await selection.task.value
        } onCancel: {
            selection.task.cancel()
        }
    }

    private static func performProvision(
        fileManager: FileManager,
        brewLocator: BrewLocator,
        installer: Installer
    ) async throws -> URL {
        guard let brewURL = brewLocator() else {
            throw Aria2ProvisioningError.homebrewUnavailable
        }
        guard try await installer(brewURL),
              let executableURL = Aria2Locator.executableURL(fileManager: fileManager) else {
            throw Aria2ProvisioningError.installFailed
        }

        CotabbyLogger.runtime.info("Installed aria2 with Homebrew at \(executableURL.path)")
        return executableURL
    }

    private static func defaultBrewExecutable() -> URL? {
        let fileManager = FileManager.default
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func installWithHomebrew(_ brewURL: URL) async throws -> Bool {
        try await installWithHomebrew(brewURL, timeout: .seconds(120))
    }

    static func installWithHomebrew(_ brewURL: URL, timeout: Duration) async throws -> Bool {
        let process = Process()
        process.executableURL = brewURL
        process.arguments = ["install", "aria2"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["NONINTERACTIVE"] = "1"
        process.environment = environment

        let execution = BlockingProcessExecution(process: process)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask {
                    try await Task.detached(priority: .utility) {
                        try execution.runAndWait()
                    }.value
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw Aria2ProvisioningError.installTimedOut
                }

                defer {
                    group.cancelAll()
                    execution.cancel()
                }
                guard let status = try await group.next() else {
                    throw Aria2ProvisioningError.installFailed
                }
                try Task.checkCancellation()
                return status == 0
            }
        } onCancel: {
            execution.cancel()
        }
    }
}

/// Runs the blocking `waitUntilExit` call on a detached worker and closes cancellation races.
nonisolated private final class BlockingProcessExecution: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var cancellationRequested = false

    init(process: Process) {
        self.process = process
    }

    func runAndWait() throws -> Int32 {
        try lock.withLock {
            if cancellationRequested {
                throw CancellationError()
            }
            try process.run()
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    func cancel() {
        lock.withLock {
            cancellationRequested = true
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
