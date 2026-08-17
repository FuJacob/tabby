import XCTest
@testable import Cotabby

final class Aria2DownloadServiceTests: XCTestCase {
    func test_downloadThrowsWhenInvalidExecutablePathProvided() async {
        let service = Aria2DownloadService { _ in }
        let invalidExecutable = URL(fileURLWithPath: "/non/existent/path/aria2c")
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        do {
            _ = try await service.download(
                from: URL(string: "https://example.com/model.gguf")!,
                filename: "model.gguf",
                stagingDirectory: stagingDir,
                executableURL: invalidExecutable
            )
            XCTFail("Expected error when providing nonexistent executable")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func test_downloadThrowsExecutableNotFoundWhenNoLocatorMatch() async {
        let service = Aria2DownloadService { _ in }
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        // When executableURL is nil and locator finds nothing, throws executableNotFound
        do {
            _ = try await service.download(
                from: URL(string: "https://example.com/model.gguf")!,
                filename: "model.gguf",
                stagingDirectory: stagingDir,
                executableURL: nil,
                locator: { nil }
            )
            XCTFail("Expected executableNotFound error")
        } catch let error as Aria2DownloadError {
            XCTAssertEqual(error, .executableNotFound)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_aria2DownloadError_localizedDescription() {
        XCTAssertEqual(
            Aria2DownloadError.executableNotFound.errorDescription,
            "aria2c executable was not found on the system."
        )
        XCTAssertEqual(
            Aria2DownloadError.cancelled.errorDescription,
            "Download was cancelled by the user."
        )
        XCTAssertEqual(
            Aria2DownloadError.paused.errorDescription,
            "Download was paused by the user."
        )
        XCTAssertEqual(
            Aria2DownloadError.processFailed(exitCode: 1, message: "Network error").errorDescription,
            "aria2c download failed (exit code 1): Network error"
        )
    }
}
