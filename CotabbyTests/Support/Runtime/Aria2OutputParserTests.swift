import XCTest
@testable import Cotabby

final class Aria2OutputParserTests: XCTestCase {
    func test_parseFullProgressLine() {
        let line = "[#e54b67 1.2GiB/4.5GiB(26%) CN:8 DL:42.5MiB ETA:1m15s]"
        let progress = Aria2OutputParser.parse(line: line)

        XCTAssertNotNil(progress)
        XCTAssertEqual(progress?.progressFraction, 0.26)
        XCTAssertEqual(progress?.connectionCount, 8)
        XCTAssertEqual(progress?.speedFormatted, "42.5 MB/s")
        XCTAssertEqual(progress?.etaFormatted, "1m 15s")
    }

    func test_parseProgressLineWithoutSpeedOrETA() {
        let line = "[#123456 0B/1.4GiB(0%) CN:1]"
        let progress = Aria2OutputParser.parse(line: line)

        XCTAssertNotNil(progress)
        XCTAssertEqual(progress?.progressFraction, 0.0)
        XCTAssertEqual(progress?.connectionCount, 1)
        XCTAssertNil(progress?.speedFormatted)
        XCTAssertNil(progress?.etaFormatted)
    }

    func test_parseProgressLineCompleted() {
        let line = "[#abcdef 4.5GiB/4.5GiB(100%)]"
        let progress = Aria2OutputParser.parse(line: line)

        XCTAssertNotNil(progress)
        XCTAssertEqual(progress?.progressFraction, 1.0)
        XCTAssertNil(progress?.connectionCount)
    }

    func test_parseNonProgressLineReturnsNil() {
        XCTAssertNil(Aria2OutputParser.parse(line: "Download Results:"))
        XCTAssertNil(Aria2OutputParser.parse(line: "08/17 12:00:00 [NOTICE] Connecting to https://huggingface.co"))
        XCTAssertNil(Aria2OutputParser.parse(line: ""))
    }
}
