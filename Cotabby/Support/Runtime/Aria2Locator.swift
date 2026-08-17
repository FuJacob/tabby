import Foundation

/// File overview:
/// Discovers the executable path of the `aria2c` binary on the host system.
///
/// Why this file exists:
/// Users on macOS may install `aria2` via Homebrew (`/opt/homebrew/bin/aria2c` on Apple Silicon
/// or `/usr/local/bin/aria2c` on Intel), MacPorts, or a bundled binary in the app bundle.
/// Keeping locator logic isolated makes discovery predictable, cached, and testable with mock file systems.
///
/// Collaborators:
/// - `ModelDownloadManager`: checks `Aria2Locator.isAvailable` to choose between `Aria2DownloadService` and `URLSession`.
/// - `Aria2DownloadService`: retrieves `Aria2Locator.executableURL` to launch the subprocess.
public enum Aria2Locator {
    /// Destination path for automatically or on-demand downloaded `aria2c` binary.
    public static var userDownloadedBinaryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("Cotabby", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("aria2c", isDirectory: false)
    }

    /// Common candidate file paths for the `aria2c` binary on macOS.
    private static let candidatePaths = [
        "/opt/homebrew/bin/aria2c",
        "/usr/local/bin/aria2c",
        "/usr/bin/aria2c",
        "/opt/local/bin/aria2c"
    ]

    /// Resolves the URL to the `aria2c` executable if present and executable.
    public static func executableURL(fileManager: FileManager = .default) -> URL? {
        // 1. Check App Bundle if bundled
        if let bundledURL = Bundle.main.url(forResource: "aria2c", withExtension: nil),
           fileManager.isExecutableFile(atPath: bundledURL.path) {
            return bundledURL
        }

        // 2. Check user-downloaded Cotabby bin directory
        let userBinary = userDownloadedBinaryURL
        if fileManager.isExecutableFile(atPath: userBinary.path) {
            return userBinary
        }

        // 3. Check candidate standard paths
        for path in candidatePaths {
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        // 3. Search PATH environment variable
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            let directories = pathEnv.split(separator: ":").map(String.init)
            for dir in directories {
                let binaryPath = (dir as NSString).appendingPathComponent("aria2c")
                if fileManager.isExecutableFile(atPath: binaryPath) {
                    return URL(fileURLWithPath: binaryPath)
                }
            }
        }

        return nil
    }

    /// Returns `true` if `aria2c` is installed and ready for use.
    public static var isAvailable: Bool {
        executableURL() != nil
    }
}
