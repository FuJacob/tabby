import XCTest
@testable import Cotabby

/// Tests for the heuristic token-count estimator. It is deliberately approximate, so these lock down
/// robust *relationships* (empty is zero, longer text estimates more, every word counts) rather than
/// exact token counts a real tokenizer would produce.
final class TokenCountEstimatorTests: XCTestCase {
    func test_emptyOrWhitespaceIsZero() {
        XCTAssertEqual(TokenCountEstimator.estimate(""), 0)
        XCTAssertEqual(TokenCountEstimator.estimate("   \n\t "), 0)
    }

    func test_everyWordIsAtLeastOneToken() {
        XCTAssertEqual(TokenCountEstimator.estimate("a"), 1)
        XCTAssertGreaterThanOrEqual(TokenCountEstimator.estimate("hi there"), 2)
    }

    func test_longerTextEstimatesMoreTokens() {
        let short = TokenCountEstimator.estimate("the cat sat")
        let long = TokenCountEstimator.estimate("the cat sat on the warm windowsill all afternoon long")
        XCTAssertGreaterThan(long, short)
    }

    func test_longWordCountsForMoreThanShortWord() {
        XCTAssertGreaterThan(
            TokenCountEstimator.estimate("internationalization"),
            TokenCountEstimator.estimate("cat")
        )
    }

    func test_scalesWithWordCount() {
        let oneWord = TokenCountEstimator.estimate("word")
        let fiveWords = TokenCountEstimator.estimate("word word word word word")
        XCTAssertEqual(fiveWords, oneWord * 5)
    }

    func test_cjkCharactersUseConservativeDenseEstimate() {
        XCTAssertEqual(TokenCountEstimator.estimate("发布计划"), 4)
        XCTAssertGreaterThan(
            TokenCountEstimator.estimate("发布计划发布计划"),
            TokenCountEstimator.estimate("abcdefgh")
        )
    }

    func test_mixedLatinAndCJKCountsBothRuns() {
        XCTAssertEqual(TokenCountEstimator.estimate("API上下文"), 4)
    }

    func test_cjkExtensionCharactersUseDenseEstimate() {
        XCTAssertEqual(TokenCountEstimator.estimate("\u{2A700}\u{2A701}"), 2)
        XCTAssertEqual(TokenCountEstimator.estimate("\u{31350}\u{31351}"), 2)
    }

    func test_splitsOnPunctuationBoundaries() {
        // Punctuation creates token boundaries (like real subword tokenizers), so a contraction or a
        // punctuation-joined identifier estimates more tokens than the same letters with none.
        XCTAssertGreaterThan(TokenCountEstimator.estimate("can't"), TokenCountEstimator.estimate("cant"))
        XCTAssertGreaterThan(TokenCountEstimator.estimate("foo.bar.baz"), TokenCountEstimator.estimate("foobarbaz"))
    }
}
