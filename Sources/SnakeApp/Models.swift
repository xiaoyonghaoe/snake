import Foundation

public enum AuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case privateKey = "private_key"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .password: L10n.text("密码")
        case .privateKey: L10n.text("私钥")
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

    public init(id: UUID = UUID(), name: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
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
        sortOrder: Int = 0
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
    }

    public var connectionLabel: String { "\(username)@\(host):\(port)" }
    public var keychainPasswordAccount: String { "\(id.uuidString)/password" }
    public var keychainPassphraseAccount: String { "\(id.uuidString)/key-passphrase" }
    public var usesCustomIcon: Bool { symbolName == Self.customIconSymbolName }
}

enum SessionTags {
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func format(_ tags: [String]) -> String {
        tags.joined(separator: " ")
    }
}

enum SessionTagFilter {
    static func matches(profileTags: [String], selectedTags: Set<String>) -> Bool {
        selectedTags.isEmpty || selectedTags.isSubset(of: Set(profileTags))
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
    /// Persisted sentinel for transfers that originate on, or target, this Mac.
    ///
    /// It is stored data rather than interface text, so it must never be
    /// localized: changing it would orphan existing records.
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

public enum WorkspaceTabKind: Hashable, Sendable {
    case sessions
    case mounts
    case terminal(profileID: UUID)
    case sftp(profileID: UUID)

    public var symbolName: String {
        switch self {
        case .sessions: "square.grid.2x2"
        case .mounts: "externaldrive"
        case .terminal: "terminal"
        case .sftp: "folder"
        }
    }
}
