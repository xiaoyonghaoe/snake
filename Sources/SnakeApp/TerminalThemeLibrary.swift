import AppKit
import Foundation

struct TerminalPalette: Codable, Equatable {
    let foreground: UInt32
    let background: UInt32
    let cursor: UInt32
    let cursorText: UInt32
    let selection: UInt32
    let ansi: [UInt32]

    init(foreground: UInt32, background: UInt32, cursor: UInt32, cursorText: UInt32,
         selection: UInt32, ansi: [UInt32]) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.cursorText = cursorText
        self.selection = selection
        self.ansi = ansi
    }
}

struct ImportedTerminalTheme: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let regular: TerminalPalette?
    let light: TerminalPalette?
    let dark: TerminalPalette?

    var selectionID: String { "imported:\(id.uuidString)" }

    func palette(isDark: Bool) -> TerminalPalette {
        if isDark { return dark ?? regular ?? light! }
        return light ?? regular ?? dark!
    }
}

enum TerminalThemeImportError: LocalizedError {
    case oversized, invalidPlist, missingPalette, invalidColor(String)

    var errorDescription: String? {
        switch self {
        case .oversized: L10n.text("主题文件超过 1 MB 限制。")
        case .invalidPlist: L10n.text("不是有效的 .itermcolors 属性列表。")
        case .missingPalette: L10n.text("缺少前景、背景或完整的 ANSI 16 色。")
        case .invalidColor(let key): L10n.format("颜色“%@”的 RGB 值无效。", key)
        }
    }
}

enum ITermColorsParser {
    static func parse(_ data: Data, name: String, id: UUID = UUID()) throws -> ImportedTerminalTheme {
        guard data.count <= 1_048_576 else { throw TerminalThemeImportError.oversized }
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw TerminalThemeImportError.invalidPlist }
        let regular = try palette(root, suffix: "")
        let light = try palette(root, suffix: " Light")
            ?? palette(root, suffix: " (Light)")
            ?? ((root["Light"] as? [String: Any]).flatMap { try palette($0, suffix: "") })
        let dark = try palette(root, suffix: " Dark")
            ?? palette(root, suffix: " (Dark)")
            ?? ((root["Dark"] as? [String: Any]).flatMap { try palette($0, suffix: "") })
        guard regular != nil || light != nil || dark != nil else { throw TerminalThemeImportError.missingPalette }
        return ImportedTerminalTheme(id: id, name: name, regular: regular, light: light, dark: dark)
    }

    private static func palette(_ root: [String: Any], suffix: String) throws -> TerminalPalette? {
        let suffixKeys = root.keys.filter { $0.hasSuffix(" Color\(suffix)") }
        guard !suffixKeys.isEmpty else { return nil }
        func required(_ key: String) throws -> UInt32 {
            guard let value = root["\(key) Color\(suffix)"] else { throw TerminalThemeImportError.missingPalette }
            return try color(value, key: key)
        }
        func optional(_ key: String, fallback: UInt32) throws -> UInt32 {
            guard let value = root["\(key) Color\(suffix)"] else { return fallback }
            return try color(value, key: key)
        }
        let fg = try required("Foreground")
        let bg = try required("Background")
        let ansi = try (0..<16).map { try required("Ansi \($0)") }
        let cursor = try optional("Cursor", fallback: fg)
        let cursorText = try optional("Cursor Text", fallback: bg)
        let selection = try optional("Selection", fallback: bg == 0xFFFFFF ? 0xCFE4FF : 0x283457)
        return TerminalPalette(foreground: fg, background: bg, cursor: cursor,
                               cursorText: cursorText, selection: selection, ansi: ansi)
    }

    private static func color(_ value: Any, key: String) throws -> UInt32 {
        guard let components = value as? [String: Any] else { throw TerminalThemeImportError.invalidColor(key) }
        var hex: UInt32 = 0
        for component in ["Red Component", "Green Component", "Blue Component"] {
            guard let number = components[component] as? NSNumber else { throw TerminalThemeImportError.invalidColor(key) }
            let v = number.doubleValue
            guard v.isFinite && (0...1).contains(v) else { throw TerminalThemeImportError.invalidColor(key) }
            hex = (hex << 8) | UInt32((v * 255).rounded())
        }
        return hex
    }
}

struct TerminalThemeLibrary {
    let directoryURL: URL

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snake/TerminalThemes", isDirectory: true)
    }

    func load() -> [ImportedTerminalTheme] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let theme = try? JSONDecoder().decode(ImportedTerminalTheme.self, from: data),
                  theme.id.uuidString == url.deletingPathExtension().lastPathComponent,
                  theme.regular != nil || theme.light != nil || theme.dark != nil,
                  [theme.regular, theme.light, theme.dark].compactMap({ $0 }).allSatisfy({ palette in
                      palette.ansi.count == 16 &&
                      ([palette.foreground, palette.background, palette.cursor,
                        palette.cursorText, palette.selection] + palette.ansi).allSatisfy { $0 <= 0xFFFFFF }
                  }) else { return nil }
            return theme
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func add(data: Data, name: String) throws -> ImportedTerminalTheme {
        let theme = try ITermColorsParser.parse(data, name: name)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directoryURL.appendingPathComponent("\(theme.id.uuidString).json")
        try JSONEncoder().encode(theme).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return theme
    }

    func remove(_ theme: ImportedTerminalTheme) throws {
        try FileManager.default.removeItem(at: directoryURL.appendingPathComponent("\(theme.id.uuidString).json"))
    }
}
