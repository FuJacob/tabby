import XCTest
@testable import Cotabby

final class StubExecutableFileManager: FileManager, @unchecked Sendable {
    var executablePaths: Set<String> = []

    override func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

final class Aria2LocatorTests: XCTestCase {
    func test_executableURL_returnsNilWhenNoCandidatesAreExecutable() {
        let stub = StubExecutableFileManager()
        stub.executablePaths = []
        XCTAssertNil(Aria2Locator.executableURL(fileManager: stub))
    }

    func test_executableURL_prioritizesUserDownloadedBinary() {
        let stub = StubExecutableFileManager()
        let userURL = Aria2Locator.userDownloadedBinaryURL
        stub.executablePaths = [userURL.path, "/opt/homebrew/bin/aria2c"]

        let resolved = Aria2Locator.executableURL(fileManager: stub)
        XCTAssertEqual(resolved?.path, userURL.path)
    }

    func test_executableURL_resolvesHomebrewPathWhenUserBinaryAbsent() {
        let stub = StubExecutableFileManager()
        stub.executablePaths = ["/opt/homebrew/bin/aria2c"]

        let resolved = Aria2Locator.executableURL(fileManager: stub)
        XCTAssertEqual(resolved?.path, "/opt/homebrew/bin/aria2c")
    }
}
