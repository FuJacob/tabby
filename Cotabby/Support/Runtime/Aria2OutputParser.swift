import Foundation

/// Progress parsed from an aria2c status line for display by model-management views.
nonisolated struct Aria2Progress: Equatable, Sendable {
    let progressFraction: Double?
    let speedFormatted: String?
    let etaFormatted: String?
    let connectionCount: Int?

    init(
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

/// Converts aria2c's status-line format into a backend-neutral progress value.
nonisolated enum Aria2OutputParser {
    // Example: [#123456 1.2GiB/4.5GiB(26%) CN:8 DL:42.5MiB ETA:1m15s]
    private static let progressRegex: NSRegularExpression? = {
        let pattern = #"\[#\w+\s+[^(]*\((\d+)%\)(?:\s+CN:(\d+))?(?:\s+DL:([0-9.]+[A-Za-z]+))?(?:\s+ETA:([0-9a-z]+))?"#
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    static func parse(line: String) -> Aria2Progress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[#"), let regex = progressRegex else {
            return nil
        }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range) else {
            return nil
        }

        var fraction: Double?
        if let percentRange = Range(match.range(at: 1), in: trimmed),
           let percent = Double(trimmed[percentRange]) {
            fraction = min(max(percent / 100.0, 0.0), 1.0)
        }

        var connections: Int?
        if match.range(at: 2).location != NSNotFound,
           let connectionRange = Range(match.range(at: 2), in: trimmed),
           let connectionCount = Int(trimmed[connectionRange]) {
            connections = connectionCount
        }

        var speedText: String?
        if match.range(at: 3).location != NSNotFound,
           let speedRange = Range(match.range(at: 3), in: trimmed) {
            let rawSpeed = String(trimmed[speedRange])
            speedText = formatSpeed(rawSpeed)
        }

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
        var result = raw
        result = result.replacingOccurrences(of: "h", with: "h ")
        result = result.replacingOccurrences(of: "m", with: "m ")
        return result.trimmingCharacters(in: .whitespaces)
    }
}
