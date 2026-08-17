import XCTest
@testable import Cotabby

final class Aria2LocatorTests: XCTestCase {
    func test_executableURL_findsExistingBinaryOrReturnsNil() {
        // When aria2c is installed on this machine, executableURL should be non-nil
        if Aria2Locator.isAvailable {
            let url = Aria2Locator.executableURL()
            XCTAssertNotNil(url)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url!.path))
        }
    }
}
