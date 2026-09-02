import XCTest
@testable import Cotabby

final class ClipboardContentDistillerTests: XCTestCase {
    func test_shortClipboard_keepsOnlyRelevantLines() {
        let result = ClipboardContentDistiller.distill(
            clipboard: "meeting agenda\nunrelated lunch\nmeeting decisions",
            prefixText: "the meeting starts soon"
        )

        XCTAssertEqual(result, "meeting agenda\nmeeting decisions")
    }

    func test_longClipboard_keepsOnlyMatchingLines() {
        let clipboard = [
            "import Foundation",
            "import UIKit",
            "func deploy() {",
            "    print(\"starting deploy\")",
            "}"
        ].joined(separator: "\n")

        let result = ClipboardContentDistiller.distill(
            clipboard: clipboard,
            prefixText: "the deploy is running"
        )

        XCTAssertEqual(result, [
            "func deploy() {",
            "print(\"starting deploy\")"
        ].joined(separator: "\n"))
    }

    func test_unrelatedClipboard_returnsNilInsteadOfHeadFallback() {
        let clipboard = [
            "alpha bravo charlie",
            "delta echo foxtrot",
            "golf hotel india",
            "juliet kilo lima"
        ].joined(separator: "\n")

        XCTAssertNil(
            ClipboardContentDistiller.distill(
                clipboard: clipboard,
                prefixText: "completely different words"
            )
        )
    }

    func test_caseInsensitiveMatching() {
        let clipboard = [
            "The DEPLOYMENT pipeline",
            "Some unrelated header",
            "Another random line",
            "Check deployment status"
        ].joined(separator: "\n")

        let result = ClipboardContentDistiller.distill(
            clipboard: clipboard,
            prefixText: "our deployment is slow"
        )

        XCTAssertEqual(result, [
            "The DEPLOYMENT pipeline",
            "Check deployment status"
        ].joined(separator: "\n"))
    }

    func test_cjkClipboard_keepsRelevantLines() {
        let result = ClipboardContentDistiller.distill(
            clipboard: "午餐时间十二点\n发布说明已经完成\n发布计划等待审核",
            prefixText: "发布计划正在"
        )

        XCTAssertEqual(result, "发布计划等待审核")
    }

    func test_shortTokensAndEmptyPrefix_returnNil() {
        XCTAssertNil(
            ClipboardContentDistiller.distill(
                clipboard: "a b c\nx y z",
                prefixText: "a b c x y z"
            )
        )
        XCTAssertNil(
            ClipboardContentDistiller.distill(
                clipboard: "line one content",
                prefixText: ""
            )
        )
    }

    func test_customLimits_boundLinesAndCharacters() {
        let result = ClipboardContentDistiller.distill(
            clipboard: "project alpha\nproject beta\nproject gamma",
            prefixText: "project status",
            limits: .init(maxLines: 2, maxCharacters: 20)
        )

        XCTAssertEqual(result, "project gamma")
    }
}
