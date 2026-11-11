import XCTest
@testable import SnakeApp

@MainActor
final class LastSessionFolderTests: XCTestCase {
    func testLastFolderSurvivesRelaunchAndForgetsDeletedFolders() throws {
        let suite = "snake.tests.last-folder.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let database = root.appendingPathComponent("test.sqlite3")
        let store = ApplicationStore(databaseURL: database, userDefaults: defaults,
                                     keyDirectoryURL: root.appendingPathComponent("Keys"))
        XCTAssertNil(store.lastSessionFolderID, "a fresh install opens the top level")
        let folder = try XCTUnwrap(store.createFolder(named: "生产"))
        store.lastSessionFolderID = folder.id

        let relaunched = ApplicationStore(databaseURL: database, userDefaults: defaults,
                                          keyDirectoryURL: root.appendingPathComponent("Keys"))
        XCTAssertEqual(relaunched.lastSessionFolderID, folder.id)
        relaunched.deleteFolder(id: folder.id)
        XCTAssertNil(relaunched.lastSessionFolderID, "a deleted folder falls back to the top level")
    }

    func testNewSessionTabsStartUnrestored() {
        XCTAssertFalse(WorkspaceTabRuntime(manager: .sessions).restoredLastFolder)
    }
}
