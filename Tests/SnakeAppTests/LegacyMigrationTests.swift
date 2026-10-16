import Foundation
import XCTest
@testable import SnakeApp

@MainActor
final class LegacyMigrationTests: XCTestCase {
    func testMalformedLegacyDataIsNotDeletedByAnEmptyImport() throws {
        let suite = "snake-legacy-malformed-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let bytes = Data("{truncated legacy data".utf8)
        defaults.set(bytes, forKey: "com.snake.profiles")
        _ = ApplicationStore(databaseURL: root.appendingPathComponent("db"), userDefaults: defaults)
        XCTAssertEqual(defaults.data(forKey: "com.snake.profiles"), bytes)
    }

    func testInvalidLegacyPortFailsWithoutTrappingOrErasingTheOriginal() throws {
        let suite = "snake-legacy-invalid-port-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        for port in [-1, 0, 65_536] {
            let profile = SSHProfile(name: "bad port", host: "localhost", port: port, username: "user")
            let bytes = try JSONEncoder().encode([profile])
            defaults.set(bytes, forKey: "com.snake.profiles")
            _ = ApplicationStore(databaseURL: root.appendingPathComponent("db"), userDefaults: defaults)
            XCTAssertEqual(defaults.data(forKey: "com.snake.profiles"), bytes)
        }
    }

    func testUnavailableDatabaseKeepsAllLegacyDataUntilSuccessfulImport() throws {
        let suite = "snake-legacy-unavailable-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let group = SessionGroup(name: "legacy")
        let profile = SSHProfile(groupID: group.id, name: "host", host: "localhost", username: "user")
        let mapping = MountMapping(profileID: profile.id, name: "disk", remotePath: "/data",
            userAccessPath: root.appendingPathComponent("disk").path, managedMountPath: "/Users/Shared/.SnakeMounts/test")
        let keys = ["com.snake.groups", "com.snake.profiles", "com.snake.mounts"]
        let data = [try JSONEncoder().encode([group]), try JSONEncoder().encode([profile]), try JSONEncoder().encode([mapping])]
        for (key, value) in zip(keys, data) { defaults.set(value, forKey: key) }
        let database = root.appendingPathComponent("db")
        let unavailable = ApplicationStore(databaseURL: database, userDefaults: defaults)
        XCTAssertEqual(unavailable.profiles.map(\.id), [profile.id])
        for (key, value) in zip(keys, data) { XCTAssertEqual(defaults.data(forKey: key), value) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = ApplicationStore(databaseURL: database, userDefaults: defaults)
        let persisted = try CorePersistence(databaseURL: database)
        XCTAssertEqual(try persisted.loadGroups().map(\.id), [group.id])
        XCTAssertEqual(try persisted.loadProfiles().map(\.id), [profile.id])
        XCTAssertEqual(try persisted.loadMountMappings().map(\.id), [mapping.id])
        for key in keys { XCTAssertNil(defaults.data(forKey: key)) }
    }

    func testPartialImportRetriesMissingRowsAndKeepsExistingSQLiteEdits() throws {
        let suite = "snake-legacy-partial-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let first = SSHProfile(name: "first", host: "localhost", username: "user")
        var second = SSHProfile(name: "second", host: "", username: "user")
        let key = "com.snake.profiles"
        defaults.set(try JSONEncoder().encode([first, second]), forKey: key)
        let database = root.appendingPathComponent("db")
        let failed = ApplicationStore(databaseURL: database, userDefaults: defaults)
        XCTAssertEqual(Set(failed.profiles.map(\.id)), [first.id, second.id])
        XCTAssertNotNil(defaults.data(forKey: key))
        let persisted = try CorePersistence(databaseURL: database)
        XCTAssertEqual(try persisted.loadProfiles().map(\.id), [first.id])
        var edited = first
        edited.name = "SQLite edit"
        try persisted.save(edited)
        second.host = "fixed.example"
        defaults.set(try JSONEncoder().encode([first, second]), forKey: key)
        let retried = ApplicationStore(databaseURL: database, userDefaults: defaults)
        XCTAssertEqual(retried.profiles.first { $0.id == first.id }?.name, edited.name)
        XCTAssertEqual(Set(try persisted.loadProfiles().map(\.id)), [first.id, second.id])
        XCTAssertNil(defaults.data(forKey: key))
    }
}
