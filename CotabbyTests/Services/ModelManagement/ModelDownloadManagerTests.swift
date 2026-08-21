import XCTest
@testable import Cotabby

@MainActor
final class ModelDownloadManagerTests: XCTestCase {
    /// Xcode 26.3's app-hosted test runner can crash in the back-deploy executor shim when a
    /// production `@MainActor` instance deinitializes, so retain fixtures for the process lifetime.
    private static var retainedManagers: [ModelDownloadManager] = []
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_modelsDirectoryPath_pointsToProvidedRuntimeDirectory() {
        let manager = makeManager()
        XCTAssertEqual(manager.modelsDirectoryPath, tempDir.path)
    }

    func test_isModelInstalled_returnsFalseWhenFileAbsent() {
        let manager = makeManager()
        XCTAssertFalse(manager.isModelInstalled(filename: "nonexistent.gguf"))
    }

    func test_isModelInstalled_returnsTrueWhenFileExistsInDirectory() throws {
        let testFile = tempDir.appendingPathComponent("test-model.gguf")
        try "dummy model content".write(to: testFile, atomically: true, encoding: .utf8)

        let manager = makeManager()
        XCTAssertTrue(manager.isModelInstalled(filename: "test-model.gguf"))
    }

    func test_canDeleteModel_onlyAllowsUserRuntimeDirectoryFiles() throws {
        let testFile = tempDir.appendingPathComponent("deletable.gguf")
        try "content".write(to: testFile, atomically: true, encoding: .utf8)

        let manager = makeManager()
        XCTAssertTrue(manager.canDeleteModel(filename: "deletable.gguf"))
        XCTAssertFalse(manager.canDeleteModel(filename: "nonexistent.gguf"))
    }

    func test_deleteModel_removesFileAndRefreshesState() throws {
        let testFile = tempDir.appendingPathComponent("to-delete.gguf")
        try "content".write(to: testFile, atomically: true, encoding: .utf8)

        let manager = makeManager()
        XCTAssertTrue(manager.isModelInstalled(filename: "to-delete.gguf"))

        manager.deleteModel(filename: "to-delete.gguf")
        XCTAssertFalse(manager.isModelInstalled(filename: "to-delete.gguf"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: testFile.path))
    }

    private func makeManager() -> ModelDownloadManager {
        let manager = ModelDownloadManager(runtimeDirectoryURL: tempDir)
        Self.retainedManagers.append(manager)
        return manager
    }
}
