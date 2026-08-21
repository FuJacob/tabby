import XCTest
@testable import Cotabby

final class Aria2StagingDirectoryResolverTests: XCTestCase {
    private let runtimeDirectory = URL(fileURLWithPath: "/tmp/CotabbyModels", isDirectory: true)

    func test_directoryIsStableForTheSameSource() {
        let sourceURL = URL(string: "https://example.com/repo-a/model.gguf")!

        let first = Aria2StagingDirectoryResolver.directory(
            in: runtimeDirectory,
            downloadURL: sourceURL,
            filename: "model.gguf"
        )
        let second = Aria2StagingDirectoryResolver.directory(
            in: runtimeDirectory,
            downloadURL: sourceURL,
            filename: "model.gguf"
        )

        XCTAssertEqual(first, second)
    }

    func test_sameFilenameFromDifferentSourcesUsesDifferentDirectories() {
        let first = Aria2StagingDirectoryResolver.directory(
            in: runtimeDirectory,
            downloadURL: URL(string: "https://example.com/repo-a/model.gguf")!,
            filename: "model.gguf"
        )
        let second = Aria2StagingDirectoryResolver.directory(
            in: runtimeDirectory,
            downloadURL: URL(string: "https://example.com/repo-b/model.gguf")!,
            filename: "model.gguf"
        )

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.lastPathComponent.hasSuffix("-model.gguf"))
        XCTAssertTrue(second.lastPathComponent.hasSuffix("-model.gguf"))
    }

    func test_filenameIsReducedToItsLeafComponent() {
        let directory = Aria2StagingDirectoryResolver.directory(
            in: runtimeDirectory,
            downloadURL: URL(string: "https://example.com/model.gguf")!,
            filename: "nested/model.gguf"
        )

        XCTAssertEqual(directory.deletingLastPathComponent(), runtimeDirectory)
        XCTAssertTrue(directory.lastPathComponent.hasSuffix("-model.gguf"))
    }
}
