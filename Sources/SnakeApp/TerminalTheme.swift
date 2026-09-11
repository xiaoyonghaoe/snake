import AppKit
import SwiftTerm

enum TerminalTheme: Equatable {
    case light
    case dark

    var backgroundHex: UInt32 {
        switch self {
        case .light: 0xFFFFFF
        case .dark: 0x111418
        }
    }

    var foregroundHex: UInt32 {
        switch self {
        case .light: 0x1F2328
        case .dark: 0xCBD2D9
        }
    }

    var cursorHex: UInt32 { 0x0A84FF }

    var cursorTextHex: UInt32 {
        switch self {
        case .light: 0xFFFFFF
        case .dark: 0x07111C
        }
    }

    var selectionHex: UInt32 {
        switch self {
        case .light: 0xCFE4FF
        case .dark: 0x244B76
        }
    }

    var ansiHex: [UInt32] {
        switch self {
        case .light:
            [
                0x24292F, 0xCF222E, 0x116329, 0x9A6700,
                0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
                0x57606A, 0xA40E26, 0x1A7F37, 0xBF8700,
                0x218BFF, 0xA475F9, 0x3192AA, 0x1F2328
            ]
        case .dark:
            [
                0x2B3138, 0xFF5C57, 0x5AF78E, 0xF3F99D,
                0x57C7FF, 0xFF6AC1, 0x9AEDFE, 0xCBD2D9,
                0x59636E, 0xFF7B72, 0x7EE787, 0xE3B341,
                0x79C0FF, 0xD2A8FF, 0xA5D6FF, 0xF0F3F6
            ]
        }
    }

    @MainActor
    func apply(to view: TerminalView) {
        view.nativeBackgroundColor = Self.nsColor(backgroundHex)
        view.nativeForegroundColor = Self.nsColor(foregroundHex)
        view.installColors(ansiHex.map(Self.swiftTermColor))
        view.caretColor = Self.nsColor(cursorHex)
        view.caretTextColor = Self.nsColor(cursorTextHex)
        view.selectedTextBackgroundColor = Self.nsColor(selectionHex)
        view.needsDisplay = true
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
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
