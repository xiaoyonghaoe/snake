import Foundation

/// The one internal command sent after opening a login shell. Its echo is held
/// until the remote shell acknowledges it; ordinary terminal output is not filtered.
struct TerminalShellStartup {
    let command: Data
    let completionMarker: Data
    private let echoPrefix: Data
    private var buffered = Data()
    private(set) var isComplete = false
    static let bufferLimit = 64 * 1_024

    init?(shellName: String, identifier: UUID = UUID()) {
        guard let hook = TerminalShellIntegration.hookCommand(for: shellName) else { return nil }
        let marker = "777;snake-ready=\(identifier.uuidString)"
        command = Data((hook.trimmingCharacters(in: .newlines)
            + "; printf '\\033]\(marker)\\007'\n").utf8)
        completionMarker = Data("\u{1b}]\(marker)\u{7}".utf8)
        let prefix = shellName.lowercased() == "bash" ? " __snake_cwd" : " function __snake_cwd"
        echoPrefix = Data(prefix.utf8)
    }

    mutating func consume(_ data: Data) -> Data {
        guard !isComplete else { return data }
        buffered.append(data)
        if let ready = buffered.range(of: completionMarker) {
            let setup = Data(buffered[..<ready.lowerBound])
            let echo = setup.range(of: echoPrefix)
            let beforeEcho = echo.map { Data(setup[..<$0.lowerBound]) } ?? Data()
            // The initial prompt has not been rendered yet. Keep complete login
            // banner lines, then let the next prompt appear once, even when a
            // long hostname would have wrapped across several terminal rows.
            var output = beforeEcho.lastIndex(of: 10).map { Data(beforeEcho[...$0]) } ?? Data()
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

    mutating func finish() -> Data {
        let output = buffered
        buffered.removeAll()
        isComplete = true
        return output
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
