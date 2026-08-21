import CryptoKit
import Foundation

/// Derives resume directories from both source URL and leaf filename.
/// `ModelDownloadManager` uses the same pure mapping for start, retry, and targeted cancellation,
/// which prevents equal filenames from different HuggingFace repositories sharing state.
nonisolated enum Aria2StagingDirectoryResolver {
    static func directory(
        in runtimeDirectory: URL,
        downloadURL: URL,
        filename: String
    ) -> URL {
        let sourceHash = SHA256.hash(data: Data(downloadURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(12)
        return runtimeDirectory.appendingPathComponent(
            ".aria2-staging-\(sourceHash)-\(leafFilename(filename))",
            isDirectory: true
        )
    }

    static func legacyDirectory(in runtimeDirectory: URL, filename: String) -> URL {
        runtimeDirectory.appendingPathComponent(
            ".aria2-staging-\(leafFilename(filename))",
            isDirectory: true
        )
    }

    private static func leafFilename(_ filename: String) -> String {
        (filename as NSString).lastPathComponent
    }
}
