import XCTest
@testable import Cotabby

@MainActor
final class ModelDownloadManagerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_modelsDirectoryPath_pointsToProvidedRuntimeDirectory() {
        let manager = ModelDownloadManager(runtimeDirectoryURL: tempDir)
        XCTAssertEqual(manager.modelsDirectoryPath, tempDir.path)
    }

    func test_isModelInstalled_returnsFalseWhenFileAbsent() {
        let manager = ModelDownloadManager(runtimeDirectoryURL: tempDir)
        XCTAssertFalse(manager.isModelInstalled(filename: "nonexistent.gguf"))
    }

    func test_isModelInstalled_returnsTrueWhenFileExistsInDirectory() throws {
        let testFile = tempDir.appendingPathComponent("test-model.gguf")
        try "dummy model content".write(to: testFile, atomically: true, encoding: .utf8)

        let manager = ModelDownloadManager(runtimeDirectoryURL: tempDir)
        XCTAssertTrue(manager.isModelInstalled(filename: "test-model.gguf"))
    }

    func test_canDeleteModel_onlyAllowsUserRuntimeDirectoryFiles() throws {
        let testFile = tempDir.appendingPathComponent("deletable.gguf")
        try "content".write(to: testFile, atomically: true, encoding: .utf8)

        let manager = ModelDownloadManager(runtimeDirectoryURL: tempDir)
        XCTAssertTrue(manager.canDeleteModel(filename: "deletable.gguf"))
        XCTAssertFalse(manager.canDeleteModel(filename: "nonexistent.gguf"))
    }

    func test_deleteModel_removesFileAndRefreshesState() throws {
        let testFile = tempDir.appendingPathComponent("to-delete.gguf")
        try "content".write(to: testFile, atomically: true, encoding: .utf8)

        let manager = ModelDownloadManager(runtimeDirectoryURL: tempDir)
        XCTAssertTrue(manager.isModelInstalled(filename: "to-delete.gguf"))

        manager.deleteModel(filename: "to-delete.gguf")
        XCTAssertFalse(manager.isModelInstalled(filename: "to-delete.gguf"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: testFile.path))
    }
}
