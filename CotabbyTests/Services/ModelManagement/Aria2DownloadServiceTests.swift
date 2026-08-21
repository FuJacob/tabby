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
        } catch let error as Aria2DownloadError {
            XCTFail("Expected a process-launch error, got \(error)")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func test_downloadThrowsExecutableNotFoundWhenNoLocatorMatch() async {
        let service = Aria2DownloadService { _ in }
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

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

    func test_cancelBeforeLaunchReturnsCancelled() async {
        let service = Aria2DownloadService { _ in }
        service.cancel()

        do {
            _ = try await service.download(
                from: URL(string: "https://example.com/model.gguf")!,
                filename: "model.gguf",
                stagingDirectory: FileManager.default.temporaryDirectory,
                executableURL: URL(fileURLWithPath: "/usr/bin/false")
            )
            XCTFail("Expected cancellation")
        } catch let error as Aria2DownloadError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_pauseBeforeLaunchReturnsPaused() async {
        let service = Aria2DownloadService { _ in }
        service.pause()

        do {
            _ = try await service.download(
                from: URL(string: "https://example.com/model.gguf")!,
                filename: "model.gguf",
                stagingDirectory: FileManager.default.temporaryDirectory,
                executableURL: URL(fileURLWithPath: "/usr/bin/false")
            )
            XCTFail("Expected pause")
        } catch let error as Aria2DownloadError {
            XCTAssertEqual(error, .paused)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_downloadRunsProcessAndReportsProgress() async throws {
        let executable = try makeExecutableScript(
            contents: """
            #!/bin/sh
            directory=""
            output=""
            for argument in "$@"; do
                case "$argument" in
                    --dir=*) directory=${argument#--dir=} ;;
                    --out=*) output=${argument#--out=} ;;
                esac
            done
            printf '[#abc123 1B/1B(100%%) CN:1 DL:1MiB ETA:0s]\n'
            printf 'model data' > "$directory/$output"
            """
        )
        let stagingDirectory = makeTemporaryDirectory()
        defer { removeFixtures(executable, stagingDirectory) }
        let recorder = Aria2ProgressRecorder()
        let service = Aria2DownloadService { recorder.append($0) }

        let result = try await service.download(
            from: URL(string: "https://example.com/model.gguf")!,
            filename: "model.gguf",
            stagingDirectory: stagingDirectory,
            executableURL: executable
        )

        XCTAssertEqual(result.lastPathComponent, "model.gguf")
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "model data")
        XCTAssertEqual(recorder.values.last?.progressFraction, 1)
        XCTAssertEqual(recorder.values.last?.speedFormatted, "1 MB/s")
    }

    func test_downloadSurfacesProcessExitAndStderr() async throws {
        let executable = try makeExecutableScript(
            contents: """
            #!/bin/sh
            echo 'simulated aria failure' >&2
            exit 7
            """
        )
        let stagingDirectory = makeTemporaryDirectory()
        defer { removeFixtures(executable, stagingDirectory) }
        let service = Aria2DownloadService { _ in }

        do {
            _ = try await service.download(
                from: URL(string: "https://example.com/model.gguf")!,
                filename: "model.gguf",
                stagingDirectory: stagingDirectory,
                executableURL: executable
            )
            XCTFail("Expected process failure")
        } catch let error as Aria2DownloadError {
            XCTAssertEqual(
                error,
                .processFailed(exitCode: 7, message: "simulated aria failure")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_pauseStopsRunningProcessAsPaused() async throws {
        let executable = try makeLongRunningExecutable()
        let stagingDirectory = makeTemporaryDirectory()
        defer { removeFixtures(executable, stagingDirectory) }
        let recorder = Aria2ProgressRecorder()
        let service = Aria2DownloadService { recorder.append($0) }
        let downloadTask = Task {
            try await service.download(
                from: URL(string: "https://example.com/model.gguf")!,
                filename: "model.gguf",
                stagingDirectory: stagingDirectory,
                executableURL: executable
            )
        }

        try await waitForProgress(recorder)
        service.pause()

        do {
            _ = try await downloadTask.value
            XCTFail("Expected pause")
        } catch let error as Aria2DownloadError {
            XCTAssertEqual(error, .paused)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_cancelStopsRunningProcessAsCancelled() async throws {
        let executable = try makeLongRunningExecutable()
        let stagingDirectory = makeTemporaryDirectory()
        defer { removeFixtures(executable, stagingDirectory) }
        let recorder = Aria2ProgressRecorder()
        let service = Aria2DownloadService { recorder.append($0) }
        let downloadTask = Task {
            try await service.download(
                from: URL(string: "https://example.com/model.gguf")!,
                filename: "model.gguf",
                stagingDirectory: stagingDirectory,
                executableURL: executable
            )
        }

        try await waitForProgress(recorder)
        service.cancel()

        do {
            _ = try await downloadTask.value
            XCTFail("Expected cancellation")
        } catch let error as Aria2DownloadError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeLongRunningExecutable() throws -> URL {
        try makeExecutableScript(
            contents: """
            #!/bin/sh
            trap 'exit 0' INT TERM
            printf '[#abc123 1B/10B(10%%) CN:1 DL:1MiB ETA:9s]\n'
            while true; do
                sleep 0.05
            done
            """
        )
    }

    private func makeExecutableScript(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-aria2-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func removeFixtures(_ urls: URL...) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func waitForProgress(_ recorder: Aria2ProgressRecorder) async throws {
        for _ in 0..<200 where recorder.values.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(recorder.values.isEmpty, "The fake process never emitted progress")
    }
}

private final class Aria2ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Aria2Progress] = []

    var values: [Aria2Progress] {
        lock.withLock { storage }
    }

    func append(_ progress: Aria2Progress) {
        lock.withLock {
            storage.append(progress)
        }
    }
}
