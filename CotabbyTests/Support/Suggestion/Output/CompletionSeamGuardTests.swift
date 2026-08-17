import XCTest
@testable import Cotabby

/// Locks in that the seam guard fires only on the two failure shapes it exists for (fresh junk
/// punctuation runs, mid-word splices that misspell the joined word) and never on the ordinary
/// continuations that surround them. Every guard must fire rarely; most of these tests are
/// allow-cases for exactly that reason.
final class CompletionSeamGuardTests: XCTestCase {
    /// A stub dictionary: the listed words are known, everything else is an uncorrectable typo.
    private func knowing(
        _ words: Set<String>
    ) -> (String) -> CompletionSeamGuard.SpellingAssessment {
        { words.contains($0.lowercased()) ? .known : .uncorrectableTypo }
    }

    private let knowsEverything: (String) -> CompletionSeamGuard.SpellingAssessment = { _ in .known }
    private let knowsNothing: (String) -> CompletionSeamGuard.SpellingAssessment = {
        _ in .uncorrectableTypo
    }

    // MARK: - Junk punctuation runs

    func testFreshPunctuationRunIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Wait",
                completion: " what....",
                spellingAssessment: knowsEverything
            ),
            .junkPunctuationRun
        )
    }

    func testSymbolRunIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Price: ",
                completion: "$$$$",
                spellingAssessment: knowsEverything
            ),
            .junkPunctuationRun
        )
    }

    func testThreeCharacterRunIsAllowed() {
        // Ellipsis-length runs are ordinary prose.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Well",
                completion: "... maybe",
                spellingAssessment: knowsEverything
            ),
            .allow
        )
    }

    func testSingleTrailingCharacterDoesNotExemptAJunkRun() {
        // "Hello." ends with one period; that must not license "...." from the completion. Only
        // a real preceding run (two or more) reads as a divider being extended.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Hello.",
                completion: "....",
                spellingAssessment: knowsEverything
            ),
            .junkPunctuationRun
        )
    }

    func testStreamedPartialVariantAppliesOnlyTheJunkRule() {
        XCTAssertFalse(
            CompletionSeamGuard.allowsStreamedPartial(precedingText: "Wait", completion: " what....")
        )
        // A mid-word splice passes the streamed check; the spell half runs only on the final
        // apply, which replaces or suppresses whatever streamed.
        XCTAssertTrue(
            CompletionSeamGuard.allowsStreamedPartial(precedingText: "gre", completion: "atful and kind")
        )
    }

    func testContinuingAnExistingDividerIsAllowed() {
        // The user already has a dash run at the caret; extending it is intentional.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "----",
                completion: "------",
                spellingAssessment: knowsEverything
            ),
            .allow
        )
    }

    func testFreshDividerAwayFromSeamIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "----",
                completion: " section ======",
                spellingAssessment: knowsEverything
            ),
            .junkPunctuationRun
        )
    }

    func testRepeatedLettersAreNotJunk() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "That is so",
                completion: " coooool",
                spellingAssessment: knowsEverything
            ),
            .allow
        )
    }

    // MARK: - Seam misspellings

    func testMisspelledSeamWordIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "I am so gre",
                completion: "atful for this",
                spellingAssessment: knowing(["great", "grateful"])
            ),
            .seamMisspelling(word: "greatful")
        )
    }

    func testKnownSeamWordIsAllowed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "I am so gre",
                completion: "at to hear it",
                spellingAssessment: knowing(["great"])
            ),
            .allow
        )
    }

    func testSeamRuleOnlyAppliesMidWord() {
        // Caret after a space: no seam word exists, so nothing to judge.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "I am so ",
                completion: "greatful",
                spellingAssessment: knowsNothing
            ),
            .allow
        )
    }

    func testCapitalizedSeamWordIsAllowed() {
        // Names and brands are routinely out-of-dictionary; never block them.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Ask Cota",
                completion: "bby about it",
                spellingAssessment: knowsNothing
            ),
            .allow
        )
    }

    func testShortSeamWordIsAllowed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "a",
                completion: "t the office",
                spellingAssessment: knowsNothing
            ),
            .allow
        )
    }

    func testDigitAdjacentSeamIsAllowed() {
        // The letter-run join is "vbeta"? No: digits break the letter run, so the head is empty
        // and the mid-word precondition (letter on both sides) fails.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "version 2",
                completion: "024 release",
                spellingAssessment: knowsNothing
            ),
            .allow
        )
    }

    func testCJKSeamIsAllowed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "これはとても良",
                completion: "い天気ですね",
                spellingAssessment: knowsNothing
            ),
            .allow
        )
    }

    func testOrdinaryContinuationIsAllowed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Thanks again for your help",
                completion: " with the move last weekend.",
                spellingAssessment: knowing(["with"])
            ),
            .allow
        )
    }

    // MARK: - Leading-word misspellings

    func testMisspelledLeadingWordWithCorrectionIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Je veux ",
                completion: "ecrir plus vite",
                spellingAssessment: { $0 == "ecrir" ? .correctableTypo : .known }
            ),
            .leadingWordMisspelling(word: "ecrir")
        )
    }

    func testLeadingWordWithoutCorrectionIsAllowed() {
        // An unknown name or domain term should not disappear merely because the native checker has
        // no suggestion for it.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Use ",
                completion: "cotabby avec soin",
                spellingAssessment: { $0 == "cotabby" ? .uncorrectableTypo : .known }
            ),
            .allow
        )
    }

    func testCapitalizedLeadingWordIsAllowed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Ask ",
                completion: "Cotypist about it",
                spellingAssessment: { _ in
                    XCTFail("capitalized leading words must not reach the spell checker")
                    return .correctableTypo
                }
            ),
            .allow
        )
    }

    func testMidWordCompletionOnlyAssessesTheJoinedSeamWord() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Je veux ecr",
                completion: "irregular",
                spellingAssessment: { word in
                    XCTAssertEqual(word, "ecrirregular")
                    return .known
                }
            ),
            .allow
        )
    }

    func testQuotedLeadingWordIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Il répond ",
                completion: "“ecrir” plus vite",
                spellingAssessment: { $0 == "ecrir" ? .correctableTypo : .known }
            ),
            .leadingWordMisspelling(word: "ecrir")
        )
    }

    func testParenthesizedLeadingWordAfterTextIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Il répond",
                completion: ": (ecrir) plus vite",
                spellingAssessment: { $0 == "ecrir" ? .correctableTypo : .known }
            ),
            .leadingWordMisspelling(word: "ecrir")
        )
    }

    func testContractionIsAssessedAsOneWord() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "It ",
                completion: "doesn't matter",
                spellingAssessment: { word in
                    XCTAssertEqual(word, "doesn't")
                    return .known
                }
            ),
            .allow
        )
    }

    // MARK: - Streamed leading words

    func testStreamedLeadingWordWaitsUntilItsBoundaryArrives() {
        XCTAssertEqual(
            CompletionSeamGuard.streamedLeadingWordVerdict(
                precedingText: "Je veux ",
                completion: "ecrir",
                spellingAssessment: { _ in
                    XCTFail("an incomplete streamed word must not reach the spell checker")
                    return .known
                }
            ),
            .wait
        )
    }

    func testStreamedContractionWaitsAfterADanglingApostrophe() {
        XCTAssertEqual(
            CompletionSeamGuard.streamedLeadingWordVerdict(
                precedingText: "It ",
                completion: "does'",
                spellingAssessment: { _ in
                    XCTFail("a dangling apostrophe may still continue the streamed word")
                    return .known
                }
            ),
            .wait
        )
    }

    func testStreamedCorrectableLeadingWordIsSuppressedAtItsBoundary() {
        XCTAssertEqual(
            CompletionSeamGuard.streamedLeadingWordVerdict(
                precedingText: "Je veux ",
                completion: "ecrir ",
                spellingAssessment: { $0 == "ecrir" ? .correctableTypo : .known }
            ),
            .suppress
        )
    }

    func testStreamedKnownLeadingWordIsAllowedAtItsBoundary() {
        XCTAssertEqual(
            CompletionSeamGuard.streamedLeadingWordVerdict(
                precedingText: "Je veux ",
                completion: "écrire ",
                spellingAssessment: { $0 == "écrire" ? .known : .correctableTypo }
            ),
            .allow
        )
    }
}
