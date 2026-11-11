import XCTest
@testable import SnakeApp
@testable import SwiftTerm

/// After a dropped connection the notice and the next login must continue below the
/// existing output instead of jumping back to the top of the screen.
final class TerminalReconnectTests: XCTestCase {
    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private let sink = Sink()

    private func terminal() -> Terminal {
        let terminal = Terminal(delegate: sink, options: TerminalOptions(cols: 80, rows: 100))
        for line in 1...50 { terminal.feed(text: "line \(line)\r\n") }
        return terminal
    }

    private func text(_ terminal: Terminal, row: Int) -> String {
        terminal.getLine(row: row)?.translateToString(trimRight: true) ?? ""
    }

    func testDisconnectNoticeContinuesBelowExistingOutput() {
        let terminal = terminal()
        terminal.feed(text: TerminalRuntime.terminalModeReset(leavingAlternateScreen: terminal.isCurrentBufferAlternate))
        terminal.feed(text: "\r\n-- disconnected --\r\n")

        XCTAssertEqual(text(terminal, row: 0), "line 1", "the first line must not be overwritten")
        XCTAssertEqual(text(terminal, row: 49), "line 50")
        XCTAssertEqual(text(terminal, row: 51), "-- disconnected --")
        XCTAssertEqual(terminal.getCursorLocation().y, 52)
    }

    /// A full-screen program such as vim still hands the screen back where it was.
    func testDisconnectInsideFullScreenProgramRestoresTheMainScreen() {
        let terminal = terminal()
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[Hvim screen")
        XCTAssertTrue(terminal.isCurrentBufferAlternate)

        terminal.feed(text: TerminalRuntime.terminalModeReset(leavingAlternateScreen: terminal.isCurrentBufferAlternate))
        XCTAssertFalse(terminal.isCurrentBufferAlternate)
        XCTAssertEqual(terminal.getCursorLocation().y, 50)
        XCTAssertEqual(text(terminal, row: 0), "line 1")
    }
}
