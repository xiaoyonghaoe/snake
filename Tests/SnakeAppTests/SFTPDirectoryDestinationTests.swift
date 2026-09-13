import XCTest
@testable import SnakeApp

final class SFTPDirectoryDestinationTests: XCTestCase {
    func testDestinationSnapshotsBrowserDirectoryNotClickedFolder() throws {
        var browserPath = "/data"
        let folder = RemoteFile(name: "logs", path: "/data/logs", isDirectory: true)
        let destination = try XCTUnwrap(SFTPDirectoryDestination(
            connectionState: .connected, currentPath: browserPath, loadingPath: nil
        ))
        browserPath = "/elsewhere"
        XCTAssertEqual(destination.path, "/data")
        XCTAssertNotEqual(destination.path, folder.path)
        XCTAssertNotEqual(destination.path, browserPath)
    }

    func testDisconnectedAndNavigatingCannotStartDirectoryActions() {
        for state: ConnectionState in [.idle, .connecting, .disconnected, .failed] {
            XCTAssertNil(SFTPDirectoryDestination(connectionState: state, currentPath: "/data", loadingPath: nil))
        }
        XCTAssertNil(SFTPDirectoryDestination(connectionState: .connected, currentPath: "/data", loadingPath: "/data/logs"))
        XCTAssertNotNil(SFTPDirectoryDestination(connectionState: .connected, currentPath: "/", loadingPath: nil))
    }
}
