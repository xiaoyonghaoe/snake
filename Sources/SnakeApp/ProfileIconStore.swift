import AppKit
import Foundation

@MainActor
enum ProfileIconStore {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for profileID: UUID) -> NSImage? {
        let key = profileID.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: fileURL(for: profileID)),
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func data(for profileID: UUID) -> Data? {
        try? Data(contentsOf: fileURL(for: profileID))
    }

    static func save(_ data: Data, for profileID: UUID) throws {
        guard let image = NSImage(data: data) else { throw ProfileIconStoreError.invalidImage }
        let manager = FileManager.default
        let directory = try iconsDirectory()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: profileID), options: .atomic)
        cache.setObject(image, forKey: profileID.uuidString as NSString)
    }

    static func delete(for profileID: UUID) {
        cache.removeObject(forKey: profileID.uuidString as NSString)
        try? FileManager.default.removeItem(at: fileURL(for: profileID))
    }

    private static func fileURL(for profileID: UUID) -> URL {
        let base = (try? iconsDirectory())
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Snake/ProfileIcons", isDirectory: true)
        return base.appendingPathComponent("\(profileID.uuidString).png", isDirectory: false)
    }

    private static func iconsDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("Snake", isDirectory: true)
            .appendingPathComponent("ProfileIcons", isDirectory: true)
    }
}

private enum ProfileIconStoreError: LocalizedError {
    case invalidImage

    var errorDescription: String? { L10n.text("选择的文件不是可用的图片。") }
}
