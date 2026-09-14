import Foundation

/// A user-selectable interface language.
///
/// The raw value of a concrete case doubles as the `.lproj` name inside the
/// application bundle. ``system`` means "follow the macOS preferred language
/// list"; anything the app does not ship falls back to simplified Chinese,
/// which is also the source language of every localization key.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }

    /// `.lproj` names shipped in `Resources/Localization`, in preference order.
    public static let supportedIdentifiers = ["zh-Hans", "en"]

    /// Source language, also the fallback for unsupported system languages.
    public static let fallbackIdentifier = "zh-Hans"

    /// Language names stay in their own script so they remain readable no
    /// matter which language is currently active.
    public var displayName: String {
        switch self {
        case .system: L10n.text("跟随系统")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    /// The concrete `.lproj` identifier this selection resolves to.
    public var resolvedIdentifier: String {
        LocalizationStore.resolvedIdentifier(for: self, preferredLocalizations: Bundle.main.preferredLocalizations)
    }

    /// The locale SwiftUI should use for string lookup and number/date formatting.
    public var locale: Locale { Locale(identifier: resolvedIdentifier) }
}
