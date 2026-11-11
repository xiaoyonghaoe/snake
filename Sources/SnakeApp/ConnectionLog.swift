import AppKit
import SnakeCoreBindings
import SwiftUI

struct ConnectionLogEntry: Identifiable, Hashable {
    enum Level: Hashable {
        case info
        case success
        case warning
        case error
    }

    let id = UUID()
    let date: Date
    let level: Level
    let message: String
    /// Technical detail such as the core's stage code; never contains secrets.
    let detail: String?
}

/// What happened while a terminal or SFTP tab connected, kept per tab so a
/// failure can be explained after the fact. Credentials are never logged.
@MainActor
final class ConnectionLog: ObservableObject {
    @Published private(set) var entries: [ConnectionLogEntry] = []
    static let limit = 300
    private let now: () -> Date
    private var attemptStartedAt: ContinuousClock.Instant?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func append(_ level: ConnectionLogEntry.Level, _ message: String, detail: String? = nil) {
        entries.append(ConnectionLogEntry(date: now(), level: level, message: message, detail: detail))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// Starts timing one connection attempt and records where it goes.
    func beginAttempt(_ profile: SSHProfile, kind: String) {
        attemptStartedAt = .now
        append(.info, L10n.format("开始 %@ 连接 %@（%@认证）", kind, profile.connectionLabel, profile.authMethod.label))
    }

    /// Seconds since `beginAttempt`, for the success and failure lines.
    var elapsedText: String {
        guard let attemptStartedAt else { return "" }
        let duration = attemptStartedAt.duration(to: .now)
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return L10n.format("用时 %@ 秒", String(format: "%.1f", seconds))
    }

    func recordConnected(_ security: CoreConnectionSecurity?, what: String) {
        var detail: String?
        if let security {
            detail = [
                L10n.format("主机密钥 %@ %@", security.hostKeyAlgorithm, security.hostKeyFingerprint),
                L10n.format("密钥交换 %@", security.keyExchangeAlgorithm),
                L10n.format("加密 %@", security.clientToServerCipher)
            ].joined(separator: " · ")
        }
        append(.success, L10n.format("%@ 已连接，%@", what, elapsedText), detail: detail)
    }

    func recordFailure(_ message: String, error: Error?) {
        append(.error, message, detail: [elapsedText, error.flatMap(Self.technicalDetail)].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: " · "))
    }

    /// Stage codes and the core's English detail, which support uses to tell
    /// a refused TCP port from a rejected password.
    nonisolated static func technicalDetail(_ error: Error) -> String? {
        switch error {
        case let CoreError.Connection(message, stage), let CoreError.Authentication(message, stage):
            let parts = [stage.map { "stage=\($0)" }, message.isEmpty ? nil : message].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case let CoreError.InvalidInput(message):
            return "invalid_input · \(message)"
        case let CoreError.HostKeyUnknown(host, port, algorithm, fingerprint):
            return "host_key_unknown · \(host):\(port) \(algorithm) \(fingerprint)"
        case let CoreError.HostKeyMismatch(host, port, algorithm, fingerprint, _):
            return "host_key_changed · \(host):\(port) \(algorithm) \(fingerprint)"
        default:
            return String(describing: error)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// Plain text for the clipboard, one entry per line.
    var text: String {
        entries.map { entry in
            var line = "\(Self.time(entry.date)) [\(entry.level.tag)] \(entry.message)"
            if let detail = entry.detail, !detail.isEmpty { line += " — \(detail)" }
            return line
        }.joined(separator: "\n")
    }
}

extension ConnectionLogEntry.Level {
    var tag: String {
        switch self {
        case .info: "INFO"
        case .success: "OK"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: SnakeStyle.muted
        case .success: SnakeStyle.secure
        case .warning: .orange
        case .error: .red
        }
    }
}

struct ConnectionLogSheet: View {
    @ObservedObject var log: ConnectionLog
    let title: String
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        SnakeEditorSheet(context: L10n.text("连接日志"), title: title, width: 680, height: 480, onClose: onClose) {
            if log.entries.isEmpty {
                Text("还没有连接记录。")
                    .font(.system(size: 13))
                    .foregroundStyle(SnakeStyle.muted)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(log.entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(ConnectionLog.time(entry.date))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(SnakeStyle.muted)
                            Image(systemName: entry.level.symbol)
                                .font(.system(size: 11))
                                .foregroundStyle(entry.level.color)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.message)
                                    .font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                                if let detail = entry.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(SnakeStyle.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
            }
        } leading: {
            Text("日志只保存在本次打开的标签中，不包含密码或口令。")
                .font(.system(size: 11))
                .foregroundStyle(SnakeStyle.muted)
        } trailing: {
            Button(copied ? L10n.text("已复制") : L10n.text("复制日志")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log.text, forType: .string)
                copied = true
            }
            .buttonStyle(SnakeOutlineButtonStyle())
            .disabled(log.entries.isEmpty)
            Button("关闭", action: onClose).buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
        }
    }
}
