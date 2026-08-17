import Foundation

/// Post-generation guard for visible output failures: junk punctuation runs ("....", "$$$$"),
/// mid-word splices that misspell the joined word ("gre" + "atful"), and correctable misspellings
/// in the first generated word. Showing nothing beats presenting any of these as an insertion.
///
/// Both rules are deliberately narrow so they fire rarely:
///
/// - **Junk run**: a run of four or more identical punctuation/symbol characters inside the
///   completion, unless the run merely extends an identical run the user already has at the caret
///   (continuing an existing `----` divider is legitimate).
/// - **Seam misspelling**: in the mid-word case (caret inside a word, completion starts with word
///   characters), the joined word formed across the seam must be known to the spell checker.
/// - **Leading-word misspelling**: when the completion starts a new word, the first generated word
///   is checked only when the caller can both identify it as a typo and offer a correction. This is
///   deliberately narrower than dictionary membership so names, jargon, and model vocabulary still
///   pass through when the native checker has no actionable fix.
///
/// Both spelling checks skip capitalized words (names and brands are routinely out-of-dictionary),
/// short words (under four letters), words with digits, and CJK text (no space-delimited word
/// boundaries, and the dictionaries do not cover it).
nonisolated enum CompletionSeamGuard {
    /// One explicit spelling result keeps callers from supplying contradictory combinations such
    /// as "typo without a correction callback". The guard only needs to distinguish actionable
    /// typos from unknown-but-uncorrectable vocabulary at a leading-word boundary.
    enum SpellingAssessment: Equatable {
        case known
        case uncorrectableTypo
        case correctableTypo
    }

    enum Verdict: Equatable {
        case allow
        case junkPunctuationRun
        case seamMisspelling(word: String)
        case leadingWordMisspelling(word: String)
    }

    /// Streaming must not expose the first generated word until it is complete enough to assess.
    /// Once this resolves to allow or suppress, the coordinator caches it for the generation so
    /// `NSSpellChecker` is never called at token cadence.
    enum StreamedLeadingWordVerdict: Equatable {
        case wait
        case allow
        case suppress
    }

    /// Identical punctuation/symbol characters in a row that count as junk when freshly introduced.
    private static let junkRunLength = 4

    /// Joined seam words shorter than this are too ambiguous to judge ("a" + "t").
    private static let minimumSeamWordLength = 4

    /// Cheap streaming-path junk rule. The separate leading-word streaming verdict buffers until a
    /// complete word exists, then performs and caches exactly one spelling decision.
    static func allowsStreamedPartial(precedingText: String, completion: String) -> Bool {
        !introducesJunkPunctuationRun(precedingText: precedingText, completion: completion)
    }

    /// The spelling assessment is injected so the pure rule stays testable and the caller picks the
    /// backend. A single result describes the whole invariant: mid-word seams reject any typo,
    /// while newly generated words reject only correctable typos.
    static func verdict(
        precedingText: String,
        completion: String,
        spellingAssessment: (String) -> SpellingAssessment
    ) -> Verdict {
        if introducesJunkPunctuationRun(precedingText: precedingText, completion: completion) {
            return .junkPunctuationRun
        }

        if let seamWord = misspellingCandidateSeamWord(
            precedingText: precedingText,
            completion: completion
        ), spellingAssessment(seamWord) != .known {
            return .seamMisspelling(word: seamWord)
        }

        if case let .candidate(leadingWord, _) = leadingWordProbe(
            precedingText: precedingText,
            completion: completion
        ), spellingAssessment(leadingWord) == .correctableTypo {
            return .leadingWordMisspelling(word: leadingWord)
        }

        return .allow
    }

    /// Leading-word half of the streaming guard. Incomplete first words remain buffered; testing a
    /// prefix such as `ecr` would create false positives and repeating the lookup on every token
    /// would put an AppKit/XPC call on the hot streaming path.
    static func streamedLeadingWordVerdict(
        precedingText: String,
        completion: String,
        spellingAssessment: (String) -> SpellingAssessment
    ) -> StreamedLeadingWordVerdict {
        switch leadingWordProbe(precedingText: precedingText, completion: completion) {
        case .notApplicable:
            return .allow
        case .incomplete:
            return .wait
        case let .candidate(word, isComplete):
            guard isComplete else {
                return .wait
            }
            return spellingAssessment(word) == .correctableTypo ? .suppress : .allow
        }
    }

    // MARK: - Junk punctuation runs

    private static func introducesJunkPunctuationRun(
        precedingText: String,
        completion: String
    ) -> Bool {
        var runCharacter: Character?
        var runLength = 0
        var runStartsAtCompletionStart = false
        var index = 0

        for character in completion {
            if character == runCharacter {
                runLength += 1
            } else {
                runCharacter = character
                runLength = 1
                runStartsAtCompletionStart = index == 0
            }
            index += 1

            guard runLength >= junkRunLength,
                  let current = runCharacter,
                  current.isPunctuation || current.isSymbol
            else { continue }

            // A run flush against the seam that continues a run of the same character the user
            // already has at the caret is an existing divider being extended, not fresh junk.
            // It must be a real preceding run (two or more): a sentence that merely ends in "."
            // must not exempt "...." from the completion.
            if runStartsAtCompletionStart, trailingRunLength(of: precedingText, character: current) >= 2 {
                continue
            }
            return true
        }
        return false
    }

    // MARK: - Seam misspellings

    /// The joined word across the caret seam when the mid-word rule applies, or nil when any of
    /// the narrowing conditions exempt it.
    private static func misspellingCandidateSeamWord(
        precedingText: String,
        completion: String
    ) -> String? {
        guard let lastBefore = precedingText.last, lastBefore.isLetter,
              let firstAfter = completion.first, firstAfter.isLetter
        else { return nil }

        let head = trailingLetterRun(of: precedingText)
        let tail = leadingLetterRun(of: completion)
        let seamWord = head + tail

        guard seamWord.count >= minimumSeamWordLength else { return nil }
        // Capitalized joins are usually names or brands the dictionary cannot know.
        guard let firstCharacter = seamWord.first, firstCharacter.isLowercase else { return nil }
        guard !containsCJK(seamWord) else { return nil }
        return seamWord
    }

    private enum LeadingWordProbe {
        case notApplicable
        case incomplete
        case candidate(word: String, isComplete: Bool)
    }

    /// Finds the first lexical word after boundary whitespace or punctuation. Apostrophes and
    /// hyphens between letters remain part of the word (`doesn't`, `state-of-the-art`) so the spell
    /// checker sees the same natural-language token the user sees.
    private static func leadingWordProbe(
        precedingText: String,
        completion: String
    ) -> LeadingWordProbe {
        guard !completion.isEmpty else {
            return .incomplete
        }

        guard let wordStart = completion.firstIndex(where: { $0.isLetter }) else {
            // Whitespace and opening punctuation may arrive before the first streamed word. Digits
            // make the token code/version-like, so the conservative spelling rule does not apply.
            return completion.allSatisfy({ $0.isWhitespace || $0.isPunctuation || $0.isSymbol })
                ? .incomplete
                : .notApplicable
        }

        let boundaryPrefix = completion[..<wordStart]
        guard !boundaryPrefix.contains(where: { $0.isNumber }) else {
            return .notApplicable
        }

        // A digit anywhere in the same whitespace-delimited token makes it code/version-like. Scan
        // the whole token before extracting its leading letter run so `ecrir2` is not misread as the
        // correctable natural-language word `ecrir`.
        let tokenEnd = completion[wordStart...].firstIndex(where: { $0.isWhitespace })
            ?? completion.endIndex
        guard !completion[wordStart..<tokenEnd].contains(where: { $0.isNumber }) else {
            return .notApplicable
        }

        // A bare apostrophe or hyphen can continue the word before the caret (`don` + `'t`). Any
        // other prefix character establishes a real boundary before the generated word.
        if precedingText.last?.isLetter == true,
           boundaryPrefix.allSatisfy({ isWordConnector($0) }) {
            return .notApplicable
        }

        var wordEnd = wordStart
        var endsInDanglingConnector = false
        while wordEnd < completion.endIndex {
            let character = completion[wordEnd]
            if character.isLetter {
                wordEnd = completion.index(after: wordEnd)
                continue
            }
            let next = completion.index(after: wordEnd)
            if isWordConnector(character), next < completion.endIndex,
               completion[next].isLetter {
                wordEnd = next
                continue
            }
            endsInDanglingConnector = isWordConnector(character)
                && next == completion.endIndex
            break
        }

        let word = String(completion[wordStart..<wordEnd])
        let letters = word.filter(\.isLetter)
        let isComplete = wordEnd < completion.endIndex && !endsInDanglingConnector
        guard letters.first?.isLowercase == true,
              !letters.dropFirst().contains(where: { $0.isUppercase }),
              !containsCJK(word) else {
            return .notApplicable
        }
        guard letters.count >= minimumSeamWordLength else {
            return isComplete ? .notApplicable : .incomplete
        }
        return .candidate(word: word, isComplete: isComplete)
    }

    /// Apostrophes and hyphens bind adjacent letter runs into one natural-language token.
    private static func isWordConnector(_ character: Character) -> Bool {
        character == "'" || character == "’" || character == "-"
    }

    private static func trailingRunLength(of text: String, character: Character) -> Int {
        text.reversed().prefix(while: { $0 == character }).count
    }

    private static func trailingLetterRun(of text: String) -> String {
        String(text.reversed().prefix(while: { $0.isLetter }).reversed())
    }

    private static func leadingLetterRun(of text: String) -> String {
        String(text.prefix(while: { $0.isLetter }))
    }

    /// Han, kana, and Hangul ranges; CJK has no space-delimited words, so a "seam word" is not a
    /// meaningful unit there and the spelling dictionaries do not cover these scripts. The
    /// 0x2E80-0x9FFF block already spans the kana ranges, so they are not listed separately.
    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF65...0xFF9F:
                return true
            default:
                return false
            }
        }
    }
}
