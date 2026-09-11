import Foundation
import SnakeCoreBindings

/// Swift-facing persistence adapter. The Rust core owns SQLite and only receives
/// non-secret configuration plus Keychain/bookmark references.
final class CorePersistence {
    private let database: CoreDatabase

    init(databaseURL: URL? = nil) throws {
        let fileManager = FileManager.default
        let url: URL
        if let databaseURL {
            url = databaseURL
        } else {
            let support = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = support.appendingPathComponent("Snake", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("snake.sqlite3", isDirectory: false)
        }
        database = try CoreDatabase.open(path: url.path)
    }

    func loadGroups() throws -> [SessionGroup] {
        try database.groups().compactMap { group in
            guard let id = UUID(uuidString: group.id) else { return nil }
            return SessionGroup(id: id, name: group.name, sortOrder: Int(group.sortOrder))
        }
    }

    func loadProfiles() throws -> [SSHProfile] {
        try database.profiles().compactMap { profile in
            guard let id = UUID(uuidString: profile.id) else { return nil }
            return SSHProfile(
                id: id,
                groupID: profile.groupId.flatMap(UUID.init(uuidString:)),
                name: profile.name,
                host: profile.host,
                port: Int(profile.port),
                username: profile.username,
                authMethod: profile.authMethod == .privateKey ? .privateKey : .password,
                keychainAccount: profile.keychainAccount,
                privateKeyBookmark: profile.privateKeyBookmark,
                tags: profile.tags,
                symbolName: profile.symbolName,
                sortOrder: Int(profile.sortOrder)
            )
        }
    }

    func save(_ group: SessionGroup) throws {
        try database.saveGroup(group: CoreSessionGroup(
            id: group.id.uuidString,
            name: group.name,
            sortOrder: Int64(group.sortOrder)
        ))
    }

    func save(_ profile: SSHProfile) throws {
        try database.saveProfile(profile: CoreSshProfile(
            id: profile.id.uuidString,
            groupId: profile.groupID?.uuidString,
            name: profile.name,
            host: profile.host,
            port: UInt16(profile.port),
            username: profile.username,
            authMethod: profile.authMethod == .privateKey ? .privateKey : .password,
            keychainAccount: profile.keychainAccount,
            privateKeyBookmark: profile.privateKeyBookmark,
            tags: profile.tags,
            symbolName: profile.symbolName,
            sortOrder: Int64(profile.sortOrder)
        ))
    }

    func deleteProfile(id: UUID) throws {
        try database.deleteProfile(id: id.uuidString)
    }

    func loadMountMappings() throws -> [MountMapping] {
        try database.mountMappings().compactMap { mapping in
            guard let id = UUID(uuidString: mapping.id) else { return nil }
            return MountMapping(
                id: id,
                profileID: mapping.profileId.flatMap(UUID.init(uuidString:)),
                name: mapping.name,
                remotePath: mapping.remotePath,
                userAccessPath: mapping.userAccessPath,
                managedMountPath: mapping.managedMountPath,
                autoMount: mapping.autoMount,
                enabled: mapping.enabled,
                state: mapping.enabled ? .idle : .failed,
                lastError: mapping.lastError
            )
        }
    }

    func save(_ mapping: MountMapping, profileSnapshot: String) throws {
        try database.saveMountMapping(mapping: CoreMountMapping(
            id: mapping.id.uuidString,
            profileId: mapping.profileID?.uuidString,
            profileSnapshot: profileSnapshot,
            name: mapping.name,
            remotePath: mapping.remotePath,
            userAccessPath: mapping.userAccessPath,
            managedMountPath: mapping.managedMountPath,
            autoMount: mapping.autoMount,
            enabled: mapping.enabled,
            lastError: mapping.lastError
        ))
    }

    func loadTransferJobs() throws -> [TransferJob] {
        try database.transferJobs().compactMap { job in
            guard let id = UUID(uuidString: job.id) else { return nil }
            return TransferJob(
                id: id,
                sourceProfileName: job.sourceProfileName,
                targetProfileName: job.targetProfileName,
                sourcePath: job.sourcePath,
                targetPath: job.targetPath,
                totalBytes: job.totalBytes,
                completedBytes: job.completedBytes,
                state: TransferState(rawValue: job.state) ?? .interrupted,
                errorMessage: job.errorMessage,
                createdAt: Date(timeIntervalSince1970: TimeInterval(job.createdAt))
            )
        }
    }

    func save(_ job: TransferJob) throws {
        try database.saveTransferJob(job: CoreTransferJob(
            id: job.id.uuidString,
            sourceProfileName: job.sourceProfileName,
            targetProfileName: job.targetProfileName,
            sourcePath: job.sourcePath,
            targetPath: job.targetPath,
            totalBytes: job.totalBytes,
            completedBytes: job.completedBytes,
            state: job.state.rawValue,
            errorMessage: job.errorMessage,
            createdAt: Int64(job.createdAt.timeIntervalSince1970)
        ))
    }

    func deleteTransfer(id: UUID) throws {
        try database.deleteTransferJob(id: id.uuidString)
    }

    func deleteMapping(id: UUID) throws {
        try database.deleteMountMapping(id: id.uuidString)
    }

    func synchronize(groups: [SessionGroup], profiles: [SSHProfile]) throws {
        let expectedGroupIDs = Set(groups.map(\.id))
        let expectedProfileIDs = Set(profiles.map(\.id))

        for group in groups { try save(group) }
        for profile in profiles { try save(profile) }

        for profile in try loadProfiles() where !expectedProfileIDs.contains(profile.id) {
            try database.deleteProfile(id: profile.id.uuidString)
        }
        for group in try loadGroups() where !expectedGroupIDs.contains(group.id) {
            try database.deleteGroup(id: group.id.uuidString)
        }
    }

    func synchronize(mappings: [MountMapping], profiles: [SSHProfile]) throws {
        let expectedIDs = Set(mappings.map(\.id))
        for mapping in mappings {
            let snapshot = profiles.first(where: { $0.id == mapping.profileID })?.name ?? "已删除会话"
            try save(mapping, profileSnapshot: snapshot)
        }
        for mapping in try loadMountMappings() where !expectedIDs.contains(mapping.id) {
            try database.deleteMountMapping(id: mapping.id.uuidString)
        }
    }
}
