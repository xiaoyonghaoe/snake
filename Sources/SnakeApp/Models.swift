import Foundation

public enum AuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case privateKey = "private_key"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .password: L10n.text("密码")
        case .privateKey: L10n.text("密钥")
        }
    }
}

public enum ConnectionState: String, Codable, Sendable {
    case idle
    case connecting
    case connected
    case disconnected
    case failed

    public var label: String {
        switch self {
        case .idle: L10n.text("未连接")
        case .connecting: L10n.text("正在连接")
        case .connected: L10n.text("已连接")
        case .disconnected: L10n.text("已断开")
        case .failed: L10n.text("连接失败")
        }
    }
}

public enum TransferState: String, Codable, CaseIterable, Sendable {
    case scanning
    case queued
    case running
    case paused
    case succeeded
    case failed
    case cancelled
    case interrupted

    public var label: String {
        switch self {
        case .scanning: L10n.text("正在扫描")
        case .queued: L10n.text("等待中")
        case .running: L10n.text("传输中")
        case .paused: L10n.text("已暂停")
        case .succeeded: L10n.text("已完成")
        case .failed: L10n.text("失败")
        case .cancelled: L10n.text("已取消")
        case .interrupted: L10n.text("已中断")
        }
    }
}

public enum MountState: String, Codable, Sendable {
    case unavailable
    case idle
    case mounting
    case mounted
    case failed
    case external

    public var label: String {
        switch self {
        case .unavailable: L10n.text("缺少依赖")
        case .idle: L10n.text("未挂载")
        case .mounting: L10n.text("正在挂载")
        case .mounted: L10n.text("已挂载")
        case .failed: L10n.text("挂载失败")
        case .external: L10n.text("外部挂载")
        }
    }
}

public struct SessionGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var sortOrder: Int
    /// Folders nest; `nil` is the top level. Absent in older saved data.
    public var parentID: UUID?

    public init(id: UUID = UUID(), name: String, sortOrder: Int = 0, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.parentID = parentID
    }
}

public struct SSHProfile: Identifiable, Codable, Hashable, Sendable {
    public static let customIconSymbolName = "snake.custom-profile-icon"
    public var id: UUID
    public var groupID: UUID?
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: AuthMethod
    public var keychainAccount: String?
    public var privateKeyBookmark: Data?
    public var tags: [String]
    public var symbolName: String
    public var sortOrder: Int
    public var savedPasswordID: UUID?

    public init(
        id: UUID = UUID(),
        groupID: UUID? = nil,
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .password,
        keychainAccount: String? = nil,
        privateKeyBookmark: Data? = nil,
        tags: [String] = [],
        symbolName: String = "server.rack",
        sortOrder: Int = 0,
        savedPasswordID: UUID? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.keychainAccount = keychainAccount
        self.privateKeyBookmark = privateKeyBookmark
        self.tags = tags
        self.symbolName = symbolName
        self.sortOrder = sortOrder
        self.savedPasswordID = savedPasswordID
    }

    public var connectionLabel: String { "\(username)@\(host):\(port)" }
    public var keychainPasswordAccount: String { "\(id.uuidString)/password" }
    public var keychainPassphraseAccount: String { "\(id.uuidString)/key-passphrase" }
    public var usesCustomIcon: Bool { symbolName == Self.customIconSymbolName }
}

/// When a session was created and last edited, as SQLite records them; reordering
/// or moving it in the list is not an edit.
public struct SSHProfileTimestamps: Hashable, Sendable {
    public var createdAt: Date
    public var updatedAt: Date
}

public struct SavedPassword: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var username: String
    /// `nil` until the entry has been stored.
    public var createdAt: Date?
    /// The last name, username or password change.
    public var updatedAt: Date?

    public init(id: UUID = UUID(), name: String, username: String, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.username = username
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var credentialAccount: String { "library/\(id.uuidString)/password" }
}

/// Folders group SSH sessions and nest inside each other; a session's `groupID`
/// and a folder's `parentID` name their folder, and `nil` is the top level.
/// Folders replaced tags, which stay stored on the profile but are no longer
/// shown or edited.
enum SessionFolders {
    /// One-time move from tags: a session outside any folder goes into a folder
    /// named after its first tag, reusing an existing folder of that name.
    static func placingByFirstTag(
        groups: [SessionGroup],
        profiles: [SSHProfile]
    ) -> (groups: [SessionGroup], profiles: [SSHProfile]) {
        var groups = groups
        var profiles = profiles
        for index in profiles.indices where profiles[index].groupID == nil {
            guard let tag = profiles[index].tags.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !tag.isEmpty else { continue }
            if let existing = groups.first(where: { $0.parentID == nil && $0.name == tag }) {
                profiles[index].groupID = existing.id
            } else {
                let folder = SessionGroup(name: tag, sortOrder: (groups.map(\.sortOrder).max() ?? -1) + 1)
                groups.append(folder)
                profiles[index].groupID = folder.id
            }
        }
        return (groups, profiles)
    }

    static func sorted(_ groups: [SessionGroup]) -> [SessionGroup] {
        groups.sorted {
            $0.sortOrder == $1.sortOrder
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.sortOrder < $1.sortOrder
        }
    }

    /// Names are trimmed and unique among siblings, ignoring case.
    static func validatedName(_ name: String, among groups: [SessionGroup], parentID: UUID? = nil,
                              excluding id: UUID? = nil) -> String? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              !groups.contains(where: {
                  $0.id != id && $0.parentID == parentID && $0.name.caseInsensitiveCompare(cleaned) == .orderedSame
              }) else { return nil }
        return cleaned
    }

    /// The folders directly inside `parentID`, in display order. A folder whose
    /// parent no longer exists shows at the top level.
    static func children(of parentID: UUID?, in groups: [SessionGroup]) -> [SessionGroup] {
        let ids = Set(groups.map(\.id))
        return sorted(groups.filter { group in
            let effectiveParent = group.parentID.flatMap { ids.contains($0) ? $0 : nil }
            return effectiveParent == parentID
        })
    }

    /// From the top level down to `id` itself; stops on a cycle.
    static func path(to id: UUID?, in groups: [SessionGroup]) -> [SessionGroup] {
        var path: [SessionGroup] = []
        var current = id
        var seen = Set<UUID>()
        while let currentID = current, seen.insert(currentID).inserted,
              let group = groups.first(where: { $0.id == currentID }) {
            path.insert(group, at: 0)
            current = group.parentID
        }
        return path
    }

    /// True when `id` is `ancestor` or sits anywhere inside it.
    static func isWithin(_ id: UUID?, _ ancestor: UUID, in groups: [SessionGroup]) -> Bool {
        path(to: id, in: groups).contains { $0.id == ancestor }
    }

    /// Parents before children, so a child's foreign key always finds its parent.
    static func parentsFirst(_ groups: [SessionGroup]) -> [SessionGroup] {
        groups.sorted { path(to: $0.id, in: groups).count < path(to: $1.id, in: groups).count }
    }

    /// Long-press reordering: the moved item takes the target's place, landing
    /// after it when moving forward and before it when moving back.
    static func moving<ID: Equatable>(_ id: ID, onto target: ID, in ids: [ID]) -> [ID] {
        guard id != target,
              let from = ids.firstIndex(of: id),
              let to = ids.firstIndex(of: target) else { return ids }
        var result = ids
        result.remove(at: from)
        result.insert(id, at: to)
        return result
    }

    /// A press becomes a drag once it travels a few points, or once it has been
    /// held briefly and then moves. A plain click never starts one, and a hand
    /// that drifts while holding no longer cancels the drag.
    static func dragActivates(distance: CGFloat, held: TimeInterval) -> Bool {
        distance >= 6 || (held >= 0.25 && distance > 0)
    }

    /// Search covers what a card shows: name, address, account and folder.
    static func matches(_ profile: SSHProfile, query: String, folderName: String?) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [profile.name, profile.host, profile.username, folderName ?? ""]
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(query)
    }
}

public struct RemoteFile: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    public var linkTarget: String?
    public var size: Int64
    public var modifiedAt: Date
    public var permissions: String

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        isDirectory: Bool,
        isSymbolicLink: Bool = false,
        linkTarget: String? = nil,
        size: Int64 = 0,
        modifiedAt: Date = .now,
        permissions: String = ""
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.linkTarget = linkTarget
        self.size = size
        self.modifiedAt = modifiedAt
        self.permissions = permissions
    }
}

/// In-process-only SFTP drag payload. It deliberately contains no credential,
/// bookmark, connection handle, or local file URL.
public struct RemoteFileTransferPayload: Codable, Sendable {
    public let sourceRuntimeID: UUID
    public let sourceProfileID: UUID
    public let sourcePath: String
    public let fileName: String
    public let fileSize: Int64
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let linkTarget: String?

    public init(sourceRuntimeID: UUID, sourceProfileID: UUID, sourcePath: String, fileName: String, fileSize: Int64, isDirectory: Bool, isSymbolicLink: Bool = false, linkTarget: String? = nil) {
        self.sourceRuntimeID = sourceRuntimeID
        self.sourceProfileID = sourceProfileID
        self.sourcePath = sourcePath
        self.fileName = fileName
        self.fileSize = fileSize
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.linkTarget = linkTarget
    }
}

public struct TransferJob: Identifiable, Hashable, Sendable {
    /// Endpoint name for transfers that originate on, or target, this Mac.
    public static let localEndpointName = "本机"

    public var id: UUID
    public var sourceProfileName: String
    public var targetProfileName: String
    public var sourcePath: String
    public var targetPath: String
    public var totalBytes: Int64
    public var completedBytes: Int64
    public var speedBytesPerSecond: Int64
    public var state: TransferState
    public var errorMessage: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        sourceProfileName: String,
        targetProfileName: String,
        sourcePath: String,
        targetPath: String,
        totalBytes: Int64,
        completedBytes: Int64 = 0,
        speedBytesPerSecond: Int64 = 0,
        state: TransferState = .queued,
        errorMessage: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sourceProfileName = sourceProfileName
        self.targetProfileName = targetProfileName
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.totalBytes = totalBytes
        self.completedBytes = completedBytes
        self.speedBytesPerSecond = speedBytesPerSecond
        self.state = state
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }

    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }
}

public struct MountMapping: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var profileID: UUID?
    public var name: String
    public var remotePath: String
    public var userAccessPath: String
    public var managedMountPath: String
    public var autoMount: Bool
    public var enabled: Bool
    public var state: MountState
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        profileID: UUID? = nil,
        name: String,
        remotePath: String,
        userAccessPath: String,
        managedMountPath: String,
        autoMount: Bool = false,
        enabled: Bool = true,
        state: MountState = .idle,
        lastError: String? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.name = name
        self.remotePath = remotePath
        self.userAccessPath = userAccessPath
        self.managedMountPath = managedMountPath
        self.autoMount = autoMount
        self.enabled = enabled
        self.state = state
        self.lastError = lastError
    }
}

/// A local port forward (`ssh -L`): `127.0.0.1:localPort` reaches
/// `remoteHost:remotePort` as seen from the session's server.
public struct SSHTunnel: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// `nil` once the session was deleted; the tunnel waits to be rebound.
    public var profileID: UUID?
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int
    public var note: String
    public var autoStart: Bool
    public var sortOrder: Int
    /// `nil` until the tunnel has been stored.
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: UUID = UUID(),
        profileID: UUID? = nil,
        localPort: Int,
        remoteHost: String = "127.0.0.1",
        remotePort: Int,
        note: String = "",
        autoStart: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.note = note
        self.autoStart = autoStart
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var localAddress: String { "127.0.0.1:\(localPort)" }

    public var remoteAddress: String {
        remoteHost.contains(":") ? "[\(remoteHost)]:\(remotePort)" : "\(remoteHost):\(remotePort)"
    }

    /// Fields whose change requires a running tunnel to restart.
    func sameEndpoint(as other: SSHTunnel) -> Bool {
        profileID == other.profileID && localPort == other.localPort
            && remoteHost == other.remoteHost && remotePort == other.remotePort
    }
}

public enum TunnelState: Hashable, Sendable {
    case stopped
    case starting
    case running(connections: Int)
    /// The SSH connection dropped; the user reconnects by hand.
    case disconnected(String)
    case failed(String)

    public var label: String {
        switch self {
        case .stopped: L10n.text("未连接")
        case .starting: L10n.text("正在连接")
        case .running(let connections):
            connections == 0 ? L10n.text("已连接") : L10n.format("已连接 · %@ 个连接", connections)
        case .disconnected: L10n.text("已断开")
        case .failed: L10n.text("连接失败")
        }
    }

    public var detail: String? {
        switch self {
        case .disconnected(let message), .failed(let message): message
        default: nil
        }
    }

    public var isActive: Bool {
        switch self {
        case .starting, .running: true
        default: false
        }
    }
}

public enum WorkspaceTabKind: Hashable, Sendable {
    case sessions
    case mounts
    case mcp
    case passwords
    case terminal(profileID: UUID)
    case sftp(profileID: UUID)

    public var symbolName: String {
        switch self {
        case .sessions: "square.grid.2x2"
        // One page holds both disk mappings and SSH tunnels: a drive on the network.
        case .mounts: "externaldrive.connected.to.line.below"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .passwords: "key.horizontal"
        case .terminal: "terminal"
        case .sftp: "folder"
        }
    }
}
