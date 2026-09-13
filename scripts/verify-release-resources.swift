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
print("Bundle version: \(app.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "missing")")
