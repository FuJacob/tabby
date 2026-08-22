import XCTest
@testable import Cotabby

final class ModelDownloadSessionDelegateTests: XCTestCase {
    func test_cancelBeforeDownloadPreventsTheRequestFromStarting() async {
        let delegate = ModelDownloadSessionDelegate { _ in }
        delegate.cancel()

        do {
            _ = try await delegate.download(from: URL(string: "https://example.com/model.gguf")!)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: the preflight state wins before URLSession starts network work.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_pauseBeforeDownloadPreventsTheRequestFromStarting() async {
        let delegate = ModelDownloadSessionDelegate { _ in }
        delegate.pause()

        do {
            _ = try await delegate.download(from: URL(string: "https://example.com/model.gguf")!)
            XCTFail("Expected pause")
        } catch URLSessionDownloadInterruption.paused(let resumeData) {
            XCTAssertNil(resumeData)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_delegateRejectsASecondDownloadAttempt() async {
        let delegate = ModelDownloadSessionDelegate { _ in }
        delegate.cancel()

        do {
            _ = try await delegate.download(from: URL(string: "https://example.com/first.gguf")!)
        } catch is CancellationError {
            // The first attempt consumes the single-use delegate.
        } catch {
            return XCTFail("Unexpected first-attempt error: \(error)")
        }

        do {
            _ = try await delegate.download(from: URL(string: "https://example.com/second.gguf")!)
            XCTFail("Expected the delegate to reject reuse")
        } catch let error as ModelDownloadSessionError {
            XCTAssertEqual(error, .alreadyStarted)
        } catch {
            XCTFail("Unexpected second-attempt error: \(error)")
        }
    }
}
