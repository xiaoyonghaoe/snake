import Foundation

/// Resolves user-visible text against the `.lproj` bundle of the selected language.
///
/// Lookups always pass `value: key`. The simplified Chinese source text is also
/// the localization key, so a missing table (`swift run`, `swift test`) or a
/// missing entry degrades to the source language instead of exposing an
/// internal key to the user.
///
/// The store is intentionally non-isolated and thread safe: `LocalizedError`
/// descriptions and `nonisolated` helpers look text up off the main actor.
public final class LocalizationStore: @unchecked Sendable {
    public static let shared = LocalizationStore()

    private let lock = NSLock()
    private var storedLanguage: AppLanguage = .system
    private var cachedIdentifier: String?
    private var cachedBundle: Bundle?

    init() {}

    /// The current selection. It may be ``AppLanguage/system``.
    public var language: AppLanguage {
        lock.lock()
        defer { lock.unlock() }
        return storedLanguage
    }

    /// The concrete `.lproj` identifier currently in effect.
    public var resolvedIdentifier: String {
        Self.resolvedIdentifier(for: language, preferredLocalizations: Bundle.main.preferredLocalizations)
    }

    /// The locale matching ``resolvedIdentifier``.
    public var locale: Locale { Locale(identifier: resolvedIdentifier) }

    public func setLanguage(_ language: AppLanguage) {
        lock.lock()
        storedLanguage = language
        lock.unlock()
    }

    /// Maps a selection onto one of the shipped localizations.
    ///
    /// `Bundle.main.preferredLocalizations` is the system-resolved list; the
    /// first entry this app ships wins, otherwise ``AppLanguage/fallbackIdentifier``.
    public static func resolvedIdentifier(
        for language: AppLanguage,
        preferredLocalizations: [String]
    ) -> String {
        switch language {
        case .simplifiedChinese: return AppLanguage.simplifiedChinese.rawValue
        case .english: return AppLanguage.english.rawValue
        case .system:
            for candidate in preferredLocalizations {
                if AppLanguage.supportedIdentifiers.contains(candidate) { return candidate }
                if let match = AppLanguage.supportedIdentifiers.first(where: {
                    candidate.hasPrefix($0) || $0.hasPrefix(candidate)
                }) {
                    return match
                }
            }
            return AppLanguage.fallbackIdentifier
        }
    }

    /// Looks a key up in the selected language, falling back to the key itself.
    public func string(_ key: String) -> String {
        guard let bundle = localizedBundle() else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Looks a format key up and substitutes `arguments`.
    public func format(_ key: String, _ arguments: [CVarArg]) -> String {
        Self.substitute(string(key), arguments)
    }

    /// Suffix of the plural variant of a count-bearing key.
    public static let pluralKeySuffix = "#plural"

    /// Count-aware lookup.
    ///
    /// Simplified Chinese does not inflect for number, so a count-bearing
    /// source string is a single key. English needs both forms, so the table
    /// stores the singular under the key and the plural under `<key>#plural`.
    /// A language that omits the variant simply falls back to the key.
    ///
    /// This deliberately avoids `Localizable.stringsdict`: `String(format:)`
    /// crashes on the `%#@variable@` specifier when it shares a format with
    /// `%@`.
    public func plural(_ key: String, count: Int, _ arguments: [CVarArg]) -> String {
        guard count != 1 else { return format(key, arguments) }
        let variant = key + Self.pluralKeySuffix
        let selected = string(variant)
        guard selected != variant else { return format(key, arguments) }
        return Self.substitute(selected, arguments)
    }

    /// Replaces each `%@` in `template` with the matching argument.
    ///
    /// Substitution is done by hand instead of through `String(format:)`
    /// because the tables use `%@` for every placeholder while call sites pass
    /// `Int`, `String` and pre-formatted values alike; passing a non-object to
    /// `%@` through the C format engine crashes. Substituted text is never
    /// rescanned, so a value containing `%@` cannot consume a later argument.
    public static func substitute(_ template: String, _ arguments: [CVarArg]) -> String {
        var result = ""
        var remainder = template[...]
        var index = 0
        while let range = remainder.range(of: "%@") {
            result += remainder[remainder.startIndex..<range.lowerBound]
            if index < arguments.count {
                result += String(describing: arguments[index])
                index += 1
            } else {
                result += "%@"
            }
            remainder = remainder[range.upperBound...]
        }
        result += remainder
        return result
    }

    /// Formats a byte count with the interface language instead of the
    /// process-wide locale used by `ByteCountFormatter.string(fromByteCount:)`.
    public func byteCount(_ bytes: Int64) -> String {
        let style = ByteCountFormatStyle(
            style: .file,
            allowedUnits: .all,
            spellsOutZero: false,
            includesActualByteCount: false,
            locale: Locale(identifier: resolvedIdentifier)
        )
        return bytes.formatted(style)
    }

    private func localizedBundle() -> Bundle? {
        let identifier = resolvedIdentifier
        lock.lock()
        defer { lock.unlock() }
        if cachedIdentifier == identifier, let cachedBundle { return cachedBundle }
        guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            cachedIdentifier = nil
            cachedBundle = nil
            return nil
        }
        cachedIdentifier = identifier
        cachedBundle = bundle
        return bundle
    }
}
