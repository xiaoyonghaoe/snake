import Foundation
import XCTest
@testable import SnakeApp

/// Guards the localization tables against drift.
///
/// The simplified Chinese source text is also the localization key, so every
/// key used by a localization-aware call site must have an English entry and
/// every entry must still be referenced from source.
final class LocalizationTests: XCTestCase {

    // MARK: - Fixtures

    /// `Tests/SnakeAppTests/LocalizationTests.swift` → repository root.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let englishRoot = repositoryRoot
        .appendingPathComponent("Resources/Localization/en.lproj", isDirectory: true)

    private static let sourceRoot = repositoryRoot
        .appendingPathComponent("Sources/SnakeApp", isDirectory: true)

    /// Initializers and modifiers that take a `LocalizedStringKey`, so a bare
    /// literal passed to them is localized by SwiftUI without an `L10n` call.
    private static let localizedCallNames = [
        "Text", "Button", "Label", "Section", "Toggle", "Picker", "TextField", "SecureField",
        "Menu", "Stepper", "Link", "NavigationLink", "LabeledContent", "confirmationDialog",
        "alert", "help", "accessibilityLabel", "accessibilityHint", "navigationTitle", "navigationSubtitle",
        "SettingsFooter"
    ].joined(separator: "|")

    private static let l10nCall = try! NSRegularExpression(
        pattern: "L10n\\.(?:text|format|plural)\\(\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
    )

    private static let pluralCall = try! NSRegularExpression(
        pattern: "L10n\\.plural\\(\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
    )

    private static let autoLocalizedCall = try! NSRegularExpression(
        pattern: "(?:^|[\\s.(,])(" + localizedCallNames + ")\\s*\\(\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
    )

    /// Strings that intentionally stay verbatim in every language: product
    /// names, units and the terminal mock content of the settings preview.
    private static let untranslatable: Set<String> = [
        "", "Snake", "SFTP", "MB", "简体中文", "English",
        "user@snake ~ % ls", "Documents/  ", "logs/  ", "start.sh"
    ]

    /// Remote shell snippets are written into the user's shell, not the app UI.
    private static let excludedFiles: Set<String> = []

    override func tearDown() {
        LocalizationStore.shared.setLanguage(.system)
        super.tearDown()
    }

    // MARK: - Tests

    func testEnglishTableCoversEveryLocalizedKey() throws {
        let table = try localizedStrings()
        let plurals = try localizedPlurals()
        let missing = try sourceKeys().subtracting(table.keys).subtracting(plurals.keys)
        XCTAssertTrue(missing.isEmpty, "Missing English translations: \(missing.sorted())")
    }

    func testEnglishTableHasNoStaleKeys() throws {
        let known = try sourceKeys()
        let table = try localizedStrings().keys
        let stale = try Set(table.map(Self.stripPluralSuffix)).union(localizedPlurals().keys)
            .subtracting(known)
        XCTAssertTrue(stale.isEmpty, "Translations no longer referenced from source: \(stale.sorted())")
    }

    func testPlaceholderCountsMatchTheSourceKey() throws {
        for (key, value) in try localizedStrings() {
            XCTAssertEqual(
                occurrences(of: "%@", in: key), occurrences(of: "%@", in: value),
                "Placeholder mismatch for \(key) → \(value)"
            )
        }
    }

    /// Every count-bearing key needs a distinct plural form; English never
    /// reuses the singular for a count other than one.
    func testPluralKeysCarryADistinctPluralForm() throws {
        let table = try localizedStrings()
        let pluralKeys = try pluralSourceKeys()
        XCTAssertFalse(pluralKeys.isEmpty, "Expected count-aware L10n.plural call sites")
        for key in pluralKeys {
            let singular = try XCTUnwrap(table[key], "Missing singular form for \(key)")
            let plural = try XCTUnwrap(table[key + LocalizationStore.pluralKeySuffix], "Missing plural form for \(key)")
            XCTAssertNotEqual(singular, plural, "Plural form equals the singular for \(key)")
        }
    }

    func testCountAwareLookupSelectsTheMatchingForm() throws {
        let bundle = try XCTUnwrap(Bundle(path: Self.englishRoot.path), "Could not load the English bundle")
        let key = "已上传 %@ 项"
        let singular = bundle.localizedString(forKey: key, value: key, table: nil)
        let plural = bundle.localizedString(forKey: key + LocalizationStore.pluralKeySuffix, value: key, table: nil)
        XCTAssertEqual(LocalizationStore.substitute(singular, [1]), "Uploaded 1 item")
        XCTAssertEqual(LocalizationStore.substitute(plural, [4]), "Uploaded 4 items")
    }

    func testSubstitutionHandlesEveryArgumentType() {
        XCTAssertEqual(LocalizationStore.substitute("%@ 秒", [12]), "12 秒")
        XCTAssertEqual(LocalizationStore.substitute("%@ / %@", ["a", 2]), "a / 2")
        // A substituted value containing %@ must not consume a later argument.
        XCTAssertEqual(LocalizationStore.substitute("%@ · %@", ["100%@", "x"]), "100%@ · x")
        XCTAssertEqual(LocalizationStore.substitute("%@ 项", []), "%@ 项")
    }

    func testPermissionPromptIsTranslatedForEveryShippedLanguage() throws {
        for language in AppLanguage.supportedIdentifiers {
            let url = Self.repositoryRoot
                .appendingPathComponent("Resources/Localization/\(language).lproj/InfoPlist.strings")
            let entries = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "Unreadable \(url.path)")
            let description = try XCTUnwrap(entries["NSLocalNetworkUsageDescription"], "Missing in \(language)")
            XCTAssertFalse(description.isEmpty)
        }
    }

    // MARK: - Runtime behavior

    func testLookupFallsBackToTheSourceLanguageWithoutABundleTable() {
        // The test bundle ships no .lproj tables, which also models `swift run`.
        XCTAssertEqual(L10n.text("无法上传"), "无法上传")
        XCTAssertEqual(L10n.format("已选 %@ 个标签", 3), "已选 3 个标签")
    }

    func testUnsupportedSystemLanguageFallsBackToSimplifiedChinese() {
        XCTAssertEqual(
            LocalizationStore.resolvedIdentifier(for: .system, preferredLocalizations: ["fr", "de"]),
            AppLanguage.fallbackIdentifier
        )
        XCTAssertEqual(
            LocalizationStore.resolvedIdentifier(for: .system, preferredLocalizations: ["en-US", "zh-Hans"]),
            "en"
        )
        XCTAssertEqual(LocalizationStore.resolvedIdentifier(for: .english, preferredLocalizations: ["zh-Hans"]), "en")
        XCTAssertEqual(
            LocalizationStore.resolvedIdentifier(for: .simplifiedChinese, preferredLocalizations: ["en"]),
            "zh-Hans"
        )
    }

    @MainActor
    func testLanguageSelectionRoundTripsThroughUserDefaults() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snake-localization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "snake-localization-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ApplicationStore(databaseURL: root.appendingPathComponent("test.sqlite3"), userDefaults: defaults)
        XCTAssertEqual(store.appLanguage, .system)
        store.appLanguage = .english
        XCTAssertEqual(LocalizationStore.shared.language, .english)

        let restored = ApplicationStore(databaseURL: root.appendingPathComponent("second.sqlite3"), userDefaults: defaults)
        XCTAssertEqual(restored.appLanguage, .english)
    }

    // MARK: - Helpers

    private func localizedStrings() throws -> [String: String] {
        let url = Self.englishRoot.appendingPathComponent("Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "Unreadable \(url.path)")
    }

    private func localizedPlurals() throws -> [String: Any] {
        let url = Self.englishRoot.appendingPathComponent("Localizable.stringsdict")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any], "Unreadable \(url.path)")
    }

    /// Every key referenced by a localization-aware call site in `Sources/SnakeApp`.
    private func sourceKeys() throws -> Set<String> {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: Self.sourceRoot, includingPropertiesForKeys: nil)
        )
        var keys: Set<String> = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift", !Self.excludedFiles.contains(url.lastPathComponent) else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for expression in [Self.l10nCall, Self.autoLocalizedCall] {
                let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
                for match in matches {
                    // The first pattern captures one group, the second two.
                    let capture = match.numberOfRanges == 2 ? match.range(at: 1) : match.range(at: 2)
                    guard let range = Range(capture, in: source) else { continue }
                    let literal = String(source[range])
                    // Interpolated literals are always routed through L10n.format.
                    guard !literal.contains("\\(") else { continue }
                    let key = Self.unescape(literal)
                    guard !Self.untranslatable.contains(key) else { continue }
                    keys.insert(key)
                }
            }
        }
        return keys
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// Keys that go through ``L10n/plural(_:count:_:)`` and therefore need a
    /// `#plural` entry as well.
    private func pluralSourceKeys() throws -> Set<String> {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: Self.sourceRoot, includingPropertiesForKeys: nil)
        )
        var keys: Set<String> = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            let matches = Self.pluralCall.matches(in: source, range: NSRange(source.startIndex..., in: source))
            for match in matches {
                guard let range = Range(match.range(at: 1), in: source) else { continue }
                keys.insert(Self.unescape(String(source[range])))
            }
        }
        return keys
    }

    private static func stripPluralSuffix(_ key: String) -> String {
        guard key.hasSuffix(LocalizationStore.pluralKeySuffix) else { return key }
        return String(key.dropLast(LocalizationStore.pluralKeySuffix.count))
    }

    /// Turns the source-level escapes of a Swift literal into the runtime string
    /// the localization lookup actually uses.
    private static func unescape(_ literal: String) -> String {
        var result = ""
        var iterator = literal.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let escape = iterator.next() else {
                result.append(character)
                continue
            }
            switch escape {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "0": result.append("\0")
            case "\\": result.append("\\")
            case "\"": result.append("\"")
            case "'": result.append("'")
            default:
                result.append("\\")
                result.append(escape)
            }
        }
        return result
    }
}
