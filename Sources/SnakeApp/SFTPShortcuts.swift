import AppKit
import Foundation

enum SFTPShortcutAction: String, CaseIterable, Codable, Sendable {
    case search
    case delete
    case uploadFile

    var title: String {
        switch self {
        case .search: L10n.text("检索")
        case .delete: L10n.text("删除")
        case .uploadFile: L10n.text("上传文件")
        }
    }

    var defaultShortcut: SFTPShortcut {
        switch self {
        case .search: SFTPShortcut(keyEquivalent: "f", modifiers: [.command])
        case .delete: SFTPShortcut(keyEquivalent: "\u{8}", modifiers: [.command])
        case .uploadFile: SFTPShortcut(keyEquivalent: "u", modifiers: [.command])
        }
    }
}

struct SFTPShortcut: Codable, Equatable, Hashable, Sendable {
    let keyEquivalent: String
    let modifierRawValue: UInt

    init(keyEquivalent: String, modifiers: NSEvent.ModifierFlags) {
        self.keyEquivalent = Self.normalized(keyEquivalent)
        modifierRawValue = modifiers.intersection(Self.supportedModifiers).rawValue
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierRawValue) }

    var displayText: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        result += Self.keyLabel(keyEquivalent)
        return result
    }

    static let supportedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    static func from(event: NSEvent) -> SFTPShortcut? {
        let key: String
        switch event.keyCode {
        case 51: key = "\u{8}"
        case 117: key = String(UnicodeScalar(NSDeleteFunctionKey)!)
        case 36, 76: key = "\r"
        case 49: key = " "
        case 123: key = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case 124: key = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case 125: key = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case 126: key = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        default:
            guard let characters = event.charactersIgnoringModifiers, let first = characters.first,
                  !first.isWhitespace, !first.isNewline else { return nil }
            key = String(first)
        }
        return SFTPShortcut(keyEquivalent: key, modifiers: event.modifierFlags)
    }

    private static func normalized(_ key: String) -> String {
        guard key.count == 1 else { return key }
        return key.lowercased()
    }

    private static func keyLabel(_ key: String) -> String {
        switch key {
        case "\u{8}": "⌫"
        case String(UnicodeScalar(NSDeleteFunctionKey)!): "⌦"
        case "\r": "↩"
        case " ": "Space"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): "→"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓"
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑"
        default: key.uppercased()
        }
    }
}

enum SFTPShortcutPolicy {
    static func action(for event: NSEvent, configured: [SFTPShortcutAction: SFTPShortcut]) -> SFTPShortcutAction? {
        guard event.type == .keyDown, let shortcut = SFTPShortcut.from(event: event) else { return nil }
        return SFTPShortcutAction.allCases.first { configured[$0] == shortcut }
    }

    static let reserved: Set<SFTPShortcut> = [
        SFTPShortcut(keyEquivalent: "q", modifiers: [.command]),
        SFTPShortcut(keyEquivalent: "w", modifiers: [.command]),
        SFTPShortcut(keyEquivalent: "n", modifiers: [.command]),
        SFTPShortcut(keyEquivalent: ",", modifiers: [.command]),
        SFTPShortcut(keyEquivalent: "h", modifiers: [.command]),
        SFTPShortcut(keyEquivalent: "m", modifiers: [.command]),
        SFTPShortcut(keyEquivalent: "x", modifiers: [.command]),
        SFTPShortcut(keyEquivalent: "c", modifiers: [.command]),
        SFTPShortcut(keyEquivalent: "v", modifiers: [.command]),
        SFTPShortcut(keyEquivalent: "a", modifiers: [.command]),
        SFTPShortcut(keyEquivalent: "z", modifiers: [.command])
    ]

    static func validationError(
        action: SFTPShortcutAction,
        shortcut: SFTPShortcut,
        configured: [SFTPShortcutAction: SFTPShortcut],
        workspaceShortcut: SFTPShortcut = WorkspaceShortcutPolicy.defaultNewTab
    ) -> String? {
        let safeModifier: NSEvent.ModifierFlags = [.command, .control, .option]
        guard !shortcut.modifiers.intersection(safeModifier).isEmpty else {
            return L10n.text("快捷键必须包含 Command、Control 或 Option。")
        }
        if reserved.contains(shortcut) {
            return L10n.format("%@ 已被 Snake 或 macOS 常用命令占用。", shortcut.displayText)
        }
        if shortcut == workspaceShortcut {
            return L10n.format("%@ 已用于新建 SSH 会话标签。", shortcut.displayText)
        }
        if let conflict = configured.first(where: { $0.key != action && $0.value == shortcut })?.key {
            return L10n.format("%@ 已用于 SFTP %@。", shortcut.displayText, conflict.title)
        }
        return nil
    }
}

enum WorkspaceShortcutPolicy {
    static let defaultNewTab = SFTPShortcut(keyEquivalent: "t", modifiers: [.command])

    static func validationError(
        _ shortcut: SFTPShortcut,
        sftpShortcuts: [SFTPShortcutAction: SFTPShortcut]
    ) -> String? {
        guard !shortcut.modifiers.intersection([.command, .control, .option]).isEmpty else {
            return L10n.text("快捷键必须包含 Command、Control 或 Option。")
        }
        if SFTPShortcutPolicy.reserved.contains(shortcut) {
            return L10n.format("%@ 已被 Snake 或 macOS 常用命令占用。", shortcut.displayText)
        }
        if let conflict = sftpShortcuts.first(where: { $0.value == shortcut })?.key {
            return L10n.format("%@ 已用于 SFTP %@。", shortcut.displayText, conflict.title)
        }
        return nil
    }
}
