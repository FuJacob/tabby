import Foundation

/// Selects the bounded clipboard lines that are relevant to the user's current caret context.
///
/// `ClipboardRelevanceFilter` remains the owner of permission-adjacent freshness and pasteboard
/// identity. This value only performs the second, line-level pass after that gate succeeds. Keeping
/// the two responsibilities separate prevents one matching line from admitting unrelated neighbors,
/// which was especially harmful for short copied blocks and long clipboard head fallbacks.
nonisolated enum ClipboardContentDistiller {
    static let defaultLimits = ContextRelevanceSelector.Limits(
        maxLines: 3,
        maxCharacters: 400
    )

    /// Returns relevant clipboard lines in their original order, or `nil` when no line shares
    /// meaningful Latin terms or CJK bigrams with `prefixText`.
    static func distill(
        clipboard: String,
        prefixText: String,
        limits: ContextRelevanceSelector.Limits = defaultLimits
    ) -> String? {
        ContextRelevanceSelector.selectRelevantLines(
            from: clipboard,
            prefixText: prefixText,
            limits: limits
        )
    }
}
