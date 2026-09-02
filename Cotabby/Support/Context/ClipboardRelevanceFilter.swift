import Foundation

/// Decides whether the current clipboard content is relevant enough to inject into the
/// autocomplete prompt. Tracks clipboard identity via an external change count, records when
/// the clipboard last changed during this Cotabby session, and applies two heuristics:
/// staleness and token overlap.
///
/// Why no source-app affinity: we never observe the actual copier — only the app that is
/// frontmost when autocomplete fires, which is always the typing app. Recording the typing
/// app as the "source" granted same-app shortcuts in apps where the user merely typed,
/// bypassing the overlap guard for unrelated clipboard content.
///
/// Why a sentinel baseline: `NSPasteboard.changeCount` is a non-zero cumulative counter, so
/// initializing to `0` made every first observation look like a fresh copy event and reset
/// the staleness clock to "now" — granting up to five minutes of injection for content
/// copied hours before Cotabby launched. The first observation now records the baseline
/// without stamping a date, gating injection until an actual change is detected.
///
/// The filter never reads `NSPasteboard` directly — the caller passes in a plain `Int` change
/// count and the raw clipboard string, keeping this type fully testable without AppKit.
@MainActor
final class ClipboardRelevanceFilter: ClipboardRelevanceFiltering {
    static let staleThresholdSeconds: TimeInterval = 300
    /// Bound text before tokenization and memoization so a large pasteboard cannot allocate an
    /// unbounded CJK bigram set on the main actor. Final prompt selection applies a much smaller cap.
    static let maximumEvaluatedCharacters = 8_000

    private var lastKnownChangeCount: Int?
    private var lastObservationDate: Date?
    private var lastChangeDate: Date?
    private let dateProvider: () -> Date

    var acceptedContextExpiresAt: Date? {
        lastChangeDate?.addingTimeInterval(Self.staleThresholdSeconds)
    }

    init(dateProvider: @escaping () -> Date = { Date() }) {
        self.dateProvider = dateProvider
    }

    /// Returns a bounded clipboard value when it looks relevant, or `nil` when it should be dropped.
    func filter(
        clipboard: String?,
        pasteboardChangeCount: Int,
        precedingText: String
    ) -> String? {
        guard let clipboard else { return nil }
        let boundedClipboard = String(clipboard.prefix(Self.maximumEvaluatedCharacters))
        let now = dateProvider()
        let previousObservationDate = lastObservationDate
        lastObservationDate = now

        guard let baselineChangeCount = lastKnownChangeCount else {
            // First observation: record the baseline so we can detect *new* copies, but leave
            // the staleness clock unset. Pre-existing clipboard content is not injected until
            // the user actually copies again while Cotabby is running.
            lastKnownChangeCount = pasteboardChangeCount
            return nil
        }

        if pasteboardChangeCount != baselineChangeCount {
            lastKnownChangeCount = pasteboardChangeCount
            // NSPasteboard exposes no copy timestamp. The copy happened sometime after our previous
            // observation, so use that earlier boundary as a conservative source time. If the gap is
            // already five minutes, the content may be stale and must fail closed.
            guard let previousObservationDate,
                  now.timeIntervalSince(previousObservationDate) < Self.staleThresholdSeconds else {
                lastChangeDate = nil
                return nil
            }
            lastChangeDate = previousObservationDate
        }

        guard let lastChangeDate,
              now.timeIntervalSince(lastChangeDate) < Self.staleThresholdSeconds
        else {
            return nil
        }

        guard PromptContextSanitizer.hasMeaningfulRelevance(
            between: boundedClipboard,
            and: precedingText
        ) else {
            return nil
        }

        return boundedClipboard
    }
}
