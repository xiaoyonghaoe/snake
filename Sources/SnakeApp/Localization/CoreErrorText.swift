import Foundation
import SnakeCoreBindings

/// Maps the stable ASCII stage codes reported by the Rust core onto localized text.
///
/// The core keeps `message` as a technical English detail and reports *where*
/// the connection failed as a closed set of codes, so the same message can be
/// rendered in any interface language without parsing translated text.
enum CoreErrorText {
    /// Stage code → simplified Chinese source template.
    ///
    /// A template without `%@` is self contained; otherwise the technical
    /// detail follows the localized stage name.
    static let stageTemplates: [String: String] = [
        "tcp_resolve": "TCP 地址解析失败：%@",
        "tcp_connect": "TCP 连接失败：%@",
        "tcp_stream": "准备 TCP 流失败：%@",
        "ssh_session_init": "初始化 SSH 会话失败：%@",
        "ssh_handshake": "SSH 握手失败：%@",
        "ssh_host_key_missing": "SSH 握手失败：服务器未提供主机密钥",
        "ssh_channel": "创建终端通道失败：%@",
        "ssh_pty": "申请 PTY 失败：%@",
        "ssh_output": "配置终端输出失败：%@",
        "ssh_shell": "启动远程 shell 失败：%@",
        "ssh_net_stream": "配置终端网络流失败：%@",
        "auth_password": "密码认证失败：%@",
        "auth_password_encoding_invalid": "密码认证失败：密码编码无效",
        "auth_private_key": "私钥认证失败：%@",
        "auth_private_key_passphrase_invalid": "私钥认证失败：私钥口令编码无效"
    ]

    /// Localized stage text, falling back to `fallback` plus the raw detail.
    static func text(_ message: String, stage: String?, fallback: String) -> String {
        guard let stage, let template = stageTemplates[stage] else {
            return L10n.format(fallback, message)
        }
        guard template.contains("%@") else { return L10n.text(template) }
        return L10n.format(template, message)
    }
}
