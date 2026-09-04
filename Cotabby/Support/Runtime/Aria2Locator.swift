import Foundation

/// Resolves an existing aria2c executable without making installation or download decisions.
/// Keeping discovery pure lets the provisioner and download manager share one precedence order.
nonisolated enum Aria2Locator {
    private static let candidatePaths = [
        "/opt/homebrew/bin/aria2c",
        "/usr/local/bin/aria2c",
        "/usr/bin/aria2c",
        "/opt/local/bin/aria2c"
    ]

    /// Resolves the URL to the `aria2c` executable if present and executable.
    static func executableURL(fileManager: FileManager = .default) -> URL? {
        if let bundledURL = Bundle.main.url(forResource: "aria2c", withExtension: nil),
           fileManager.isExecutableFile(atPath: bundledURL.path) {
            return bundledURL
        }

        for path in candidatePaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            let directories = pathEnv.split(separator: ":").map(String.init)
            for directory in directories {
                let binaryPath = (directory as NSString).appendingPathComponent("aria2c")
                guard fileManager.isExecutableFile(atPath: binaryPath) else {
                    continue
                }
                return URL(fileURLWithPath: binaryPath)
            }
        }

        return nil
    }
}
