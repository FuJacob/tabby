import XCTest
@testable import Cotabby

/// Locks down the deterministic line ranking shared by clipboard and OCR prompt context. Keeping the
/// selector pure lets multilingual relevance and source-local budgets run in normal CI without a
/// pasteboard, Vision, or a model.
final class ContextRelevanceSelectorTests: XCTestCase {
    func test_selectRelevantLines_prefersMoreRelevantThenRecentButRestoresReadingOrder() {
        let text = [
            "Earlier project note",
            "Project alpha is blocked",
            "Unrelated social reminder",
            "Project alpha is ready for review"
        ].joined(separator: "\n")

        let result = ContextRelevanceSelector.selectRelevantLines(
            from: text,
            prefixText: "The project alpha status is",
            limits: .init(maxLines: 3, maxCharacters: 200)
        )

        XCTAssertEqual(result, [
            "Earlier project note",
            "Project alpha is blocked",
            "Project alpha is ready for review"
        ].joined(separator: "\n"))
    }

    func test_selectRelevantLines_matchesCJKTermsWithoutWhitespaceBoundaries() {
        let text = [
            "明日の天気について",
            "发布说明已经准备好了",
            "发布计划需要审核"
        ].joined(separator: "\n")

        let result = ContextRelevanceSelector.selectRelevantLines(
            from: text,
            prefixText: "发布计划正在",
            limits: .init(maxLines: 3, maxCharacters: 200)
        )

        XCTAssertEqual(result, "发布计划需要审核")
    }

    func test_selectRelevantLines_matchesJapaneseAndKoreanTerms() {
        XCTAssertEqual(
            ContextRelevanceSelector.selectRelevantLines(
                from: "明日の天気\n会議資料を共有しました",
                prefixText: "会議資料を確認",
                limits: .init(maxLines: 2, maxCharacters: 200)
            ),
            "会議資料を共有しました"
        )
        XCTAssertEqual(
            ContextRelevanceSelector.selectRelevantLines(
                from: "점심 메뉴\n배포 계획 승인 완료",
                prefixText: "배포 계획을 검토",
                limits: .init(maxLines: 2, maxCharacters: 200)
            ),
            "배포 계획 승인 완료"
        )
    }

    func test_selectRelevantLines_matchesMixedFullWidthAndLatinTerms() {
        let result = ContextRelevanceSelector.selectRelevantLines(
            from: "ＡＰＩ 发布计划 ready\nunrelated reminder",
            prefixText: "API 发布状态",
            limits: .init(maxLines: 2, maxCharacters: 200)
        )

        XCTAssertEqual(result, "ＡＰＩ 发布计划 ready")
    }

    func test_selectRelevantLines_rejectsOneCommonCJKBigramAndJapaneseGrammar() {
        XCTAssertNil(
            ContextRelevanceSelector.selectRelevantLines(
                from: "发布按钮",
                prefixText: "发布计划正在审核",
                limits: .init(maxLines: 2, maxCharacters: 200)
            )
        )
        XCTAssertNil(
            ContextRelevanceSelector.selectRelevantLines(
                from: "給与明細を共有します",
                prefixText: "この処理を実行します",
                limits: .init(maxLines: 2, maxCharacters: 200)
            )
        )
        XCTAssertNil(
            ContextRelevanceSelector.selectRelevantLines(
                from: "급여 명세를 공유합니다",
                prefixText: "이 작업을 실행합니다",
                limits: .init(maxLines: 2, maxCharacters: 200)
            )
        )
        XCTAssertNil(
            ContextRelevanceSelector.selectRelevantLines(
                from: "급여 명세는 안전할 것입니다",
                prefixText: "이 작업은 실행될 것입니다",
                limits: .init(maxLines: 2, maxCharacters: 200)
            )
        )
        XCTAssertNil(
            ContextRelevanceSelector.selectRelevantLines(
                from: "급여를 합니다",
                prefixText: "회의를 합니다",
                limits: .init(maxLines: 2, maxCharacters: 200)
            )
        )
    }

    func test_selectRelevantLines_doesNotTreatOneCJKCharacterAsEvidence() {
        XCTAssertNil(
            ContextRelevanceSelector.selectRelevantLines(
                from: "会议预算已经批准",
                prefixText: "发布会马上开始",
                limits: .init(maxLines: 2, maxCharacters: 200)
            )
        )
    }

    func test_selectRelevantLines_ignoresCommonEnglishStopWords() {
        XCTAssertNil(
            ContextRelevanceSelector.selectRelevantLines(
                from: "the quarterly lunch menu",
                prefixText: "the deployment status",
                limits: .init(maxLines: 2, maxCharacters: 200)
            )
        )
    }

    func test_selectRelevantLines_appliesLineAndCharacterLimitsIncludingSeparators() {
        let result = ContextRelevanceSelector.selectRelevantLines(
            from: "project alpha\nproject beta\nproject gamma",
            prefixText: "project status",
            limits: .init(maxLines: 2, maxCharacters: 20)
        )

        XCTAssertEqual(result, "project gamma")
    }

    func test_selectRelevantLines_strongLaterLineCannotBeCrowdedOutByWeakEarlierLine() {
        let result = ContextRelevanceSelector.selectRelevantLines(
            from: String(repeating: "project detail ", count: 20)
                + "\nproject alpha status ready",
            prefixText: "project alpha status is",
            limits: .init(maxLines: 2, maxCharacters: 30)
        )

        XCTAssertEqual(result, "project alpha status ready")
    }

    func test_selectRelevantLines_revalidatesAnOversizedLineAfterTruncation() {
        let line = String(repeating: "unrelated ", count: 20) + "project alpha"

        XCTAssertNil(
            ContextRelevanceSelector.selectRelevantLines(
                from: line,
                prefixText: "project alpha status",
                limits: .init(maxLines: 1, maxCharacters: 40)
            )
        )
    }

    func test_selectRelevantLines_dropsPrefixDuplicate() {
        XCTAssertNil(
            ContextRelevanceSelector.selectRelevantLines(
                from: "shipping the release",
                prefixText: "We are shipping the release",
                limits: .init(maxLines: 2, maxCharacters: 200)
            )
        )
    }

    func test_selectRelevantLines_dropsDuplicateAfterSanitizationChangesPunctuation() {
        XCTAssertNil(
            ContextRelevanceSelector.selectRelevantLines(
                from: "Deploy alpha",
                prefixText: "Status: Deploy: alpha",
                limits: .init(maxLines: 2, maxCharacters: 200)
            )
        )
    }

    func test_selectRelevantLines_dropsSourceWithoutCaretEvidence() {
        XCTAssertNil(
            ContextRelevanceSelector.selectRelevantLines(
                from: "quarterly budget review",
                prefixText: "shipping the release",
                limits: .init(maxLines: 3, maxCharacters: 200)
            )
        )
    }

    func test_selectRelevantLines_deduplicatesRepeatedSourceLines() {
        let result = ContextRelevanceSelector.selectRelevantLines(
            from: "project alpha is ready\nProject   alpha is ready\nproject beta is blocked",
            prefixText: "project alpha status",
            limits: .init(maxLines: 3, maxCharacters: 200)
        )

        XCTAssertEqual(result, "Project   alpha is ready\nproject beta is blocked")
    }

    func test_selectRelevantLines_staysStableWhenPrefixGrowsWithoutChangingEvidence() {
        let text = "project alpha is ready\nunrelated reminder"
        let limits = ContextRelevanceSelector.Limits(maxLines: 2, maxCharacters: 200)

        let first = ContextRelevanceSelector.selectRelevantLines(
            from: text,
            prefixText: "project alpha status",
            limits: limits
        )
        let second = ContextRelevanceSelector.selectRelevantLines(
            from: text,
            prefixText: "project alpha status today",
            limits: limits
        )

        XCTAssertEqual(first, second)
    }

    func test_selectRelevantLines_isDeterministic() {
        let text = "release alpha\nrelease beta\nrelease gamma"
        let limits = ContextRelevanceSelector.Limits(maxLines: 2, maxCharacters: 200)
        let expected = ContextRelevanceSelector.selectRelevantLines(
            from: text,
            prefixText: "release status",
            limits: limits
        )

        for _ in 0..<20 {
            XCTAssertEqual(
                ContextRelevanceSelector.selectRelevantLines(
                    from: text,
                    prefixText: "release status",
                    limits: limits
                ),
                expected
            )
        }
    }
}
