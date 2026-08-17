import XCTest
@testable import Cotabby

final class Aria2ProvisionerTests: XCTestCase {
    func test_aria2Locator_userDownloadedBinaryURL_isDeterministic() {
        let url = Aria2Locator.userDownloadedBinaryURL
        XCTAssertTrue(url.path.contains("Cotabby/bin/aria2c"))
    }

    func test_aria2ProvisioningError_errorDescription() {
        XCTAssertEqual(
            Aria2ProvisioningError.downloadFailed("404 Not Found").errorDescription,
            "Failed to download aria2c binary: 404 Not Found"
        )
        XCTAssertEqual(
            Aria2ProvisioningError.extractionFailed("corrupt").errorDescription,
            "Failed to extract aria2c binary: corrupt"
        )
        XCTAssertEqual(
            Aria2ProvisioningError.invalidBinary.errorDescription,
            "Downloaded binary is corrupted or incompatible with this architecture."
        )
        XCTAssertEqual(
            Aria2ProvisioningError.permissionDenied.errorDescription,
            "Permission denied while setting executable attributes."
        )
    }

    func test_provisioner_returnsExistingURLIfAvailable() async throws {
        let stub = StubExecutableFileManager()
        stub.executablePaths = ["/opt/homebrew/bin/aria2c"]
        let provisioner = Aria2Provisioner(fileManager: stub)

        let url = try await provisioner.provisionIfNeeded()
        XCTAssertEqual(url.path, "/opt/homebrew/bin/aria2c")
    }
}
