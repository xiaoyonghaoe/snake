import AppKit
import XCTest
@testable import SnakeApp

@MainActor
final class TerminalThemeImportTests: XCTestCase {
    private func plist(includeBackground: Bool = true, invalidRed: Double? = nil) throws -> Data {
        let color: [String: Any] = ["Red Component": invalidRed ?? 0.25,
                                    "Green Component": 0.5, "Blue Component": 0.75]
        var root: [String: Any] = ["Foreground Color": color]
        if includeBackground { root["Background Color"] = color }
        for index in 0..<16 { root["Ansi \(index) Color"] = color }
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    func testSinglePaletteUsesOriginalBackgroundInBothAppearances() throws {
        let parsed = try ITermColorsParser.parse(plist(), name: "Example")
        XCTAssertEqual(parsed.palette(isDark: false).background, 0x4080BF)
        XCTAssertEqual(parsed.palette(isDark: true).background, 0x4080BF)
        XCTAssertEqual(parsed.palette(isDark: true).ansi.count, 16)
        XCTAssertEqual(parsed.palette(isDark: true).cursor, 0x4080BF)
    }

    func testRejectsMissingInvalidAndOversizedPalettes() throws {
        XCTAssertThrowsError(try ITermColorsParser.parse(plist(includeBackground: false), name: "Missing"))
        XCTAssertThrowsError(try ITermColorsParser.parse(plist(invalidRed: 1.5), name: "Invalid"))
        XCTAssertThrowsError(try ITermColorsParser.parse(Data("garbage".utf8), name: "Broken"))
        XCTAssertThrowsError(try ITermColorsParser.parse(Data(repeating: 65, count: 1_048_577), name: "Huge"))
    }

    func testPairedLightDarkPalettesSwitchWithAppearance() throws {
        let original = try XCTUnwrap(PropertyListSerialization.propertyList(from: plist(), format: nil) as? [String: Any])
        var light: [String: Any] = [:]
        var dark: [String: Any] = [:]
        for (key, value) in original {
            light[key] = value
            dark[key] = value
        }
        dark["Background Color"] = ["Red Component": 0.0, "Green Component": 0.0, "Blue Component": 0.0]
        let data = try PropertyListSerialization.data(fromPropertyList: ["Light": light, "Dark": dark],
                                                     format: .xml, options: 0)
        let theme = try ITermColorsParser.parse(data, name: "Paired")
        XCTAssertEqual(theme.palette(isDark: false).background, 0x4080BF)
        XCTAssertEqual(theme.palette(isDark: true).background, 0x000000)
    }

    func testImportPersistenceDeletionAndMissingSelectionFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snake-themes-\(UUID())")
        let library = TerminalThemeLibrary(directoryURL: root.appendingPathComponent("themes"))
        let suite = "snake-themes-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let theme = try library.add(data: plist(), name: "Example")
        XCTAssertEqual(library.load(), [theme])
        let file = library.directoryURL.appendingPathComponent("\(theme.id.uuidString).json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        defaults.set(theme.selectionID, forKey: "com.snake.terminal.theme")
        let store = ApplicationStore(databaseURL: root.appendingPathComponent("db.sqlite3"),
                                     userDefaults: defaults, terminalThemeDirectoryURL: library.directoryURL)
        XCTAssertEqual(store.selectedTerminalThemeID, theme.selectionID)
        XCTAssertEqual(store.terminalTheme(isDark: false).backgroundHex, 0x4080BF)
        let badFile = root.appendingPathComponent("damaged.itermcolors")
        try Data("not a plist".utf8).write(to: badFile)
        store.importTerminalTheme(from: badFile)
        XCTAssertEqual(store.selectedTerminalThemeID, theme.selectionID)
        XCTAssertNotNil(store.terminalThemeNotice)
        store.deleteSelectedImportedTerminalTheme()
        XCTAssertEqual(store.selectedTerminalThemeID, TerminalThemePreset.tokyoNight.rawValue)
        XCTAssertTrue(library.load().isEmpty)
        defaults.set(theme.selectionID, forKey: "com.snake.terminal.theme")
        let restored = ApplicationStore(databaseURL: root.appendingPathComponent("db.sqlite3"),
                                        userDefaults: defaults, terminalThemeDirectoryURL: library.directoryURL)
        XCTAssertEqual(restored.selectedTerminalThemeID, TerminalThemePreset.tokyoNight.rawValue)
        XCTAssertNotNil(restored.terminalThemeNotice)
    }
}
