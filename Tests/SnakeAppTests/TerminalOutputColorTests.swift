import AppKit
import XCTest
@testable import SnakeApp
@testable import SwiftTerm

@MainActor
final class TerminalOutputColorTests: XCTestCase {
    func testFieldMatchesAndNonMatches() {
        let matcher = TerminalOutputHighlighter(logs: true, fields: true)
        let input = "drwxr-xr-x 4.0K 2026-09-13 09:30 192.0.2.10:22 /var/log ~/文档 [INFO] running 80%"
        let source = input as NSString
        let tokens = matcher.matches(in: input).map { source.substring(with: $0.range) }
        XCTAssertEqual(tokens, ["drwxr-xr-x", "4.0K", "2026-09-13 09:30", "192.0.2.10:22", "/var/log", "~/文档", "INFO", "running", "80%"])
        let invalid = "errorCount information runningTotal 1234 999.2.3.4 192.0.2.1:99999 abcINFO SUCCESSFUL relative/path"
        XCTAssertTrue(matcher.matches(in: invalid).isEmpty)
    }

    func testIndependentSettingsAndPriority() {
        let plain = "ERROR failed INFO running 4KiB /srv/INFO/config"
        func tokens(logs: Bool, fields: Bool) -> [String] {
            TerminalOutputHighlighter(logs: logs, fields: fields).matches(in: plain)
                .map { (plain as NSString).substring(with: $0.range) }
        }
        XCTAssertEqual(tokens(logs: false, fields: false), [])
        XCTAssertEqual(tokens(logs: true, fields: false), ["ERROR", "INFO", "INFO"])
        XCTAssertEqual(tokens(logs: false, fields: true), ["failed", "running", "4KiB", "/srv/INFO/config"])
        XCTAssertEqual(tokens(logs: true, fields: true), ["ERROR", "failed", "INFO", "running", "4KiB", "/srv/INFO/config"])
    }

    func testIPTimePermissionAndUnicode() {
        let input = "中文 e\u{301} [2001:db8::1]:22 ::1 Sep 13 09:30 Sep 13 2025 -rw-r--r--@ 128MiB 1.5% /目录/日志"
        let matches = TerminalOutputHighlighter(logs: false, fields: true).matches(in: input)
        XCTAssertEqual(matches.map { (input as NSString).substring(with: $0.range) },
                       ["[2001:db8::1]:22", "::1", "Sep 13 09:30", "Sep 13 2025", "-rw-r--r--@", "128MiB", "1.5%", "/目录/日志"])
    }

    func testCachesStreamingAndOversizeLines() {
        let matcher = TerminalOutputHighlighter(logs: true, fields: true)
        XCTAssertTrue(matcher.matches(in: "runn").isEmpty)
        XCTAssertEqual(matcher.matches(in: "running").count, 1)
        _ = matcher.matches(in: "running")
        XCTAssertEqual(matcher.evaluationCount, 2)
        for i in 0..<1_000 { _ = matcher.matches(in: "INFO row \(i) /var/log") }
        XCTAssertLessThanOrEqual(matcher.cachedRowCount, 512)
        XCTAssertTrue(matcher.matches(in: "ERROR " + String(repeating: "x", count: 4_096)).isEmpty)
    }

    func testAllLightThemesUseWhiteBackground() {
        for preset in TerminalThemePreset.allCases {
            XCTAssertEqual(TerminalTheme(preset: preset, isDark: false).backgroundHex, 0xFFFFFF)
        }
    }

    func testTokyoPaletteMatchesPinnedFilesWithWhiteDayBackground() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for dark in [false, true] {
            let theme = TerminalTheme(preset: .tokyoNight, isDark: dark)
            let file = root.appendingPathComponent("Vendor/TokyoNight/tokyonight_\(dark ? "night" : "day").conf")
            let text = try String(contentsOf: file, encoding: .utf8)
            var colors: [String: UInt32] = [:]
            for line in text.split(separator: "\n") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                if parts.count == 2, parts[1].hasPrefix("#"), let hex = UInt32(parts[1].dropFirst(), radix: 16) {
                    colors[String(parts[0])] = hex
                }
            }
            XCTAssertEqual(theme.ansiHex, (0..<16).compactMap { colors["color\($0)"] })
            XCTAssertEqual(theme.backgroundHex, dark ? try XCTUnwrap(colors["background"]) : 0xFFFFFF)
            XCTAssertEqual(theme.foregroundHex, colors["foreground"])
            XCTAssertEqual(theme.cursorHex, colors["cursor"])
            XCTAssertEqual(theme.cursorTextHex, dark ? try XCTUnwrap(colors["cursor_text_color"]) : 0xFFFFFF)
            XCTAssertEqual(theme.selectionHex, colors["selection_background"])
        }
    }

    func testThemeMigrationRunsOnlyOnceAndNewSwitchesPersist() throws {
        let suite = "snake-tokyo-migration-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set("classic", forKey: "com.snake.terminal.theme")
        let first = ApplicationStore(databaseURL: root.appendingPathComponent("test.sqlite3"), userDefaults: defaults)
        XCTAssertEqual(first.terminalThemePreset, .tokyoNight)
        XCTAssertTrue(first.terminalFieldHighlightEnabled)
        XCTAssertTrue(first.terminalShellColorsEnabled)
        first.terminalThemePreset = .classic
        first.terminalFieldHighlightEnabled = false
        first.terminalShellColorsEnabled = false
        let second = ApplicationStore(databaseURL: root.appendingPathComponent("test.sqlite3"), userDefaults: defaults)
        XCTAssertEqual(second.terminalThemePreset, .classic)
        XCTAssertFalse(second.terminalFieldHighlightEnabled)
        XCTAssertFalse(second.terminalShellColorsEnabled)
    }

    func testLongWrappedFieldAndCapInSharedRenderer() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        view.terminal.resize(cols: 20, rows: 12)
        let theme = TerminalTheme(preset: .tokyoNight, isDark: false, fieldHighlightEnabled: true)
        theme.apply(to: view)
        view.feed(text: "prefix /very/long/directory/name/config.json")
        let buffer = view.terminal.buffer
        for row in 0..<3 {
            let colors = view.displayHighlightColors(row: row, line: buffer.lines[row], cols: buffer.cols)
            XCTAssertFalse(colors.isEmpty)
        }
        let original = view.terminal.getText(start: Position(col: 0, row: 0), end: Position(col: 10, row: 2))
        var changed = theme
        changed.fieldHighlightEnabled = false
        changed.apply(to: view)
        XCTAssertTrue(view.displayHighlightColors(row: 0, line: buffer.lines[0], cols: buffer.cols).isEmpty)
        XCTAssertEqual(view.terminal.getText(start: Position(col: 0, row: 0), end: Position(col: 10, row: 2)), original)
        theme.apply(to: view)
        view.feed(text: String(repeating: "x", count: 4_200))
        let current = view.terminal.buffer
        XCTAssertTrue(view.displayHighlightColors(row: current.yDisp, line: current.lines[current.yDisp], cols: current.cols).isEmpty)
    }
}
