import AppKit
import XCTest
@testable import SnakeApp
@testable import SwiftTerm

@MainActor
final class TerminalHighlightTests: XCTestCase {
    func testKeywordsAndUnicodeBoundaries() {
        let matcher = TerminalLogHighlighter()
        let text = "中文 [eRrOr] level=warn FATAL WARNING INFO DEBUG TRACE errorCount information DEBUGGER x_INFO 1WARN éERROR ERROR\u{301}"
        let matches = matcher.matches(in: text)
        XCTAssertEqual(matches.map(\.level), [.error, .warning, .error, .warning, .info, .debug, .debug])
        XCTAssertEqual(matches.map { (text as NSString).substring(with: $0.range) },
                       ["eRrOr", "warn", "FATAL", "WARNING", "INFO", "DEBUG", "TRACE"])
    }

    func testCacheReusesRowsAndBoundsMemory() {
        let matcher = TerminalLogHighlighter()
        _ = matcher.matches(in: "INFO first")
        _ = matcher.matches(in: "INFO first")
        XCTAssertEqual(matcher.evaluationCount, 1)
        for i in 0..<2_000 { _ = matcher.matches(in: "DEBUG row \(i)") }
        XCTAssertLessThanOrEqual(matcher.cachedRowCount, 512)
        XCTAssertTrue(matcher.matches(in: "ER").isEmpty)
        XCTAssertEqual(matcher.matches(in: "ERROR").first?.level, .error)
    }

    func testAllThemesAreReadableAndClassicUnchanged() {
        XCTAssertEqual(TerminalTheme.light.ansiHex[1], 0xCF222E)
        XCTAssertEqual(TerminalTheme.dark.ansiHex[4], 0x57C7FF)
        for preset in TerminalThemePreset.allCases {
            for dark in [false, true] {
                let theme = TerminalTheme(preset: preset, isDark: dark)
                XCTAssertEqual(theme.ansiHex.count, 16)
                for color in [theme.foregroundHex] + [.error, .warning, .info, .debug].map(theme.logColorHex)
                    + TerminalFieldRole.allCases.map(theme.fieldColorHex) {
                    XCTAssertGreaterThanOrEqual(contrast(color, theme.backgroundHex), 4.5)
                }
            }
        }
    }

    func testSettingsDefaultsPersistenceAndFallback() throws {
        let suite = "snake-theme-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let db = directory.appendingPathComponent("test.sqlite3")
        let store = ApplicationStore(databaseURL: db, userDefaults: defaults)
        XCTAssertEqual(store.terminalThemePreset, .tokyoNight)
        XCTAssertTrue(store.terminalLogHighlightEnabled)
        store.terminalThemePreset = .classic
        store.terminalLogHighlightEnabled = false
        let restored = ApplicationStore(databaseURL: db, userDefaults: defaults)
        XCTAssertEqual(restored.terminalThemePreset, .classic)
        XCTAssertFalse(restored.terminalLogHighlightEnabled)
        defaults.set("removed-preset", forKey: "com.snake.terminal.theme")
        XCTAssertEqual(ApplicationStore(databaseURL: db, userDefaults: defaults).terminalThemePreset, .tokyoNight)
    }

    func testSharedRendererUnicodeAndFragmentedOutput() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 1_000, height: 400))
        let theme = TerminalTheme(preset: .vivid, isDark: false)
        theme.apply(to: view)
        view.feed(text: "中文 😀 e\u{301} [ER")
        XCTAssertFalse(rendered(view).containsColor(TerminalTheme.nsColor(theme.logColorHex(.error))))
        view.feed(text: "ROR] normal")
        let output = rendered(view)
        let range = (output.string as NSString).range(of: "ERROR")
        XCTAssertNotEqual(range.location, NSNotFound)
        for offset in range.location..<NSMaxRange(range) {
            XCTAssertEqual(output.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor,
                           TerminalTheme.nsColor(theme.logColorHex(.error)))
        }
        XCTAssertEqual(output.attribute(.foregroundColor, at: NSMaxRange(range), effectiveRange: nil) as? NSColor,
                       view.nativeForegroundColor)
        view.terminal.resize(cols: 120, rows: 20)
        XCTAssertTrue(rendered(view).containsColor(TerminalTheme.nsColor(theme.logColorHex(.error))))
    }

    func testSoftWrapDoesNotTurnWordFragmentsIntoKeywords() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 1_000, height: 400))
        let theme = TerminalTheme(preset: .vivid, isDark: false)
        theme.apply(to: view)
        view.terminal.resize(cols: 10, rows: 10)
        view.feed(text: "1234 ERRORCount")
        XCTAssertFalse(rendered(view).containsColor(TerminalTheme.nsColor(theme.logColorHex(.error))))
        view.feed(text: "\r\n1234 ERROR")
        XCTAssertTrue(rendered(view, row: 2).containsColor(TerminalTheme.nsColor(theme.logColorHex(.error))))
        // The token crosses the wrap, not a newline: both halves should highlight.
        view.feed(text: "\r\n12345678 WARNING")
        XCTAssertTrue(rendered(view, row: 3).containsColor(TerminalTheme.nsColor(theme.logColorHex(.warning))))
        XCTAssertTrue(rendered(view, row: 4).containsColor(TerminalTheme.nsColor(theme.logColorHex(.warning))))
    }

    func testRemoteColorsInverseHiddenAndSelectionWin() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 1_000, height: 400))
        var theme = TerminalTheme(preset: .vivid, isDark: false, logHighlightEnabled: false)
        theme.apply(to: view)
        view.feed(text: "\u{1b}[32mERROR\u{1b}[0m \u{1b}[38;2;1;2;3mWARN\u{1b}[0m \u{1b}[7mINFO\u{1b}[0m \u{1b}[8mDEBUG\u{1b}[0m ERROR")
        let original = rendered(view)
        theme.logHighlightEnabled = true
        theme.apply(to: view)
        let highlighted = rendered(view)
        XCTAssertEqual(original.string, highlighted.string)
        for index in 0..<22 {
            XCTAssertEqual(original.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor,
                           highlighted.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)
        }
        view.selection.setSelection(start: Position(col: 22, row: 0), end: Position(col: 27, row: 0))
        let selected = rendered(view)
        let last = (selected.string as NSString).range(of: "ERROR", options: .backwards)
        XCTAssertEqual(selected.attribute(.foregroundColor, at: last.location, effectiveRange: nil) as? NSColor,
                       view.nativeForegroundColor)
        XCTAssertNotNil(selected.attribute(.selectionBackgroundColor, at: last.location, effectiveRange: nil))
    }

    func testSwitchKeepsSurfaceBufferScrollSelectionAndDisablesAlternateScreen() {
        let runtime = TerminalRuntime(profile: SSHProfile(name: "offline", host: "127.0.0.1", username: "test"))
        let view = runtime.terminalSurface()
        view.terminal.resize(cols: 80, rows: 24)
        view.feed(text: "ERROR first\r\nINFO second")
        let buffer = view.terminal.buffer
        let original = view.terminal.getText(start: Position(col: 0, row: 0), end: Position(col: 20, row: 1))
        let scroll = buffer.yDisp
        view.selection.setSelection(start: Position(col: 0, row: 1), end: Position(col: 4, row: 1))
        for dark in [true, false] {
            runtime.applyTheme(TerminalTheme(preset: .vivid, isDark: dark))
            XCTAssertTrue(view === runtime.terminalSurface())
            XCTAssertTrue(buffer === view.terminal.buffer)
            XCTAssertEqual(buffer.yDisp, scroll)
            XCTAssertTrue(view.selection.active)
            XCTAssertEqual(view.terminal.getText(start: Position(col: 0, row: 0), end: Position(col: 20, row: 1)), original)
        }
        view.selection.active = false
        runtime.applyTheme(TerminalTheme(preset: .vivid, isDark: false, logHighlightEnabled: false))
        XCTAssertEqual(rendered(view).attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       view.nativeForegroundColor)
        runtime.applyTheme(TerminalTheme(preset: .vivid, isDark: false))
        XCTAssertNotEqual(rendered(view).attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                          view.nativeForegroundColor)
        view.feed(text: "\u{1b}[?1049hERROR")
        XCTAssertTrue(view.terminal.isCurrentBufferAlternate)
        XCTAssertEqual(rendered(view).attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       view.nativeForegroundColor)
        view.feed(text: "\u{1b}[?1049l")
        XCTAssertNotEqual(rendered(view).attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                          view.nativeForegroundColor)
    }

    func testManyLogRowsRenderWithBoundedMatchingCost() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 1_000, height: 400))
        TerminalTheme(preset: .tokyoNight, isDark: true, fieldHighlightEnabled: true).apply(to: view)
        let start = Date()
        for i in 0..<5_000 { view.feed(text: "[INFO] row \(i) 中文 [ERROR] retry\r\n") }
        for _ in 0..<10 {
            for row in 0..<view.terminal.rows { _ = rendered(view, row: row) }
        }
        let elapsed = Date().timeIntervalSince(start)
        print("Terminal highlight: 5,000 log rows + 10 visible redraws: \(elapsed)s")
        XCTAssertLessThan(elapsed, 15, "Guard against accidentally scanning all scrollback each redraw")
    }

    private func rendered(_ view: TerminalView, row: Int = 0) -> NSAttributedString {
        let buffer = view.terminal.displayBuffer
        let result = NSMutableAttributedString(string: "")
        let info = view.buildAttributedString(row: row + buffer.yDisp, line: buffer.lines[row + buffer.yDisp], cols: buffer.cols)
        for segment in info.segments { result.append(segment.attributedString) }
        return result
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            let values = [16, 8, 0].map { shift -> Double in
                let s = Double((hex >> shift) & 255) / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
        }
        return (max(luminance(a), luminance(b)) + 0.05) / (min(luminance(a), luminance(b)) + 0.05)
    }
}

private extension NSAttributedString {
    func containsColor(_ color: NSColor) -> Bool {
        var found = false
        enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: length)) { value, _, _ in
            if value as? NSColor == color { found = true }
        }
        return found
    }
}
