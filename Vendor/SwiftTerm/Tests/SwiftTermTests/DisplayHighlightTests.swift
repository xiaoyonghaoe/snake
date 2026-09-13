#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

@MainActor
final class DisplayHighlightTests: XCTestCase {
    func testOptionalProviderOnlyChangesDrawingAndMarksExistingRowsDirty() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        view.feed(text: "ERROR plain")
        let original = rendered(view)
        let buffer = view.terminal.buffer
        let raw = view.terminal.getText(start: Position(col: 0, row: 0), end: Position(col: 11, row: 0))
        view.terminal.clearUpdateRange()
        view.displayHighlights = { _ in [TerminalDisplayHighlight(range: NSRange(location: 0, length: 5), color: .red)] }
        XCTAssertNotNil(view.terminal.getUpdateRange())
        XCTAssertEqual(rendered(view).attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .red)
        XCTAssertEqual(view.terminal.getText(start: Position(col: 0, row: 0), end: Position(col: 11, row: 0)), raw)
        XCTAssertTrue(buffer === view.terminal.buffer)
        view.displayHighlights = nil
        XCTAssertEqual(rendered(view), original)
    }

    func testUTF16WideAndCombiningCellsAndInvalidRanges() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        view.feed(text: "中文😀e\u{301} ERROR")
        view.displayHighlights = { text in
            [TerminalDisplayHighlight(range: (text as NSString).range(of: "ERROR"), color: .red),
             TerminalDisplayHighlight(range: NSRange(location: NSNotFound, length: 1), color: .blue),
             TerminalDisplayHighlight(range: NSRange(location: 0, length: Int.max), color: .blue)]
        }
        let output = rendered(view)
        let range = (output.string as NSString).range(of: "ERROR")
        XCTAssertEqual(output.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor, .red)
        XCTAssertNotEqual(output.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .red)
    }

    func testAlternateBufferNeverCallsProvider() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        var calls = 0
        view.displayHighlights = { _ in calls += 1; return [] }
        view.feed(text: "\u{1b}[?1049hERROR")
        _ = rendered(view)
        XCTAssertEqual(calls, 0)
        view.feed(text: "\u{1b}[?1049lINFO")
        _ = rendered(view)
        XCTAssertEqual(calls, 1)
    }

    private func rendered(_ view: TerminalView) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let buffer = view.terminal.displayBuffer
        let info = view.buildAttributedString(row: buffer.yDisp, line: buffer.lines[buffer.yDisp], cols: buffer.cols)
        for segment in info.segments { result.append(segment.attributedString) }
        return result
    }
}
#endif
