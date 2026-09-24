import AppKit
import SwiftTerm

enum TerminalThemePreset: String, CaseIterable {
    case classic, vivid, tokyoNight, catppuccin, gruvbox, solarized

    var title: String {
        switch self {
        case .classic: L10n.text("经典")
        case .vivid: L10n.text("鲜明")
        case .tokyoNight: "Tokyo Night"
        case .catppuccin: "Catppuccin Latte / Mocha"
        case .gruvbox: "Gruvbox Light / Dark"
        case .solarized: "Solarized Light / Dark"
        }
    }
}

struct TerminalTheme: Equatable {
    let preset: TerminalThemePreset
    let isDark: Bool
    var logHighlightEnabled = true
    var fieldHighlightEnabled = false
    var importedPalette: TerminalPalette? = nil

    private var builtinPalette: TerminalPalette? {
        switch preset {
        case .catppuccin:
            return isDark
                ? TerminalPalette(foreground: 0xCDD6F4, background: 0x1E1E2E, cursor: 0xF5E0DC, cursorText: 0x1E1E2E, selection: 0x585B70,
                                  ansi: [0x45475A,0xF38BA8,0xA6E3A1,0xF9E2AF,0x89B4FA,0xF5C2E7,0x94E2D5,0xA6ADC8,0x585B70,0xF37799,0x89D88B,0xEBD391,0x74A8FC,0xF2AEDE,0x6BD7CA,0xBAC2DE])
                : TerminalPalette(foreground: 0x4C4F69, background: 0xFFFFFF, cursor: 0xDC8A78, cursorText: 0xFFFFFF, selection: 0xACB0BE,
                                  ansi: [0x5C5F77,0xD20F39,0x40A02B,0xDF8E1D,0x1E66F5,0xEA76CB,0x179299,0xACB0BE,0x6C6F85,0xDE293E,0x49AF3D,0xEEA02D,0x456EFF,0xFE85D8,0x2D9FA8,0xBCC0CC])
        case .gruvbox:
            return isDark
                ? TerminalPalette(foreground: 0xE6D4A3, background: 0x1E1E1E, cursor: 0xE6D4A3, cursorText: 0x1E1E1E, selection: 0x7F7061,
                                  ansi: [0x1E1E1E,0xBE0F17,0x868715,0xCC881A,0x377375,0xA04B73,0x578E57,0x978771,0x7F7061,0xF73028,0xAAB01E,0xF7B125,0x719586,0xC77089,0x7DB669,0xE6D4A3])
                : TerminalPalette(foreground: 0x2E2A29, background: 0xFFFFFF, cursor: 0x2E2A29, cursorText: 0xFFFFFF, selection: 0xE5D5A0,
                                  ansi: [0xFAEFBB,0xBE0F17,0x868715,0xCC881A,0x377375,0xA04B73,0x578E57,0x685C51,0x7F7061,0x890009,0x66620D,0xA56311,0x0E5365,0x7B2B5E,0x356A46,0x2E2A29])
        case .solarized:
            let ansi: [UInt32] = [0x002831,0xD11C24,0x738A05,0xA57706,0x2176C7,0xC61C6F,0x259286,0xEAE3CB,0x001E27,0xBD3613,0x475B62,0x536870,0x708284,0x5956BA,0x819090,0xFCF4DC]
            return isDark
                ? TerminalPalette(foreground: 0x839496, background: 0x001E27, cursor: 0x839496, cursorText: 0x002831, selection: 0x475B62, ansi: ansi)
                : TerminalPalette(foreground: 0x536870, background: 0xFFFFFF, cursor: 0x536870, cursorText: 0xFFFFFF, selection: 0xEAE3CB, ansi: ansi)
        default: return nil
        }
    }

    private var palette: TerminalPalette? { importedPalette ?? builtinPalette }

    // Keep the original palettes available to existing callers.
    static let light = TerminalTheme(preset: .classic, isDark: false)
    static let dark = TerminalTheme(preset: .classic, isDark: true)

    var backgroundHex: UInt32 {
        if let palette { return palette.background }
        if preset == .tokyoNight { return isDark ? 0x1A1B26 : 0xFFFFFF }
        return isDark ? (preset == .vivid ? 0x0F151E : 0x111418) : 0xFFFFFF
    }

    var foregroundHex: UInt32 {
        if let palette { return palette.foreground }
        if preset == .tokyoNight { return isDark ? 0xC0CAF5 : 0x3760BF }
        return isDark ? (preset == .vivid ? 0xD8E2EF : 0xCBD2D9) : 0x1F2328
    }

    var cursorHex: UInt32 {
        if let palette { return palette.cursor }
        return preset == .tokyoNight ? foregroundHex : (preset == .vivid && isDark ? 0x64B5FF : 0x0A84FF)
    }

    var cursorTextHex: UInt32 {
        if let palette { return palette.cursorText }
        return preset == .tokyoNight ? backgroundHex : (isDark ? 0x07111C : 0xFFFFFF)
    }

    var selectionHex: UInt32 {
        if let palette { return palette.selection }
        return preset == .tokyoNight ? (isDark ? 0x283457 : 0xB7C1E3) : (isDark ? 0x244B76 : 0xCFE4FF)
    }

    var ansiHex: [UInt32] {
        if let palette { return palette.ansi }
        // Folke Lemaitre's Tokyo Night, pinned provenance and license: Vendor/TokyoNight.
        if preset == .tokyoNight {
            return isDark ? [
                0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68,
                0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                0x414868, 0xFF899D, 0x9FE044, 0xFABA4A,
                0x8DB0FF, 0xC7A9FF, 0xA4DAFF, 0xC0CAF5
            ] : [
                0xB4B5B9, 0xF52A65, 0x587539, 0x8C6C3E,
                0x2E7DE9, 0x9854F1, 0x007197, 0x6172B0,
                0xA1A6C5, 0xFF4774, 0x5C8524, 0xA27629,
                0x358AFF, 0xA463FF, 0x007EA8, 0x3760BF
            ]
        }
        if preset == .vivid {
            return isDark ? [
                0x263445, 0xFF7385, 0x68D99F, 0xE9C46A,
                0x64B5FF, 0xBF9BFF, 0x4DD5DE, 0xD8E2EF,
                0x718399, 0xFFA0AA, 0x99E8B8, 0xF6DA8B,
                0x9DCEFF, 0xD8BDFF, 0x8EE9ED, 0xF5F8FC
            ] : [
                0x242D38, 0xC12A36, 0x167044, 0x856000,
                0x005FCC, 0x753EC8, 0x007E8A, 0x616D7A,
                0x526170, 0xB51F4C, 0x137657, 0x946000,
                0x1559B7, 0x8D32AC, 0x006E79, 0x1F2328
            ]
        }
        if !isDark {
            return [
                0x24292F, 0xCF222E, 0x116329, 0x9A6700,
                0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
                0x57606A, 0xA40E26, 0x1A7F37, 0xBF8700,
                0x218BFF, 0xA475F9, 0x3192AA, 0x1F2328
            ]
        } else {
            return [
                0x2B3138, 0xFF5C57, 0x5AF78E, 0xF3F99D,
                0x57C7FF, 0xFF6AC1, 0x9AEDFE, 0xCBD2D9,
                0x59636E, 0xFF7B72, 0x7EE787, 0xE3B341,
                0x79C0FF, 0xD2A8FF, 0xA5D6FF, 0xF0F3F6
            ]
        }
    }

    func logColorHex(_ level: TerminalLogLevel) -> UInt32 {
        if preset == .tokyoNight && importedPalette == nil {
            let value: UInt32 = switch level {
            case .error: ansiHex[1]
            case .warning: isDark ? 0xFF9E64 : 0xB15C00
            case .info: ansiHex[4]
            case .debug: ansiHex[5]
            }
            return readableAccent(value)
        }
        let value: UInt32 = switch level {
        case .error: ansiHex[1]
        case .warning: isDark ? 0xFFB86B : 0xA64B00
        case .info: ansiHex[4]
        case .debug: isDark ? 0xBF9BFF : 0x753EC8
        }
        return readableAccent(value)
    }

    func fieldColorHex(_ role: TerminalFieldRole) -> UInt32 {
        let value: UInt32 = switch role {
        case .error: logColorHex(.error)
        case .warning, .quantity: logColorHex(.warning)
        case .success: ansiHex[2]
        case .address: ansiHex[4]
        case .permission, .path: ansiHex[6]
        case .time: isDark ? 0xA9B1D6 : 0x6172B0
        }
        return readableAccent(value)
    }

    // Only local decorations are adjusted. Explicit remote ANSI values stay exact.
    private func readableAccent(_ hex: UInt32) -> UInt32 {
        func luminance(_ color: UInt32) -> Double {
            let c = [16, 8, 0].map { shift -> Double in
                let s = Double((color >> shift) & 255) / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722
        }
        let background = luminance(backgroundHex)
        var result = hex
        for step in 0...20 {
            let foreground = luminance(result)
            if (max(background, foreground) + 0.05) / (min(background, foreground) + 0.05) >= 4.5 { return result }
            let fraction = Double(step + 1) / 20
            result = [16, 8, 0].reduce(UInt32(0)) { value, shift in
                let channel = Double((hex >> shift) & 255)
                let mixed = min(255, max(0, channel + ((isDark ? 255 : 0) - channel) * fraction))
                return value | (UInt32(mixed.rounded()) << shift)
            }
        }
        return result
    }

    @MainActor
    func apply(to view: TerminalView) {
        view.nativeBackgroundColor = Self.nsColor(backgroundHex)
        view.nativeForegroundColor = Self.nsColor(foregroundHex)
        view.installColors(ansiHex.map(Self.swiftTermColor))
        view.caretColor = Self.nsColor(cursorHex)
        view.caretTextColor = Self.nsColor(cursorTextHex)
        view.selectedTextBackgroundColor = Self.nsColor(selectionHex)
        if logHighlightEnabled || fieldHighlightEnabled {
            let matcher = TerminalOutputHighlighter(logs: logHighlightEnabled, fields: fieldHighlightEnabled)
            view.displayHighlights = { text in
                matcher.matches(in: text).map {
                    TerminalDisplayHighlight(range: $0.range, color: Self.nsColor($0.color(in: self)))
                }
            }
        } else {
            view.displayHighlights = nil
        }
        view.needsDisplay = true
    }

    static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func swiftTermColor(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16((hex >> 16) & 0xFF) * 257,
            green: UInt16((hex >> 8) & 0xFF) * 257,
            blue: UInt16(hex & 0xFF) * 257
        )
    }
}
