import AppKit
import XCTest
@testable import SnakeApp
@testable import SwiftTerm

final class TerminalShellStartupTests: XCTestCase {
    func testSuppressesEchoAndMarkerAcrossEveryByteBoundary() throws {
        let original = try XCTUnwrap(TerminalShellStartup(shellName: "bash"))
        let report = Data("\u{1b}]7;file://server/root\u{1b}\\".utf8)
        var raw = Data("Last login: test\r\nroot@server:~# ".utf8)
        raw.append(original.command)
        raw.append(report)
        raw.append(original.completionMarker)
        raw.append(Data("root@server:~# ".utf8))
        var filter = original
        var visible = Data()
        for byte in raw { visible.append(filter.consume(Data([byte]))) }
        XCTAssertTrue(filter.isComplete)
        XCTAssertEqual(visible, Data("Last login: test\r\n".utf8) + report + Data("root@server:~# ".utf8))
        XCTAssertFalse(String(decoding: visible, as: UTF8.self).contains("__snake_cwd"))
        let userOutput = Data("user command: __snake_cwd\r\n".utf8)
        XCTAssertEqual(filter.consume(userOutput), userOutput, "Only startup is filtered")
    }

    func testOtherAttemptsCannotCompleteStartupAndTimeoutReturnsOutput() throws {
        var first = try XCTUnwrap(TerminalShellStartup(shellName: "bash"))
        let second = try XCTUnwrap(TerminalShellStartup(shellName: "bash"))
        let pending = Data("login message\r\n".utf8) + second.completionMarker
        XCTAssertTrue(first.consume(pending).isEmpty)
        XCTAssertFalse(first.isComplete)
        XCTAssertEqual(first.finish(), pending)
        XCTAssertTrue(first.isComplete)
        XCTAssertEqual(first.consume(Data("after timeout".utf8)), Data("after timeout".utf8))
        XCTAssertNil(TerminalShellStartup(shellName: "tcsh"))
    }

    func testOversizedOrRedrawnStartupDoesNotBlockAndPreservesOSC7() throws {
        var large = try XCTUnwrap(TerminalShellStartup(shellName: "zsh"))
        let data = Data(repeating: 65, count: TerminalShellStartup.bufferLimit)
        XCTAssertEqual(large.consume(data), data)
        XCTAssertTrue(large.isComplete)

        var redrawn = try XCTUnwrap(TerminalShellStartup(shellName: "fish"))
        let report = Data("\u{1b}]7;file://server/中文 path\u{7}".utf8)
        let raw = Data("\r<redrawn tail of internal setup>\r\n".utf8) + report + redrawn.completionMarker
        XCTAssertEqual(redrawn.consume(raw), report)
    }

    @MainActor
    func testVisibleTerminalRetainsBannerPathAndOnePrompt() throws {
        var startup = try XCTUnwrap(TerminalShellStartup(shellName: "bash"))
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 700, height: 300))
        view.terminal.resize(cols: 30, rows: 12)
        let prompt = "root@iZ2ze0ditjra7kxd4h1v6jZ:~# "
        let raw = Data("Welcome to server\r\n\(prompt)".utf8) + startup.command
            + Data("\u{1b}]7;file://host/root\u{7}".utf8) + startup.completionMarker
            + Data(prompt.utf8)
        let output = [UInt8](startup.consume(raw))
        view.feed(byteArray: output[...])
        let text = view.terminal.getText(start: Position(col: 0, row: 0), end: Position(col: 29, row: 11))
        XCTAssertTrue(text.contains("Welcome to server"))
        XCTAssertEqual(text.components(separatedBy: "root@iZ2ze0").count - 1, 1)
        XCTAssertFalse(text.contains("__snake_cwd"))
        XCTAssertFalse(text.contains("snake-ready="))
    }

    func testRealInteractiveShellsKeepDirectoryUpdatesWithoutShowingSetup() throws {
        // Real local PTYs exercise readline/fish redraws at narrow and wide sizes.
        // No user rc files are loaded and no SSH server or saved credentials are used.
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { throw XCTSkip("Python PTY fixture unavailable") }
        let shells: [(String, String, [String])] = [
            ("bash", "/bin/bash", ["--noprofile", "--norc", "-i"]),
            ("zsh", "/bin/zsh", ["-f", "-i"]),
            ("fish", "/opt/homebrew/bin/fish", ["--no-config", "--interactive"])
        ]
        for (name, path, arguments) in shells where FileManager.default.isExecutableFile(atPath: path) {
            for width in [30, 100] {
                var startup = try XCTUnwrap(TerminalShellStartup(shellName: name))
                let request: [String: Any] = [
                    "shell": path, "args": arguments, "width": width,
                    "command": String(decoding: startup.command, as: UTF8.self),
                    "marker": String(decoding: startup.completionMarker, as: UTF8.self)
                ]
                let process = Process()
                process.executableURL = URL(fileURLWithPath: python)
                process.arguments = ["-c", Self.ptyFixture]
                let input = Pipe(), output = Pipe(), errors = Pipe()
                process.standardInput = input; process.standardOutput = output; process.standardError = errors
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
                try input.fileHandleForWriting.close()
                let raw = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
                var visible = Data()
                for offset in stride(from: 0, to: raw.count, by: 7) {
                    visible.append(startup.consume(raw.subdata(in: offset..<min(offset + 7, raw.count))))
                }
                XCTAssertTrue(startup.isComplete, "\(name) \(width): \(String(decoding: raw, as: UTF8.self))")
                let rendered = String(decoding: visible, as: UTF8.self)
                XCTAssertFalse(rendered.contains("__snake_cwd"), "\(name) \(width)")
                XCTAssertFalse(rendered.contains("snake-ready="), "\(name) \(width)")
                XCTAssertTrue(rendered.contains("]7;file://"), "\(name) \(width)")
                XCTAssertTrue(rendered.contains("/tmp"), "cd still reports its new directory: \(name) \(width)")
                XCTAssertTrue(rendered.contains("SNAKE_USER_OUTPUT"), "User output must remain visible")
            }
        }
    }

    private static let ptyFixture = #"""
import errno, fcntl, json, os, pty, select, signal, struct, sys, termios, time
request = json.load(sys.stdin)
pid, fd = pty.fork()
if pid == 0:
    env = dict(os.environ, TERM="xterm-256color", PS1="snake-test# ", LC_ALL="C")
    os.execve(request["shell"], [request["shell"]] + request["args"], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, request["width"], 0, 0))
collected = bytearray()
def read_until(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if select.select([fd], [], [], 0.05)[0]:
            try:
                block = os.read(fd, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO: break
                raise
            if not block: break
            collected.extend(block)
        if predicate(): return True
    return predicate()
try:
    read_until(lambda: b"# " in collected or b"> " in collected or b"% " in collected, 1)
    os.write(fd, request["command"].encode())
    if not read_until(lambda: request["marker"].encode() in collected, 5):
        raise RuntimeError("shell did not acknowledge initialization")
    os.write(fd, b"cd /tmp\nprintf 'SNAKE_USER_OUTPUT\\n'\n")
    read_until(lambda: b"/tmp" in collected and b"SNAKE_USER_OUTPUT\r\n" in collected, 3)
    read_until(lambda: False, 0.1)
    sys.stdout.buffer.write(collected)
finally:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    os.close(fd)
"""#
}
