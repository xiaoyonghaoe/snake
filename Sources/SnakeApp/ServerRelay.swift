import Foundation

/// Local staging for copying between two servers.
///
/// Each copy downloads into its own batch folder `<root>/snake-relay-<uuid>/`,
/// uploads from there, and removes that folder once the upload ends, whatever the
/// outcome. Only batch folders this app created are ever removed, so a folder the
/// user chose keeps the rest of its contents.
enum ServerRelay {
    static let defaultRootRelativePath = "Snake/Relay"
    static let batchPrefix = "snake-relay-"

    /// `~/Library/Caches/Snake/Relay`.
    static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent(defaultRootRelativePath, isDirectory: true)
    }

    /// Resolves the relay root; a folder that can no longer be resolved falls back to
    /// the default location and reports it, like the open-remote-file cache.
    static func location(bookmark: Data?, accessScope: Bool) -> RemoteOpenCache.Location {
        var location = RemoteOpenCache.location(bookmark: bookmark, accessScope: accessScope)
        if location.isDefault { location.url = defaultRoot() }
        return location
    }

    /// Creates a private batch folder for one copy.
    static func makeBatch(root: URL, ownedRoot: Bool, fileManager: FileManager = .default) throws -> URL {
        try RemoteOpenCache.prepare(directory: root, owned: ownedRoot, fileManager: fileManager)
        let batch = root.appendingPathComponent(batchPrefix + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: batch, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: RemoteOpenCache.ownedDirectoryPermissions])
        if ownedRoot { RemoteOpenCache.excludeFromBackup(batch) }
        return batch
    }

    /// True only for a batch folder this app created: a real directory, never a link,
    /// named with our prefix and a UUID.
    static func isBatch(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix(batchPrefix), UUID(uuidString: String(name.dropFirst(batchPrefix.count))) != nil,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// Removes one batch folder and everything in it.
    static func removeBatch(_ batch: URL, fileManager: FileManager = .default) {
        guard isBatch(batch) else { return }
        try? fileManager.removeItem(at: batch)
    }

    /// Removes batches left behind by a crash or a forced quit.
    @discardableResult
    static func removeStaleBatches(root: URL, fileManager: FileManager = .default) -> Int {
        let children = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [])) ?? []
        var removed = 0
        for child in children where isBatch(child) {
            if (try? fileManager.removeItem(at: child)) != nil { removed += 1 }
        }
        return removed
    }

    /// Deletes every symbolic link under `batch` without following any.
    ///
    /// Uploading reads through links, so a link that came from the source server must
    /// never reach it: it could send an arbitrary local file to the destination.
    @discardableResult
    static func removeSymbolicLinks(in batch: URL, fileManager: FileManager = .default) -> Int {
        guard let enumerator = fileManager.enumerator(at: batch, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else {
            return 0
        }
        var removed = 0
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}

extension LocalUploadCoordinator {
    /// Downloads `file` from `source` into `batch`, then uploads it into
    /// `destinationRoot` on this coordinator's server. Nothing is uploaded unless the
    /// whole download succeeded. The caller owns `batch` and deletes it afterwards.
    func relay(_ file: RemoteFile, from source: DownloadSource, through batch: URL, to destinationRoot: String,
               store: ApplicationStore, onUploaded: (@MainActor () -> Void)? = nil) async {
        let downloaded = await withCheckedContinuation { continuation in
            download(files: [file], to: batch, store: store, from: source) { continuation.resume(returning: $0) }
        }
        guard downloaded.failed == 0, downloaded.cancelled == 0 else { return }
        _ = await Task.detached(priority: .utility) { ServerRelay.removeSymbolicLinks(in: batch) }.value
        // A skipped top-level link leaves nothing to upload.
        let local = batch.appendingPathComponent(file.name)
        guard FileManager.default.fileExists(atPath: local.path) else { return }
        upload(urls: [local], destinationRoot: destinationRoot, store: store, relay: true, onFinished: onUploaded)
        await batchTask?.value
    }
}
