import Foundation

/// Selects the small part of an already-authorized auxiliary context source that is relevant to
/// the text nearest the caret.
///
/// The selector is deliberately pure. Clipboard and OCR services remain responsible for permission,
/// freshness, capture, and sanitization; this type only ranks their line-oriented text. Keeping the
/// policy here gives every source the same multilingual matching and deterministic budget behavior
/// without coupling prompt construction to AppKit or Vision.
nonisolated enum ContextRelevanceSelector {
    /// A source-local budget applied before the selected text competes in the global prompt budget.
    /// Independent limits keep one large OCR or clipboard payload from crowding out every other cue.
    struct Limits: Equatable, Sendable {
        let maxLines: Int
        let maxCharacters: Int

        init(maxLines: Int, maxCharacters: Int) {
            self.maxLines = max(0, maxLines)
            self.maxCharacters = max(0, maxCharacters)
        }
    }

    /// Returns relevant lines in their original reading order, or `nil` when the source has no
    /// meaningful overlap with the caret context.
    ///
    /// Ranking prefers stronger multilingual evidence. Later lines break score ties because chat
    /// transcripts and copied notes commonly place the newest information last. The character budget
    /// is spent in that ranked order so an earlier weak line cannot crowd out a later strong one; only
    /// the admitted lines are restored to source order for a coherent final excerpt.
    static func selectRelevantLines(
        from text: String,
        prefixText: String,
        limits: Limits
    ) -> String? {
        guard limits.maxLines > 0, limits.maxCharacters > 0 else { return nil }

        let prefixTerms = PromptContextSanitizer.relevanceTerms(from: prefixText)
        guard !prefixTerms.words.isEmpty || !prefixTerms.cjkBigrams.isEmpty else { return nil }

        let candidates = relevantCandidates(
            from: text,
            prefixText: prefixText,
            prefixTerms: prefixTerms
        )
        let selected = admittedCandidates(
            from: candidates,
            prefixTerms: prefixTerms,
            limits: limits
        )
        let result = selected
            .sorted { $0.candidate.index < $1.candidate.index }
            .map(\.text)
            .joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    private static func relevantCandidates(
        from text: String,
        prefixText: String,
        prefixTerms: PromptContextSanitizer.RelevanceTerms
    ) -> [Candidate] {
        let candidates = removingPrefixDuplicateLines(from: text, prefixText: prefixText)
            .components(separatedBy: .newlines)
            .enumerated()
            .compactMap { index, rawLine -> Candidate? in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return nil }

                let evidence = PromptContextSanitizer.relevanceEvidence(
                    between: PromptContextSanitizer.relevanceTerms(from: line),
                    and: prefixTerms
                )
                guard evidence.isMeaningful else { return nil }
                return Candidate(line: line, index: index, score: evidence.score)
            }

        // OCR and copied transcripts can repeat the same visible line. Keep the newest occurrence so
        // duplicates cannot consume multiple line slots or prompt characters.
        var latestByNormalizedLine: [String: Candidate] = [:]
        for candidate in candidates {
            latestByNormalizedLine[normalizedForDuplicateComparison(candidate.line)] = candidate
        }
        return latestByNormalizedLine.values.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.index > rhs.index : lhs.score > rhs.score
        }
    }

    private static func admittedCandidates(
        from rankedCandidates: [Candidate],
        prefixTerms: PromptContextSanitizer.RelevanceTerms,
        limits: Limits
    ) -> [SelectedCandidate] {
        var selected: [SelectedCandidate] = []
        var remainingCharacters = limits.maxCharacters

        for candidate in rankedCandidates where selected.count < limits.maxLines {
            let separatorCost = selected.isEmpty ? 0 : 1
            guard remainingCharacters > separatorCost else { break }
            let availableCharacters = remainingCharacters - separatorCost

            if candidate.line.count <= availableCharacters {
                selected.append(SelectedCandidate(candidate: candidate, text: candidate.line))
                remainingCharacters -= separatorCost + candidate.line.count
                continue
            }

            guard selected.isEmpty,
                  let truncated = relevantTruncatedPrefix(
                      of: candidate.line,
                      maxCharacters: availableCharacters,
                      prefixTerms: prefixTerms
                  ) else {
                continue
            }
            selected.append(SelectedCandidate(candidate: candidate, text: truncated))
            remainingCharacters -= truncated.count
        }
        return selected
    }

    /// An oversized top candidate may be truncated only when the retained prefix still carries the
    /// relevance evidence that admitted the full line. Otherwise no text from that line is emitted.
    private static func relevantTruncatedPrefix(
        of line: String,
        maxCharacters: Int,
        prefixTerms: PromptContextSanitizer.RelevanceTerms
    ) -> String? {
        let truncated = String(line.prefix(maxCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !truncated.isEmpty else { return nil }
        let evidence = PromptContextSanitizer.relevanceEvidence(
            between: PromptContextSanitizer.relevanceTerms(from: truncated),
            and: prefixTerms
        )
        return evidence.isMeaningful ? truncated : nil
    }

    /// Removes lines already present in the caret prefix before either relevance ranking or a
    /// conservative visual fallback. This separate step prevents an all-duplicate source from being
    /// mistaken for a merely low-confidence source and reintroduced unchanged.
    static func removingPrefixDuplicateLines(from text: String, prefixText: String) -> String {
        let normalizedPrefix = normalizedForDuplicateComparison(prefixText)
        return text
            .components(separatedBy: .newlines)
            .compactMap { rawLine -> String? in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return nil }
                let normalizedLine = normalizedForDuplicateComparison(line)
                guard normalizedLine.count < 4 || !normalizedPrefix.contains(normalizedLine) else {
                    return nil
                }
                return line
            }
            .joined(separator: "\n")
    }

    private static func normalizedForDuplicateComparison(_ text: String) -> String {
        // Auxiliary lines are sanitized before selection. Applying the same transformation to the
        // caret prefix makes `Deploy: alpha` and its sanitized `Deploy alpha` form compare equally.
        PromptContextSanitizer.sanitize(text)
            .precomposedStringWithCompatibilityMapping
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private struct Candidate {
        let line: String
        let index: Int
        let score: Int
    }

    private struct SelectedCandidate {
        let candidate: Candidate
        let text: String
    }
}
