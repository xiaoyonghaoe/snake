import Foundation

/// The single entry point for text that SwiftUI cannot localize on its own.
///
/// Use ``text(_:)`` when the simplified Chinese source string is used verbatim
/// — for `String` parameters (`NSAlert.messageText`, `NSMenuItem.title`,
/// computed `String` properties) and for expressions such as ternaries that
/// would otherwise resolve to `Text(verbatim:)`.
///
/// Use ``format(_:_:)`` when the source string interpolates values. Convert
/// `\(value)` into `%@` so the key matches the table.
///
/// Plain, interpolation-free literals passed straight to `Text`, `Button`,
/// `Label`, `Section`, `.help`, `.accessibilityLabel` and friends are resolved
/// by SwiftUI against the same tables and need no wrapper.
public enum L10n {
    public static func text(_ key: String) -> String {
        LocalizationStore.shared.string(key)
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        LocalizationStore.shared.format(key, arguments)
    }

    /// Count-aware lookup.
    ///
    /// Use when the English sentence needs a singular and a plural form.
    /// `count` selects the form; `arguments` are substituted into the chosen
    /// format. The table keeps the singular under the key and the plural under
    /// `<key>#plural` (see ``LocalizationStore/pluralKeySuffix``).
    public static func plural(_ key: String, count: Int, _ arguments: CVarArg...) -> String {
        LocalizationStore.shared.plural(key, count: count, arguments)
    }

    /// Localized byte count (for example `1.2 MB`).
    public static func byteCount(_ bytes: Int64) -> String {
        LocalizationStore.shared.byteCount(bytes)
    }
}
