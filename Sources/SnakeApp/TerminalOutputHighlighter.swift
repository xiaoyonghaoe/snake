import Darwin
import Foundation

enum TerminalFieldRole: CaseIterable, Sendable {
    case error, warning, success, permission, time, address, path, quantity
}

struct TerminalOutputMatch {
    enum Role { case log(TerminalLogLevel), field(TerminalFieldRole) }
    let range: NSRange
    let role: Role

    func color(in theme: TerminalTheme) -> UInt32 {
        switch role {
        case .log(let level): theme.logColorHex(level)
        case .field(let role): theme.fieldColorHex(role)
        }
    }
}

/// Fixed local display rules, independent of any server command or prompt parser.
final class TerminalOutputHighlighter {
    static let ruleVersion = 2
    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let role: TerminalFieldRole
        let validate: (@Sendable (String) -> Bool)?
        init(_ pattern: String, _ role: TerminalFieldRole, validate: (@Sendable (String) -> Bool)? = nil) {
            regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.role = role
            self.validate = validate
        }
    }

    private static let left = #"(?<![\p{L}\p{M}\p{N}_])"#
    private static let right = #"(?![\p{L}\p{M}\p{N}_])"#
    private static let failures = Rule(left + #"(?:failed|failure|panic|denied)"# + right, .error)
    private static let warnings = Rule(left + #"(?:stopped|inactive|disabled|exited)"# + right, .warning)
    private static let rules: [Rule] = [
        Rule(#"(?<![\p{L}\p{N}_:/])(?:~/|/)[^\s\x00-\x1f<>\"'`|;,()\[\]{}]+"#, .path),
        Rule(left + #"(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?"# + right, .address, validate: validIPv4),
        Rule(#"(?<![\w:])(?:\[[0-9a-f:]+\](?::\d{1,5})?|[0-9a-f]*:[0-9a-f:]+)(?![\w:])"#, .address, validate: validIPv6),
        Rule(left + #"\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?"# + right, .time),
        Rule(left + #"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+(?:\d{2}:\d{2}|\d{4})"# + right, .time),
        Rule(#"(?<!\S)(?:[bcdlps-][rwxstST-]{9})(?:[+@.])?(?!\S)"#, .permission),
        Rule(left + #"\d+(?:\.\d+)?(?:\s?(?:[KMGTPE]i?B|[KMGTPE]|B)|%)(?![\p{L}\p{M}\p{N}_])"#, .quantity),
        Rule(left + #"(?:success|succeeded|ok|passed|running|active|enabled|connected)"# + right, .success)
    ]
    private let logs: Bool
    private let fields: Bool
    private let logMatcher = TerminalLogHighlighter()
    private var cache: [String: [TerminalOutputMatch]] = [:]
    private var keys = [String](repeating: "", count: 512)
    private var nextKey = 0
    private(set) var evaluationCount = 0
    var cachedRowCount: Int { cache.count }

    init(logs: Bool, fields: Bool) { self.logs = logs; self.fields = fields }

    func matches(in text: String) -> [TerminalOutputMatch] {
        guard text.count <= 4_096 else { return [] }
        if let result = cache[text] { return result }
        evaluationCount += 1
        let source = text as NSString
        var result: [TerminalOutputMatch] = []
        func append(_ match: TerminalOutputMatch) {
            guard !result.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else { return }
            result.append(match)
        }
        func apply(_ rule: Rule) {
            for match in rule.regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                guard rule.validate?(source.substring(with: match.range)) ?? true else { continue }
                append(TerminalOutputMatch(range: match.range, role: .field(rule.role)))
            }
        }
        let levels = logs ? logMatcher.matches(in: text) : []
        for match in levels where match.level == .error || match.level == .warning {
            append(TerminalOutputMatch(range: match.range, role: .log(match.level)))
        }
        if fields {
            apply(Self.failures)
            apply(Self.warnings)
            Self.rules.forEach(apply)
        }
        for match in levels where match.level == .info || match.level == .debug {
            append(TerminalOutputMatch(range: match.range, role: .log(match.level)))
        }
        result.sort { $0.range.location < $1.range.location }
        cache.removeValue(forKey: keys[nextKey])
        keys[nextKey] = text
        nextKey = (nextKey + 1) % keys.count
        cache[text] = result
        return result
    }

    private static func validIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.count == 1 || validPort(parts[1]) else { return false }
        var address = in_addr()
        return String(parts[0]).withCString { inet_pton(AF_INET, $0, &address) } == 1
    }

    private static func validIPv6(_ value: String) -> Bool {
        var host = value
        if value.hasPrefix("["), let end = value.firstIndex(of: "]") {
            host = String(value[value.index(after: value.startIndex)..<end])
            let tail = value[value.index(after: end)...]
            if !tail.isEmpty && (!tail.hasPrefix(":") || !validPort(tail.dropFirst())) { return false }
        }
        var address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }

    private static func validPort(_ value: Substring) -> Bool {
        guard let port = Int(value) else { return false }
        return (1...65_535).contains(port)
    }
}
