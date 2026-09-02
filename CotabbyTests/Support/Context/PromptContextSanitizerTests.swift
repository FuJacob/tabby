import XCTest
@testable import Cotabby

final class PromptContextSanitizerTests: XCTestCase {

    // MARK: - sanitize

    func test_sanitize_stripsANSIEscapeSequences() {
        let input = "\u{001B}[31mERROR\u{001B}[0m something broke"
        let result = PromptContextSanitizer.sanitize(input)
        XCTAssertFalse(result.contains("\u{001B}"))
        XCTAssertTrue(result.contains("ERROR"))
        XCTAssertTrue(result.contains("something broke"))
    }

    func test_sanitize_replacesDisallowedUnicodeWithSpacesPreservingWordBoundaries() {
        let result = PromptContextSanitizer.sanitize("raw-output")
        XCTAssertEqual(result, "raw output")
    }

    func test_sanitize_collapsesRepeatedWhitespaceIntoSingleSpaces() {
        let result = PromptContextSanitizer.sanitize("hello    world")
        XCTAssertEqual(result, "hello world")
    }

    func test_sanitize_filtersEmptyAndWhitespaceOnlyLines() {
        let input = "first\n   \n\nsecond"
        let result = PromptContextSanitizer.sanitize(input)
        XCTAssertEqual(result, "first\nsecond")
    }

    func test_sanitize_respectsMaxCharactersLimit() {
        let input = "abcdefghij"
        let result = PromptContextSanitizer.sanitize(input, maxCharacters: 5)
        XCTAssertEqual(result, "abcde")
    }

    func test_sanitize_returnsFullInputWhenMaxCharactersEqualsLength() {
        let input = "hello"
        let result = PromptContextSanitizer.sanitize(input, maxCharacters: 5)
        XCTAssertEqual(result, "hello")
    }

    func test_sanitize_returnsEmptyStringForWhitespaceOnlyInput() {
        XCTAssertEqual(PromptContextSanitizer.sanitize("   \n  \n  "), "")
    }

    func test_sanitize_returnsEmptyStringForEmptyInput() {
        XCTAssertEqual(PromptContextSanitizer.sanitize(""), "")
    }

    func test_sanitize_preservesAllowedCharacters() {
        let input = "Hello world 123 user@host.com"
        let result = PromptContextSanitizer.sanitize(input)
        XCTAssertEqual(result, input)
    }

    func test_sanitize_handlesANSIMixedWithRealText() {
        let input = "\u{001B}[32mHello\u{001B}[0m world"
        let result = PromptContextSanitizer.sanitize(input)
        XCTAssertEqual(result, "Hello world")
    }

    // MARK: - sanitizeOCR

    func test_sanitizeOCR_dropsStandaloneNumbers() {
        let input = "hello 50 world 424"
        let result = PromptContextSanitizer.sanitizeOCR(input)
        XCTAssertFalse(result.contains("50"))
        XCTAssertFalse(result.contains("424"))
        XCTAssertTrue(result.contains("hello"))
        XCTAssertTrue(result.contains("world"))
    }

    func test_sanitizeOCR_dropsShortNoiseTokensButKeepsPreservedWords() {
        // "I" and "if" are in the preserved set; "x" is not
        let input = "I like if x"
        let result = PromptContextSanitizer.sanitizeOCR(input)
        XCTAssertTrue(result.contains("I"))
        XCTAssertTrue(result.contains("if"))
        XCTAssertTrue(result.contains("like"))
        XCTAssertFalse(result.contains(" x"))
    }

    func test_sanitizeOCR_dropsLineWhenMajorityTokensAreNoise() {
        // 3 of 4 tokens are noise (>50%): "50", "x", "99" — only "hello" survives
        let input = "50 x 99 hello"
        let result = PromptContextSanitizer.sanitizeOCR(input)
        XCTAssertEqual(result, "")
    }

    func test_sanitizeOCR_keepsLineWhenHalfOrMoreTokensSurvive() {
        // 2 of 4 tokens survive (exactly 50%): kept.count * 2 >= tokens.count
        let input = "hello world 50 99"
        let result = PromptContextSanitizer.sanitizeOCR(input)
        XCTAssertTrue(result.contains("hello"))
        XCTAssertTrue(result.contains("world"))
    }

    func test_sanitizeOCR_respectsMaxCharacters() {
        let input = "alpha beta gamma delta epsilon"
        let result = PromptContextSanitizer.sanitizeOCR(input, maxCharacters: 10)
        XCTAssertLessThanOrEqual(result.count, 10)
    }

    func test_sanitizeOCR_returnsEmptyForAllNoiseInput() {
        let input = "50 424 102 99"
        let result = PromptContextSanitizer.sanitizeOCR(input)
        XCTAssertEqual(result, "")
    }

    func test_sanitizeOCR_dropsRandomMixedCaseAndAlphanumericGarbage() {
        let input = """
        gLVWrt bDokE 54tbdbDX
        Visible task update Screen Recording copy for Cotabby
        """

        let result = PromptContextSanitizer.sanitizeOCR(input)

        XCTAssertFalse(result.contains("gLVWrt"))
        XCTAssertFalse(result.contains("bDokE"))
        XCTAssertFalse(result.contains("54tbdbDX"))
        XCTAssertTrue(result.contains("Visible task update Screen Recording copy for Cotabby"))
    }

    func test_sanitizeOCR_preservesUsefulTechnicalAndUserContext() {
        let input = """
        Cotabby PR API context needs GeneralPaneView.swift normalizedBundleIdentifier jane@example.com
        """

        let result = PromptContextSanitizer.sanitizeOCR(input)

        XCTAssertTrue(result.contains("Cotabby"))
        XCTAssertTrue(result.contains("PR"))
        XCTAssertTrue(result.contains("API"))
        XCTAssertTrue(result.contains("GeneralPaneView.swift"))
        XCTAssertTrue(result.contains("normalizedBundleIdentifier"))
        XCTAssertTrue(result.contains("jane@example.com"))
    }

    func test_sanitizeOCR_dropsLineWhereMostTokensAreOCRNoise() {
        let input = "gLVWrt 54tbdbDX bDokE User"
        let result = PromptContextSanitizer.sanitizeOCR(input)
        XCTAssertEqual(result, "")
    }

    func test_sanitizeOCR_preservesNonLatinScripts() {
        // CJK, Cyrillic, and accented Latin carry real context but have no ASCII vowel and never
        // match the English word lists. They must survive OCR filtering so non-English users are
        // not left with empty visual context.
        let input = """
        会議の議題を確認してください
        Привет команда смотрите задачу
        Préparez la réunion à Zürich
        """

        let result = PromptContextSanitizer.sanitizeOCR(input)

        XCTAssertTrue(result.contains("会議の議題を確認してください"))
        XCTAssertTrue(result.contains("Привет"))
        XCTAssertTrue(result.contains("задачу"))
        XCTAssertTrue(result.contains("réunion"))
        XCTAssertTrue(result.contains("Zürich"))
    }

    func test_sanitizeOCR_keepsNonLatinButStillDropsAsciiNoiseOnSameLine() {
        // The non-Latin allowance must not become a backdoor for ASCII OCR garbage on the same line.
        let input = "東京 gLVWrt オフィス 54tbdbDX"
        let result = PromptContextSanitizer.sanitizeOCR(input)

        XCTAssertTrue(result.contains("東京"))
        XCTAssertTrue(result.contains("オフィス"))
        XCTAssertFalse(result.contains("gLVWrt"))
        XCTAssertFalse(result.contains("54tbdbDX"))
    }

    func test_sanitizeOCR_dropsLineOfOnlyWeakShortWords() {
        // Preserved short words survive token scoring but are never strong signal on their own, so
        // a line made entirely of them is UI chrome ("we", "go", "to") and must be dropped whole.
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR("we go to it"), "")
    }

    func test_sanitizeOCR_dropsRepeatedGlyphRuns() {
        // "aaaa" is the repeated-glyph hallucination shape; the real words around it must survive.
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR("meeting notes aaaa"), "meeting notes")
    }

    func test_sanitizeOCR_returnsEmptyWhenBaseSanitizationLeavesNothing() {
        // Symbols-only input sanitizes to an empty base string, which becomes one empty line; the
        // OCR line filter must treat that as no tokens, not crash or emit whitespace.
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR("*** ---"), "")
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR(""), "")
    }

    func test_sanitizeOCR_dropsLetterlessDottedToken() {
        // "12.34" splits like a domain but carries no letters, is not all-digits (the dot), and has
        // no word signal, so it scores as numeric UI chrome and is dropped.
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR("meeting notes 12.34"), "meeting notes")
    }

    func test_sanitizeOCR_dropsLowercaseLedTokenWithInteriorCapital() {
        // "abeW" has vowels, so only the mixed-case rule can reject it: a non-leading capital in a
        // short token without a known technical word is OCR garbage, unlike "Safari"-style prose.
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR("meeting notes abeW"), "meeting notes")
    }

    // MARK: - significantTokens

    func test_significantTokens_emitsCJKBigramEvidence() {
        let tokens = PromptContextSanitizer.significantTokens(from: "发布计划")

        XCTAssertTrue(tokens.contains("发布"))
        XCTAssertTrue(tokens.contains("布计"))
        XCTAssertTrue(tokens.contains("计划"))
    }

    func test_significantTokens_omitsSingletonCJKAndCommonEnglishWords() {
        XCTAssertFalse(PromptContextSanitizer.significantTokens(from: "会").contains("会"))
        XCTAssertFalse(PromptContextSanitizer.significantTokens(from: "します").contains("ます"))
        XCTAssertFalse(PromptContextSanitizer.significantTokens(from: "것입니다").contains("것입니다"))
        XCTAssertTrue(PromptContextSanitizer.significantTokens(from: "배포 계획을").contains("계획"))
        XCTAssertFalse(PromptContextSanitizer.significantTokens(from: "the deployment").contains("the"))
        XCTAssertTrue(PromptContextSanitizer.significantTokens(from: "the deployment").contains("deployment"))
    }

    func test_significantTokens_normalizesFullWidthLatin() {
        XCTAssertTrue(PromptContextSanitizer.significantTokens(from: "ＡＰＩ status").contains("api"))
    }

    func test_significantTokens_supportsNewerCJKExtensions() {
        XCTAssertTrue(
            PromptContextSanitizer.significantTokens(from: "\u{2A700}\u{2A701}")
                .contains("\u{2A700}\u{2A701}")
        )
        XCTAssertTrue(
            PromptContextSanitizer.significantTokens(from: "\u{31350}\u{31351}")
                .contains("\u{31350}\u{31351}")
        )
    }

    func test_relevanceEvidence_requiresStrongCJKOverlap() {
        XCTAssertFalse(
            PromptContextSanitizer.hasMeaningfulRelevance(
                between: "发布按钮",
                and: "发布计划正在审核"
            )
        )
        XCTAssertTrue(
            PromptContextSanitizer.hasMeaningfulRelevance(
                between: "发布计划等待审核",
                and: "发布计划正在"
            )
        )
        XCTAssertFalse(
            PromptContextSanitizer.hasMeaningfulRelevance(
                between: "給与明細を共有します",
                and: "この処理を実行します"
            )
        )
        XCTAssertFalse(
            PromptContextSanitizer.hasMeaningfulRelevance(
                between: "급여 명세를 공유합니다",
                and: "이 작업을 실행합니다"
            )
        )
        XCTAssertFalse(
            PromptContextSanitizer.hasMeaningfulRelevance(
                between: "급여 명세는 안전할 것입니다",
                and: "이 작업은 실행될 것입니다"
            )
        )
        XCTAssertFalse(
            PromptContextSanitizer.hasMeaningfulRelevance(
                between: "급여를 합니다",
                and: "회의를 합니다"
            )
        )
    }

    // MARK: - containsAlphanumericSignal

    func test_containsAlphanumericSignal_returnsTrueForMixedInput() {
        XCTAssertTrue(PromptContextSanitizer.containsAlphanumericSignal("---a---"))
    }

    func test_containsAlphanumericSignal_returnsFalseForPureSymbols() {
        XCTAssertFalse(PromptContextSanitizer.containsAlphanumericSignal("--- ---"))
    }

    func test_containsAlphanumericSignal_returnsFalseForEmptyString() {
        XCTAssertFalse(PromptContextSanitizer.containsAlphanumericSignal(""))
    }
}
