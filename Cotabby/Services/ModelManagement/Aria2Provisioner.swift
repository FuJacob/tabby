import Foundation
import Logging

/// State of on-demand aria2c binary provisioning.
public enum Aria2ProvisioningState: Equatable, Sendable {
    case idle
    case downloading(progress: Double?)
    case ready(path: String)
    case failed(String)
}

/// Errors that can occur during aria2c binary provisioning.
public enum Aria2ProvisioningError: LocalizedError, Equatable {
    case downloadFailed(String)
    case extractionFailed(String)
    case invalidBinary
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let message):
            return "Failed to download aria2c binary: \(message)"
        case .extractionFailed(let message):
            return "Failed to extract aria2c binary: \(message)"
        case .invalidBinary:
            return "Downloaded binary is corrupted or incompatible with this architecture."
        case .permissionDenied:
            return "Permission denied while setting executable attributes."
        }
    }
}

/// File overview:
/// Automatically downloads and provisions the `aria2c` standalone binary into
/// Cotabby's Application Support folder if it is not present on the system.
///
/// Why this class exists:
/// Many users do not have Homebrew or MacPorts installed. Providing on-demand
/// provisioning ensures all users get high-speed segmented downloads and pause/resume
/// without needing manual terminal setup.
///
/// Collaborators:
/// - `Aria2Locator`: defines the destination `userDownloadedBinaryURL` and verifies availability.
/// - `ModelDownloadManager`: triggers automatic provisioning before initiating model downloads.
public final class Aria2Provisioner: @unchecked Sendable {
    public static let shared = Aria2Provisioner()

    private let fileManager: FileManager
    private let lock = NSLock()
    private var activeTask: Task<URL, Error>?

    /// Direct prebuilt binary URLs by architecture (ARM64 Apple Silicon / Intel x86_64).
    private static var bottleDownloadURL: URL {
        #if arch(arm64)
        // macOS Apple Silicon universal/arm64 bottle
        return URL(string: "https://ghcr.io/v2/homebrew/core/aria2/blobs/sha256:8815b6b79395235863349628dc0d753bbee9069e99d94257b7646ffd85615623")!
        #else
        // macOS Intel x86_64 bottle
        return URL(string: "https://ghcr.io/v2/homebrew/core/aria2/blobs/sha256:b88e53b1c54d82af91dea90551fc114b7c02149972d536b9d55a33b12f9a9fd5")!
        #endif
    }

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Checks if `aria2c` is already available anywhere on the system or locally provisioned.
    public var isAvailable: Bool {
        Aria2Locator.isAvailable
    }

    /// Provisions `aria2c` into `Aria2Locator.userDownloadedBinaryURL` if not already installed.
    ///
    /// - Parameter progressHandler: Callback receiving download progress fraction (0.0 to 1.0).
    /// - Returns: File URL to the provisioned `aria2c` executable.
    @discardableResult
    public func provisionIfNeeded(
        progressHandler: (@Sendable (Double?) -> Void)? = nil
    ) async throws -> URL {
        if let existing = Aria2Locator.executableURL(fileManager: fileManager) {
            return existing
        }

        lock.lock()
        if let ongoing = activeTask {
            lock.unlock()
            return try await ongoing.value
        }

        let task = Task<URL, Error> {
            try await performProvision(progressHandler: progressHandler)
        }
        activeTask = task
        lock.unlock()

        defer {
            lock.lock()
            activeTask = nil
            lock.unlock()
        }

        return try await task.value
    }

    private func performProvision(
        progressHandler: (@Sendable (Double?) -> Void)?
    ) async throws -> URL {
        let destinationURL = Aria2Locator.userDownloadedBinaryURL
        let binDirectory = destinationURL.deletingLastPathComponent()

        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        // 1. Check if Homebrew exists on the host and can install aria2 quickly
        if let brewURL = findBrewExecutable() {
            if (try? await runBrewInstallAria2(brewURL: brewURL)) == true,
               let installedURL = Aria2Locator.executableURL(fileManager: fileManager) {
                return installedURL
            }
        }

        // 2. Fetch the Homebrew package bottle token and download archive
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let archiveURL = tempDir.appendingPathComponent("aria2_package.tar.gz")

        // Fetch auth token for GHCR package registry
        let token = try await fetchGHCRToken()
        var request = URLRequest(url: Self.bottleDownloadURL)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (tempDownloadedURL, response) = try await URLSession.shared.download(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw Aria2ProvisioningError.downloadFailed("HTTP \(code)")
        }

        try fileManager.moveItem(at: tempDownloadedURL, to: archiveURL)

        // 3. Extract the aria2c executable from the archive using tar
        let extractedDir = tempDir.appendingPathComponent("extracted")
        try fileManager.createDirectory(at: extractedDir, withIntermediateDirectories: true)

        let tarProcess = Process()
        tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tarProcess.arguments = ["-xzf", archiveURL.path, "-C", extractedDir.path]

        try tarProcess.run()
        tarProcess.waitUntilExit()

        guard tarProcess.terminationStatus == 0 else {
            throw Aria2ProvisioningError.extractionFailed("tar exit code \(tarProcess.terminationStatus)")
        }

        // 4. Find the aria2c binary in the extracted contents
        guard let discoveredBinary = findBinaryInDirectory(named: "aria2c", directory: extractedDir) else {
            throw Aria2ProvisioningError.invalidBinary
        }

        // 5. Promote binary to Cotabby bin directory with executable permissions
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: discoveredBinary, to: destinationURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)

        guard fileManager.isExecutableFile(atPath: destinationURL.path) else {
            throw Aria2ProvisioningError.permissionDenied
        }

        CotabbyLogger.runtime.info("Successfully provisioned aria2c to \(destinationURL.path)")
        return destinationURL
    }

    private func fetchGHCRToken() async throws -> String? {
        guard let tokenURL = URL(string: "https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/aria2:pull") else {
            return nil
        }
        let (data, _) = try await URLSession.shared.data(from: tokenURL)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            return nil
        }
        return token
    }

    private func findBrewExecutable() -> URL? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for path in candidates {
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func runBrewInstallAria2(brewURL: URL) async throws -> Bool {
        let process = Process()
        process.executableURL = brewURL
        process.arguments = ["install", "aria2"]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func findBinaryInDirectory(named binaryName: String, directory: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == binaryName {
                return fileURL
            }
        }
        return nil
    }
}
