import AppKit
import SwiftUI

/// The shared visual language intentionally mirrors the approved Snake prototype:
/// quiet Sequoia chrome around dense, high-signal work surfaces.
enum SnakeStyle {
    static let chromeFrost = adaptive(light: 0xECEEF2, dark: 0x20242A)
    static let canvas = adaptive(light: 0xF7F8FA, dark: 0x15181D)
    static let raisedSurface = adaptive(light: 0xFFFFFF, dark: 0x252A31)
    static let ink = adaptive(light: 0x1D1D1F, dark: 0xF2F4F7)
    static let muted = adaptive(light: 0x6E7380, dark: 0x9CA5B2)
    static let hairline = adaptive(light: 0xD7DAE0, dark: 0x343A43)
    static let action = Color(red: 0.039, green: 0.518, blue: 1.0)
    static let secure = Color(red: 0.176, green: 0.745, blue: 0.549)
    static let terminal = Color(red: 0.067, green: 0.078, blue: 0.094)
    static let terminalBelt = Color(red: 0.094, green: 0.133, blue: 0.145)
    static let terminalText = Color(red: 0.796, green: 0.824, blue: 0.851)
    static let selectedRow = adaptive(light: 0xD5E4FC, dark: 0x193B61)
    static let dropFill = adaptive(light: 0xEAF2FF, dark: 0x132A43)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return color(match == .darkAqua ? dark : light)
        })
    }

    private static func color(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    static func iconTint(for profile: SSHProfile) -> Color {
        if profile.name.localizedCaseInsensitiveContains("gpu") { return Color(red: 0.79, green: 0.34, blue: 0.58) }
        if profile.name.localizedCaseInsensitiveContains("db") { return Color(red: 0.45, green: 0.33, blue: 0.78) }
        if profile.name.localizedCaseInsensitiveContains("edge") { return Color(red: 0.86, green: 0.49, blue: 0.15) }
        if profile.name.localizedCaseInsensitiveContains("dev") { return Color(red: 0.18, green: 0.65, blue: 0.49) }
        return action
    }

    static func status(for profile: SSHProfile) -> Color {
        if profile.name.localizedCaseInsensitiveContains("gpu") { return .orange }
        if profile.name.localizedCaseInsensitiveContains("test") { return .secondary }
        return secure
    }
}

struct SnakeIconButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? SnakeStyle.action : SnakeStyle.ink)
            .padding(6)
            .background(
                selected ? SnakeStyle.action.opacity(0.14) : (configuration.isPressed ? Color.primary.opacity(0.08) : .clear),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }
}

struct SFTPNavigationButtonStyle: ButtonStyle {
    let isAvailable: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isAvailable ? SnakeStyle.ink : SnakeStyle.muted.opacity(0.62))
            .frame(width: 32, height: 30)
            .contentShape(Rectangle())
            .background(
                configuration.isPressed ? Color.primary.opacity(0.09) : Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(SnakeStyle.hairline.opacity(isAvailable ? 0.72 : 0.42), lineWidth: 1)
            }
    }
}

struct SnakeOutlineButtonStyle: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(emphasized ? Color.white : SnakeStyle.ink)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(emphasized ? SnakeStyle.action.opacity(configuration.isPressed ? 0.78 : 1) : SnakeStyle.raisedSurface.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                if !emphasized {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(SnakeStyle.hairline, lineWidth: 1)
                }
            }
    }
}
