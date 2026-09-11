import XCTest
@testable import SnakeApp

final class SFTPSelectionTests: XCTestCase {
    func testCommandAddsAndRemovesWithoutLosingOtherItems() {
        let ids = (0..<5).map { _ in UUID() }
        var selection = SFTPSelection()
        selection.click(ids[0], order: ids)
        selection.click(ids[3], order: ids, command: true)
        XCTAssertEqual(selection.ids, [ids[0], ids[3]])
        selection.click(ids[0], order: ids, command: true)
        XCTAssertEqual(selection.ids, [ids[3]])
    }

    func testShiftRangeExpandsAndContractsFromAnchor() {
        let ids = (0..<6).map { _ in UUID() }
        var selection = SFTPSelection()
        selection.click(ids[1], order: ids)
        selection.click(ids[5], order: ids, shift: true)
        XCTAssertEqual(selection.ids, Set(ids[1...5]))
        selection.click(ids[3], order: ids, shift: true)
        XCTAssertEqual(selection.ids, Set(ids[1...3]))
        selection.click(ids[0], order: ids, shift: true)
        XCTAssertEqual(selection.ids, Set(ids[0...1]))
    }

    func testCommandShiftUnionsAndContextClickRetainsSelectedBatch() {
        let ids = (0..<6).map { _ in UUID() }
        var selection = SFTPSelection()
        selection.click(ids[0], order: ids)
        selection.click(ids[3], order: ids, command: true)
        selection.click(ids[5], order: ids, command: true, shift: true)
        XCTAssertEqual(selection.ids, Set([ids[0]] + Array(ids[3...5])))
        selection.contextClick(ids[4], order: ids)
        XCTAssertEqual(selection.ids.count, 4)
        selection.contextClick(ids[2], order: ids)
        XCTAssertEqual(selection.ids, [ids[2]])
    }

    func testStaleSelectionAndUnsafeDeletionTargetsAreRejected() {
        let id = UUID()
        var selection = SFTPSelection()
        selection.click(id, order: [])
        XCTAssertTrue(selection.ids.isEmpty)
        let paths = ["/", "/tmp/..", "relative", "/tmp/a", "/tmp/a", "/tmp/中文 '文件"]
        let files = paths.map { RemoteFile(name: "test", path: $0, isDirectory: false) }
        XCTAssertEqual(SFTPDeletionBatch.targets(files).map(\.path), ["/tmp/a", "/tmp/中文 '文件"])
    }

    func testDirectorySymlinkIsNeverRecursivelyDeleted() {
        let directory = RemoteFile(name: "folder", path: "/tmp/folder", isDirectory: true)
        let link = RemoteFile(name: "link", path: "/tmp/link", isDirectory: true, isSymbolicLink: true, linkTarget: "/")
        XCTAssertTrue(SFTPDeletionBatch.usesRecursiveRemoval(directory))
        XCTAssertFalse(SFTPDeletionBatch.usesRecursiveRemoval(link))
    }
}
