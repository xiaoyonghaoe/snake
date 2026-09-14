// Read-only validation: does not launch Snake or access user configuration.
import Foundation
import Metal

guard CommandLine.arguments.count == 2,
      let app = Bundle(path: CommandLine.arguments[1]),
      let resourceURL = app.url(forResource: "SwiftTerm_SwiftTerm", withExtension: "bundle"),
      let resources = Bundle(url: resourceURL),
      let shader = resources.url(forResource: "Shaders", withExtension: "metal") else {
    fatalError("Packaged SwiftTerm resources were not found inside the application")
}
let source = try String(contentsOf: shader, encoding: .utf8)
precondition(!source.isEmpty)
if let device = MTLCreateSystemDefaultDevice() {
    let library = try device.makeLibrary(source: source, options: nil)
    precondition(!library.functionNames.isEmpty)
    print("Packaged Metal shaders compiled: \(library.functionNames.count) functions")
} else {
    print("Resource lookup passed; Metal compilation skipped (no GPU available)")
}

// Every shipped language must carry a parseable string table, and the local
// network permission prompt must be translated for each of them. Simplified
// Chinese is the source language: its table is intentionally empty and every
// missing lookup falls back to the Chinese key itself.
let sourceLanguage = "zh-Hans"
let languages = ["zh-Hans", "en"]
for language in languages {
    guard let lproj = app.url(forResource: language, withExtension: "lproj"),
          let bundle = Bundle(url: lproj) else {
        fatalError("Missing \(language).lproj inside the application")
    }
    guard let info = bundle.url(forResource: "InfoPlist", withExtension: "strings"),
          let infoEntries = NSDictionary(contentsOf: info),
          let description = infoEntries["NSLocalNetworkUsageDescription"] as? String,
          !description.isEmpty else {
        fatalError("Missing NSLocalNetworkUsageDescription in \(language).lproj/InfoPlist.strings")
    }
    if language == sourceLanguage {
        print("Localization \(language): source language")
        continue
    }
    guard let table = bundle.url(forResource: "Localizable", withExtension: "strings"),
          let entries = NSDictionary(contentsOf: table), entries.count > 0 else {
        fatalError("Missing or unreadable \(language).lproj/Localizable.strings")
    }
    if let plural = bundle.url(forResource: "Localizable", withExtension: "stringsdict") {
        guard let rules = NSDictionary(contentsOf: plural), rules.count > 0 else {
            fatalError("Unreadable \(language).lproj/Localizable.stringsdict")
        }
    }
    print("Localization \(language): \(entries.count) strings")
}

print("Bundle version: \(app.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "missing")")
