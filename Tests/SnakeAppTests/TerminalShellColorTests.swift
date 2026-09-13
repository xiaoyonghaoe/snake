import Foundation
import XCTest
@testable import SnakeApp

final class TerminalShellColorTests: XCTestCase {
    private var dockerImage: String? { ProcessInfo.processInfo.environment["SNAKE_SHELL_COLOR_DOCKER_IMAGE"] }
    private var shells: [(String, String)] {
        let list = [("bash", "/bin/bash"), ("zsh", "/bin/zsh"), ("fish", dockerImage == nil ? "/opt/homebrew/bin/fish" : "/usr/bin/fish")]
        return list.filter { dockerImage != nil || FileManager.default.isExecutableFile(atPath: $0.1) }
    }

    func testSetupIsSessionLocalAndUnknownShellIsSkipped() {
        XCTAssertNil(TerminalShellColors.command(for: "tcsh"))
        for (name, _) in shells {
            let command = TerminalShellColors.command(for: name)!
            XCTAssertTrue(command.split(separator: "\n").allSatisfy { $0.utf8.count < 1_024 })
            for forbidden in ["eval ", ".bashrc", ".zshrc", "config.fish", "FORCE_COLOR", "SYSTEMD_", "unset NO_COLOR"] {
                XCTAssertFalse(command.contains(forbidden), forbidden)
            }
        }
    }

    func testNativeShellsProduceColorsAndRespectPipes() throws {
        for (name, path) in shells {
            let result = try run(name, path, setup: "", check: "ll\nls\nprintf 'PIPE_BEGIN\\n'\nls | cat\n")
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("\u{1b}["), "\(name): \(result.output)")
            XCTAssertTrue(result.output.contains("folder"), result.output)
            XCTAssertFalse(result.output.contains("syntax error"), result.output)
            XCTAssertFalse(result.output.contains("Unknown command"), result.output)
            let piped = result.output.components(separatedBy: "PIPE_BEGIN").last ?? ""
            XCTAssertFalse(piped.contains("\u{1b}["), result.output)
        }
    }

    func testFileKindsHaveDistinctColors() throws {
        for (name, path) in shells {
            let result = try run(name, path, setup: "", check: "ls -1d folder link run.sh plain.txt\n")
            let expression = try NSRegularExpression(pattern: #"\x1b\[([0-9;]+)m(?:\x1b\[[0-9;]*m)*(folder|link|run\.sh)"#)
            let source = result.output as NSString
            var colorByFile: [String: String] = [:]
            for match in expression.matches(in: result.output, range: NSRange(location: 0, length: source.length)) {
                colorByFile[source.substring(with: match.range(at: 2))] = source.substring(with: match.range(at: 1))
            }
            XCTAssertEqual(colorByFile.count, 3, "\(name): \(result.output)")
            XCTAssertEqual(Set(colorByFile.values).count, 3, result.output)
            XCTAssertFalse(result.output.contains("\u{1b}[31mplain.txt"), result.output)
        }
    }

    func testSimpleAliasesKeepOptionsAndSetupIsIdempotent() throws {
        for (name, path) in shells {
            let definition = name == "fish" ? "alias ll 'ls -lah'" : "alias ll='ls -lah'"
            let query = name == "fish" ? "functions ll" : "alias ll"
            let result = try run(name, path, setup: definition,
                                 check: TerminalShellColors.command(for: name)! + "\n" + query + "\nll\n")
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("-lah"), result.output)
            XCTAssertTrue(result.output.contains("--color=auto") || result.output.contains("-G"), result.output)
            XCTAssertTrue(result.output.contains("\u{1b}["), result.output)
            XCTAssertFalse(result.output.contains("-G -G"), result.output)
            XCTAssertFalse(result.output.contains("--color=auto --color=auto"), result.output)
        }
    }

    func testComplexFunctionsAndDisabledAliasesArePreserved() throws {
        for (name, path) in shells {
            let definition = name == "fish" ? "function ll; printf COMPLEX; end" : "ll() { printf COMPLEX; }"
            let result = try run(name, path, setup: definition, check: "ll\n")
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("COMPLEX"), result.output)
            XCTAssertTrue(result.output.contains("自定义函数"), result.output)
            let disabled = name == "fish" ? "alias ll 'ls --color=never -l'" : "alias ll='ls --color=never -l'"
            let query = name == "fish" ? "functions ll" : "alias ll"
            let preserved = try run(name, path, setup: disabled, check: query + "\n")
            XCTAssertTrue(preserved.output.contains("--color=never"), preserved.output)
            XCTAssertTrue(preserved.output.contains("保留 ll 原有选项"), preserved.output)
        }
    }

    func testUserColorsAndNoColorAreNotOverwritten() throws {
        for (name, path) in shells {
            let query = "printf 'LSVALUE:%s\\n' \"$LS_COLORS\"\n"
            let existing = try run(name, path, setup: "", check: query, extra: ["LS_COLORS": "di=31:*.rs=35"])
            XCTAssertTrue(existing.output.contains("LSVALUE:di=31:*.rs=35"), existing.output)
            XCTAssertFalse(existing.output.contains("di=34"), existing.output)
            XCTAssertTrue(existing.output.contains("ln=36"), existing.output)
            let disabled = try run(name, path, setup: "", check: query, extra: ["NO_COLOR": "1", "LS_COLORS": "di=31"])
            XCTAssertTrue(disabled.output.contains("NO_COLOR 已设置"), disabled.output)
            XCTAssertTrue(disabled.output.contains("LSVALUE:di=31\r\n"), disabled.output)
            XCTAssertFalse(disabled.output.contains("ln=36"), disabled.output)
        }
    }

    func testBashAndZshDoNotEvaluateAliasContents() throws {
        for (name, path) in shells where name != "fish" {
            let result = try run(name, path, setup: "alias ll='ls $(touch MUST_NOT_EXIST)'",
                                 check: "test ! -e MUST_NOT_EXIST\n")
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("复杂别名"), result.output)
        }
    }

    private func run(_ shell: String, _ executable: String, setup: String, check: String,
                     extra: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snake-shell-colors-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: false)
        FileManager.default.createFile(atPath: root.appendingPathComponent("plain.txt").path, contents: Data("fixture".utf8))
        FileManager.default.createFile(atPath: root.appendingPathComponent("run.sh").path, contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("folder"))
        for file in [".bashrc", ".zshrc", "config.fish"] {
            try "# unchanged".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let prelude: String
        switch shell {
        case "bash": prelude = "shopt -s expand_aliases\n"
        // Load the standard alias helper, but don't autoload the vendor's ls/ll wrappers.
        case "fish": prelude = "alias __snake_fixture_init true\nfunctions -c alias __snake_fixture_alias\nfunctions -e __snake_fixture_init\nset -g fish_function_path\nfunctions -c __snake_fixture_alias alias\nfunctions -e ls ll\n"
        default: prelude = ""
        }
        let script = root.appendingPathComponent("fixture.\(shell)")
        try (prelude + setup + "\n" + TerminalShellColors.command(for: shell)! + check)
            .write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        let flags: [String] = shell == "bash" ? ["--noprofile", "--norc"] : shell == "zsh" ? ["-f"] : ["--no-config"]
        process.arguments = ["-q", "/dev/null", executable] + flags + [script.path]
        process.currentDirectoryURL = root
        process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin:/opt/homebrew/bin", "TERM": "xterm-256color", "LC_ALL": "C"].merging(extra) { _, new in new }
        if let dockerImage {
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
            var environmentArgs: [String] = []
            for (key, value) in extra { environmentArgs += ["--env", "\(key)=\(value)"] }
            process.arguments = ["run", "--rm", "-t", "--network", "none", "--read-only", "--tmpfs", "/tmp",
                                 "--mount", "type=bind,source=\(root.path),target=/fixture,readonly",
                                 "--workdir", "/fixture", "--env", "HOME=/fixture", "--env", "TERM=xterm-256color", "--env", "LC_ALL=C"]
                + environmentArgs + [dockerImage, executable] + flags + ["/fixture/fixture.\(shell)"]
            // Docker reads its existing host configuration; the container only gets
            // explicit test variables above, never host credentials/environment.
            process.environment = ProcessInfo.processInfo.environment
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        for file in [".bashrc", ".zshrc", "config.fish"] {
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8), "# unchanged")
        }
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
