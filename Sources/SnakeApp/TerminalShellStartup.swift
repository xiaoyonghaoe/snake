import Foundation

/// The one internal command sent after opening a login shell. Its echo is held
/// until the remote shell acknowledges it; ordinary terminal output is not filtered.
struct TerminalShellStartup {
    let command: Data
    let completionMarker: Data
    /// The hook's function name. Matching only this word still finds the echo when
    /// zsh syntax highlighting colors the `function` keyword in front of it.
    private let echoToken = Data("__snake_cwd".utf8)
    private var buffered = Data()
    private var releasedCount = 0
    private(set) var isComplete = false
    static let bufferLimit = 64 * 1_024

    init?(shellName: String, identifier: UUID = UUID()) {
        guard let hook = TerminalShellIntegration.hookCommand(for: shellName) else { return nil }
        let marker = "777;snake-ready=\(identifier.uuidString)"
        command = Data((hook.trimmingCharacters(in: .newlines)
            + "; printf '\\033]\(marker)\\007'\n").utf8)
        completionMarker = Data("\u{1b}]\(marker)\u{7}".utf8)
    }

    mutating func consume(_ data: Data) -> Data {
        guard !isComplete else { return data }
        buffered.append(data)
        if let ready = buffered.range(of: completionMarker) {
            let setup = Data(buffered[..<ready.lowerBound])
            let echo = setup.range(of: echoToken)
            // The initial prompt has not been rendered yet. Keep complete login
            // banner lines, then let the next prompt appear once, even when a
            // long hostname would have wrapped across several terminal rows.
            var output = Data(Self.banner(in: setup, echo: echo).dropFirst(releasedCount))
            output.append(Self.directoryReports(in: echo.map { Data(setup[$0.lowerBound...]) } ?? setup))
            output.append(buffered[ready.upperBound...])
            buffered.removeAll()
            isComplete = true
            return output
        }
        // A missing acknowledgement must never keep the terminal blocked.
        if buffered.count >= Self.bufferLimit { return finish() }
        return Data()
    }

    /// Called when a slow login shell has not acknowledged the hook yet. Shows the
    /// banner received so far but keeps hiding the echoed hook until the shell
    /// runs it. Without any echo the shell is not cooperating, so stop filtering.
    mutating func releaseBanner() -> Data {
        guard !isComplete else { return Data() }
        guard let echo = buffered.range(of: echoToken) else { return finish() }
        let banner = Self.banner(in: buffered, echo: echo)
        let output = Data(banner.dropFirst(releasedCount))
        releasedCount = banner.count
        return output
    }

    mutating func finish() -> Data {
        let output = Data(buffered.dropFirst(releasedCount))
        buffered.removeAll()
        releasedCount = 0
        isComplete = true
        return output
    }

    private static func banner(in setup: Data, echo: Range<Data.Index>?) -> Data {
        guard let echo else { return Data() }
        return setup[..<echo.lowerBound].lastIndex(of: 10).map { Data(setup[...$0]) } ?? Data()
    }

    private static func directoryReports(in data: Data) -> Data {
        let prefix = Data("\u{1b}]7;".utf8)
        let bell = Data([7])
        let terminator = Data([27, 92])
        var offset = data.startIndex
        var result = Data()
        while offset < data.endIndex,
              let start = data.range(of: prefix, in: offset..<data.endIndex) {
            let remaining = start.upperBound..<data.endIndex
            let end = [data.range(of: bell, in: remaining), data.range(of: terminator, in: remaining)]
                .compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
            guard let end else { break }
            result.append(data[start.lowerBound..<end.upperBound])
            offset = end.upperBound
        }
        return result
    }
}
