#!/usr/bin/env swift

import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: import-plaintext-credential <account> <credentials-path>\n".utf8))
    exit(2)
}

let account = CommandLine.arguments[1]
let fileURL = URL(fileURLWithPath: CommandLine.arguments[2])
var secretData = FileHandle.standardInput.readDataToEndOfFile()
while secretData.last == 0x0A || secretData.last == 0x0D {
    secretData.removeLast()
}
guard let secret = String(data: secretData, encoding: .utf8), !secret.isEmpty else {
    FileHandle.standardError.write(Data("credential input is empty or invalid UTF-8\n".utf8))
    exit(3)
}

let manager = FileManager.default
let directory = fileURL.deletingLastPathComponent()
try manager.createDirectory(at: directory, withIntermediateDirectories: true)
try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

var credentials: [String: String] = [:]
if manager.fileExists(atPath: fileURL.path) {
    credentials = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fileURL))
}
credentials[account] = secret

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let encoded = try encoder.encode(credentials)
let temporaryURL = directory.appendingPathComponent(".credentials-import-\(UUID().uuidString).tmp")
guard manager.createFile(
    atPath: temporaryURL.path,
    contents: encoded,
    attributes: [.posixPermissions: 0o600]
) else {
    throw CocoaError(.fileWriteUnknown)
}

if manager.fileExists(atPath: fileURL.path) {
    _ = try manager.replaceItemAt(fileURL, withItemAt: temporaryURL)
} else {
    try manager.moveItem(at: temporaryURL, to: fileURL)
}
try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
secretData.resetBytes(in: secretData.startIndex..<secretData.endIndex)
print("Credential reference imported into the temporary plaintext backend.")
