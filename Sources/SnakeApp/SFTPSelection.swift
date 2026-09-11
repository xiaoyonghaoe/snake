import Foundation

struct SFTPSelection: Equatable {
    private(set) var ids = Set<UUID>()
    private(set) var anchor: UUID?

    mutating func click(_ id: UUID, order: [UUID], command: Bool = false, shift: Bool = false) {
        guard order.contains(id) else { return }
        if shift, let anchor, let start = order.firstIndex(of: anchor), let end = order.firstIndex(of: id) {
            let range = Set(order[min(start, end)...max(start, end)])
            ids = command ? ids.union(range) : range
        } else if command {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
        } else {
            ids = [id]
            anchor = id
        }
    }

    mutating func contextClick(_ id: UUID, order: [UUID]) {
        if !ids.contains(id) { click(id, order: order) }
    }
}

enum SFTPDeletionBatch {
    static func targets(_ files: [RemoteFile]) -> [RemoteFile] {
        var seen = Set<String>()
        return files.filter {
            let normalized = ($0.path as NSString).standardizingPath
            return $0.path.hasPrefix("/") && normalized != "/" && normalized == $0.path
                && !$0.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
                && seen.insert($0.path).inserted
        }
    }

    static func usesRecursiveRemoval(_ file: RemoteFile) -> Bool {
        file.isDirectory && !file.isSymbolicLink
    }
}
