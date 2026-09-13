import Foundation

enum TerminalLogLevel: Equatable {
    case error, warning, info, debug
}

struct TerminalLogMatch: Equatable {
    let range: NSRange
    let level: TerminalLogLevel
}

/// Draw-time matching only. A new instance is installed for every theme/rule change.
/// Cache keys include the complete rendered row, so streaming output and resize cannot
/// reuse stale offsets. The bounded FIFO cache never retains terminal scrollback.
final class TerminalLogHighlighter {
    static let ruleVersion = 1
    private let expression = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{M}\p{N}_])(ERROR|FATAL|WARNING|WARN|INFO|DEBUG|TRACE)(?![\p{L}\p{M}\p{N}_])"#,
        options: [.caseInsensitive]
    )
    private var cache: [String: [TerminalLogMatch]] = [:]
    private var keys = [String](repeating: "", count: 512)
    private var nextKey = 0
    private(set) var evaluationCount = 0
    var cachedRowCount: Int { cache.count }

    func matches(in text: String) -> [TerminalLogMatch] {
        if let cached = cache[text] { return cached }
        evaluationCount += 1
        let source = text as NSString
        let result = expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            let level: TerminalLogLevel
            switch source.substring(with: match.range).uppercased() {
            case "ERROR", "FATAL": level = .error
            case "WARN", "WARNING": level = .warning
            case "INFO": level = .info
            default: level = .debug
            }
            return TerminalLogMatch(range: match.range, level: level)
        }
        cache.removeValue(forKey: keys[nextKey])
        keys[nextKey] = text
        nextKey = (nextKey + 1) % keys.count
        cache[text] = result
        return result
    }
}
