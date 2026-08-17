import Foundation

/// File overview:
/// Pure parser that extracts download progress, transfer speed, and ETA from aria2c's standard output stream.
///
/// Why this file exists:
/// aria2c emits progress status updates to stdout formatted like:
/// `[#e54b67 1.2GiB/4.5GiB(26%) CN:8 DL:42.5MiB ETA:1m15s]`
/// Decoupling string parsing into its own pure support type allows comprehensive unit testing
/// without launching subprocesses or mocking `Process` pipes.
///
/// Collaborators:
/// - `Aria2DownloadService`: consumes this parser while streaming stdout from the aria2c process.
/// - `ModelDownloadState`: receives the parsed progress fraction, transfer speed, and ETA for SwiftUI rendering.
public struct Aria2Progress: Equatable, Sendable {
    public let progressFraction: Double?
    public let speedFormatted: String?
    public let etaFormatted: String?
    public let connectionCount: Int?

    public init(
        progressFraction: Double?,
        speedFormatted: String? = nil,
        etaFormatted: String? = nil,
        connectionCount: Int? = nil
    ) {
        self.progressFraction = progressFraction
        self.speedFormatted = speedFormatted
        self.etaFormatted = etaFormatted
        self.connectionCount = connectionCount
    }
}

public enum Aria2OutputParser {
    // Regex pattern matching aria2c progress line:
    // e.g. "[#123456 1.2GiB/4.5GiB(26%) CN:8 DL:42.5MiB ETA:1m15s]"
    // - Group 1: Percent number e.g. "26"
    // - Group 2: Connection count (optional) e.g. "8"
    // - Group 3: Download speed (optional) e.g. "42.5MiB"
    // - Group 4: ETA (optional) e.g. "1m15s"
    private static let progressRegex: NSRegularExpression? = {
        let pattern = #"\[#\w+\s+[^(]*\((\d+)%\)(?:\s+CN:(\d+))?(?:\s+DL:([0-9.]+[A-Za-z]+))?(?:\s+ETA:([0-9a-z]+))?"#
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Parses a single line of stdout from aria2c and returns an `Aria2Progress` value if a progress report is present.
    public static func parse(line: String) -> Aria2Progress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[#"), let regex = progressRegex else {
            return nil
        }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range) else {
            return nil
        }

        // Extract percentage
        var fraction: Double?
        if let percentRange = Range(match.range(at: 1), in: trimmed),
           let percentVal = Double(trimmed[percentRange]) {
            fraction = min(max(percentVal / 100.0, 0.0), 1.0)
        }

        // Extract connection count
        var connections: Int?
        if match.range(at: 2).location != NSNotFound,
           let cnRange = Range(match.range(at: 2), in: trimmed),
           let cnVal = Int(trimmed[cnRange]) {
            connections = cnVal
        }

        // Extract download speed
        var speedText: String?
        if match.range(at: 3).location != NSNotFound,
           let speedRange = Range(match.range(at: 3), in: trimmed) {
            let rawSpeed = String(trimmed[speedRange])
            speedText = formatSpeed(rawSpeed)
        }

        // Extract ETA
        var etaText: String?
        if match.range(at: 4).location != NSNotFound,
           let etaRange = Range(match.range(at: 4), in: trimmed) {
            etaText = formatETA(String(trimmed[etaRange]))
        }

        return Aria2Progress(
            progressFraction: fraction,
            speedFormatted: speedText,
            etaFormatted: etaText,
            connectionCount: connections
        )
    }

    private static func formatSpeed(_ raw: String) -> String {
        if raw.hasSuffix("GiB") {
            let num = raw.dropLast(3)
            return "\(num) GB/s"
        } else if raw.hasSuffix("MiB") {
            let num = raw.dropLast(3)
            return "\(num) MB/s"
        } else if raw.hasSuffix("KiB") {
            let num = raw.dropLast(3)
            return "\(num) KB/s"
        } else if raw.hasSuffix("B") {
            let num = raw.dropLast(1)
            return "\(num) B/s"
        }
        return "\(raw)/s"
    }

    private static func formatETA(_ raw: String) -> String {
        // Format "1m15s" -> "1m 15s", "45s" -> "45s", "2h5m" -> "2h 5m"
        var result = raw
        result = result.replacingOccurrences(of: "h", with: "h ")
        result = result.replacingOccurrences(of: "m", with: "m ")
        return result.trimmingCharacters(in: .whitespaces)
    }
}
