import AppKit
import Foundation
import Combine
import SnakeCoreBindings

@MainActor
public final class ApplicationStore: ObservableObject {
    public static let shared = ApplicationStore()

    @Published public private(set) var groups: [SessionGroup]
    @Published public private(set) var profiles: [SSHProfile]
    @Published public private(set) var transferJobs: [TransferJob]
    @Published public private(set) var mountMappings: [MountMapping]
    @Published var mountActionError: String?
    @Published public var selectedProfileID: UUID?
    @Published public var isDarkAppearancePreferred: Bool {
        didSet { defaults.set(isDarkAppearancePreferred, forKey: appearanceKey) }
    }
    @Published public var multipartThresholdMB: Int {
        didSet {
            let value = min(max(multipartThresholdMB, 1), 10_240)
            if value != multipartThresholdMB { multipartThresholdMB = value; return }
            defaults.set(value, forKey: multipartThresholdKey)
        }
    }
    @Published public var multipartConcurrency: Int {
        didSet {
            let value = min(max(multipartConcurrency, 1), 8)
            if value != multipartConcurrency { multipartConcurrency = value; return }
            defaults.set(value, forKey: multipartConcurrencyKey)
        }
    }
    @Published public var terminalFontName: String {
        didSet { defaults.set(terminalFontName, forKey: terminalFontNameKey) }
    }
    @Published public var terminalFontSize: Double {
        didSet {
            let value = min(max(terminalFontSize, 9), 32)
            if value != terminalFontSize { terminalFontSize = value; return }
            defaults.set(value, forKey: terminalFontSizeKey)
        }
    }

    weak var workspaceCoordinator: WorkspaceWindowCoordinator?

    private let defaults: UserDefaults
    private let corePersistence: CorePersistence?
    private let groupsKey = "com.snake.groups"
    private let profilesKey = "com.snake.profiles"
    private let mountsKey = "com.snake.mounts"
    private let multipartThresholdKey = "com.snake.transfer.multipart-threshold-mb"
    private let multipartConcurrencyKey = "com.snake.transfer.multipart-concurrency"
    private let terminalFontNameKey = "com.snake.terminal.font-name"
    private let terminalFontSizeKey = "com.snake.terminal.font-size"
    private let appearanceKey = "com.snake.appearance.dark"
    private var transferControls: [UUID: CoreTransferControl] = [:]
    private var ephemeralTransferJobIDs: Set<UUID> = []
    private var mountStateMonitor: AnyCancellable?
    private var mountOperations: [UUID: Task<Void, Never>] = [:]
    private(set) var isPreparingToQuit = false

    public init(databaseURL: URL? = nil, userDefaults: UserDefaults = .standard) {
        defaults = userDefaults
        self.isDarkAppearancePreferred = defaults.bool(forKey: appearanceKey)
        let savedThreshold = defaults.integer(forKey: multipartThresholdKey)
        let savedConcurrency = defaults.integer(forKey: multipartConcurrencyKey)
        self.multipartThresholdMB = savedThreshold == 0 ? 50 : min(max(savedThreshold, 1), 10_240)
        self.multipartConcurrency = savedConcurrency == 0 ? 4 : min(max(savedConcurrency, 1), 8)
        self.terminalFontName = defaults.string(forKey: terminalFontNameKey)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName
        let savedFontSize = defaults.double(forKey: terminalFontSizeKey)
        self.terminalFontSize = savedFontSize == 0 ? 13 : min(max(savedFontSize, 9), 32)
        let persistence = try? CorePersistence(databaseURL: databaseURL)
        self.corePersistence = persistence
        let sqliteGroups = (try? persistence?.loadGroups()) ?? []
        let sqliteProfiles = (try? persistence?.loadProfiles()) ?? []
        let legacyGroups = Self.decode([SessionGroup].self, data: defaults.data(forKey: groupsKey))
        let legacyProfiles = Self.decode([SSHProfile].self, data: defaults.data(forKey: profilesKey))
        let restoredGroups = sqliteGroups.isEmpty ? legacyGroups : sqliteGroups
        let restoredProfiles = sqliteProfiles.isEmpty ? legacyProfiles : sqliteProfiles
        let sqliteMounts = (try? persistence?.loadMountMappings()) ?? []
        let legacyMounts = Self.decode([MountMapping].self, data: defaults.data(forKey: mountsKey))
        let restoredMounts = sqliteMounts.isEmpty ? legacyMounts : sqliteMounts
        let persistedTransfers = (try? persistence?.loadTransferJobs()) ?? []
        let obsoleteLocalUploadRecords = persistedTransfers.filter { $0.sourceProfileName == "本机" }
        self.transferJobs = persistedTransfers.filter { $0.sourceProfileName != "本机" }

        self.groups = restoredGroups
        self.profiles = restoredProfiles
        self.mountMappings = restoredMounts
        self.selectedProfileID = restoredProfiles.first?.id
        mountStateMonitor = Timer.publish(every: 3, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.mountMappings.contains(where: { $0.state == .mounted || $0.state == .external }) else { return }
                self.refreshMountStates()
            }
        }
        for job in obsoleteLocalUploadRecords {
            try? persistence?.deleteTransfer(id: job.id)
        }
        if sqliteProfiles.isEmpty && !legacyProfiles.isEmpty {
            persistConfiguration()
            defaults.removeObject(forKey: groupsKey)
            defaults.removeObject(forKey: profilesKey)
            defaults.removeObject(forKey: mountsKey)
        }
        let automaticMappings = mountMappings.filter { $0.autoMount && $0.enabled }.map(\.id)
        if !automaticMappings.isEmpty {
            DispatchQueue.main.async { [weak self] in
                for mappingID in automaticMappings { self?.mount(mappingID: mappingID) }
            }
        }
    }

    public var selectedProfile: SSHProfile? {
        profiles.first(where: { $0.id == selectedProfileID })
    }

    public var multipartThresholdBytes: Int64 {
        Int64(multipartThresholdMB) * 1_024 * 1_024
    }

    public func profiles(in group: SessionGroup) -> [SSHProfile] {
        profiles.filter { $0.groupID == group.id }.sorted { $0.sortOrder < $1.sortOrder }
    }

    public func ungroupedProfiles() -> [SSHProfile] {
        profiles.filter { $0.groupID == nil }.sorted { $0.sortOrder < $1.sortOrder }
    }

    public func group(named name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        groups.append(SessionGroup(name: cleaned, sortOrder: groups.count))
        persistConfiguration()
    }

    public func move(profileID: UUID, to groupID: UUID?) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].groupID = groupID
        profiles[index].sortOrder = profiles.filter { $0.groupID == groupID }.count
        persistConfiguration()
    }

    public func save(profile: SSHProfile, credential: String? = nil) throws {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65535).contains(profile.port) else {
            throw ApplicationStoreError.invalidProfile
        }

        guard !isPreparingToQuit else { throw ApplicationStoreError.invalidProfile }
        var stored = profile
        if let credential, !credential.isEmpty {
            let account = profile.authMethod == .password ? profile.keychainPasswordAccount : profile.keychainPassphraseAccount
            try CredentialStore.save(credential, account: account)
            stored.keychainAccount = account
        }

        var proposedProfiles = profiles
        if let index = proposedProfiles.firstIndex(where: { $0.id == stored.id }) {
            proposedProfiles[index] = stored
        } else {
            proposedProfiles.append(stored)
        }
        let updatedMappings = try preparedMappings(mountMappings, profiles: proposedProfiles)
        let linkChanges = try changeMappingLinks(to: updatedMappings)
        do {
            try corePersistence?.save(stored)
            try corePersistence?.synchronize(mappings: updatedMappings, profiles: proposedProfiles)
        } catch {
            linkChanges.reversed().forEach { $0.rollback() }
            throw error
        }
        linkChanges.forEach { $0.commit() }
        profiles = proposedProfiles
        mountMappings = updatedMappings
        selectedProfileID = stored.id
        persistConfiguration()
    }

    public func delete(profile: SSHProfile) {
        workspaceCoordinator?.closeConnections(profileID: profile.id)
        profiles.removeAll { $0.id == profile.id }
        mountMappings = mountMappings.map { mapping in
            guard mapping.profileID == profile.id else { return mapping }
            var disabled = mapping
            disabled.profileID = nil
            disabled.enabled = false
            disabled.state = .failed
            disabled.lastError = "原 SSH 会话已删除，请重新绑定会话。"
            return disabled
        }
        if selectedProfileID == profile.id {
            selectedProfileID = profiles.first?.id
        }
        Task { @MainActor in
            try? CredentialStore.delete(account: profile.keychainPasswordAccount)
            try? CredentialStore.delete(account: profile.keychainPassphraseAccount)
        }
        ProfileIconStore.delete(for: profile.id)
        persistConfiguration()
    }

    public func openTerminal(_ profile: SSHProfile) {
        workspaceCoordinator?.openTerminal(for: profile)
    }

    public func openSFTP(_ profile: SSHProfile) {
        workspaceCoordinator?.openSFTP(for: profile)
    }

    @discardableResult
    func registerRealUpload(url: URL, to profile: SSHProfile, targetPath: String, totalBytes: Int64) -> UUID {
        let job = TransferJob(
            sourceProfileName: "本机",
            targetProfileName: profile.name,
            sourcePath: url.path,
            targetPath: targetPath,
            totalBytes: max(totalBytes, 1),
            state: .queued
        )
        transferJobs.insert(job, at: 0)
        ephemeralTransferJobIDs.insert(job.id)
        return job.id
    }

    func markTransferRunning(_ id: UUID) {
        updateJob(id) {
            $0.state = .running
            $0.speedBytesPerSecond = 0
            $0.errorMessage = nil
        }
    }

    func markTransferSucceeded(_ id: UUID) {
        updateJob(id) {
            $0.state = .succeeded
            $0.completedBytes = $0.totalBytes
            $0.speedBytesPerSecond = 0
        }
        transferControls.removeValue(forKey: id)
    }

    func markTransferFailed(_ id: UUID, message: String) {
        updateJob(id) {
            $0.state = .failed
            $0.speedBytesPerSecond = 0
            $0.errorMessage = message
        }
        transferControls.removeValue(forKey: id)
    }

    @discardableResult
    func registerRealRemoteCopy(file: RemoteFile, from source: SSHProfile, to destination: SSHProfile, targetPath: String) -> UUID {
        let job = TransferJob(
            sourceProfileName: source.name,
            targetProfileName: destination.name,
            sourcePath: file.path,
            targetPath: targetPath,
            totalBytes: max(file.size, 1),
            state: .queued
        )
        transferJobs.insert(job, at: 0)
        try? corePersistence?.save(job)
        return job.id
    }

    func makeTransferControl(for id: UUID) -> CoreTransferControl {
        let control = CoreTransferControl()
        transferControls[id] = control
        return control
    }

    func prepareTransferRetry(_ id: UUID) {
        updateJob(id) {
            $0.completedBytes = 0
            $0.speedBytesPerSecond = 0
            $0.state = .queued
            $0.errorMessage = nil
        }
    }

    func transferJob(id: UUID) -> TransferJob? {
        transferJobs.first { $0.id == id }
    }

    func updateRealTransferProgress(_ id: UUID, completed: Int64, total: Int64, speed: Int64) {
        updateJob(id) {
            $0.completedBytes = min(max(completed, 0), max(total, 1))
            $0.totalBytes = max(total, 1)
            $0.speedBytesPerSecond = max(speed, 0)
            if $0.state == .queued { $0.state = .running }
        }
    }

    public func pause(jobID: UUID) {
        transferControls[jobID]?.pause()
        updateJob(jobID) { $0.state = .paused; $0.speedBytesPerSecond = 0 }
    }

    public func resume(jobID: UUID) {
        if let control = transferControls[jobID] {
            control.resume()
            updateJob(jobID) { $0.state = .running }
            return
        }
        updateJob(jobID) {
            $0.state = .failed
            $0.errorMessage = "应用重启或连接关闭后需从 SFTP 页面重新发起传输。"
        }
    }

    public func cancel(jobID: UUID) {
        transferControls[jobID]?.cancel()
        updateJob(jobID) { $0.state = .cancelled; $0.speedBytesPerSecond = 0 }
    }

    public func retry(jobID: UUID) {
        updateJob(jobID) {
            $0.state = .failed
            $0.errorMessage = "请回到 SFTP 文件列表重新发起此传输。"
        }
    }

    public func removeCompletedTransfers() {
        let removed = transferJobs.filter { [.succeeded, .cancelled].contains($0.state) }
        transferJobs.removeAll { [.succeeded, .cancelled].contains($0.state) }
        for job in removed {
            ephemeralTransferJobIDs.remove(job.id)
            try? corePersistence?.deleteTransfer(id: job.id)
        }
    }

    public func setAutoMount(_ enabled: Bool, for mappingID: UUID) {
        guard let index = mountMappings.firstIndex(where: { $0.id == mappingID }) else { return }
        mountMappings[index].autoMount = enabled
        persistConfiguration()
    }

    public func save(mapping: MountMapping) throws {
        guard !isPreparingToQuit, mountOperations[mapping.id] == nil else { throw ApplicationStoreError.invalidMapping }
        guard !mapping.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !mapping.remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !mapping.userAccessPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApplicationStoreError.invalidMapping
        }
        var proposed = mountMappings
        if let index = proposed.firstIndex(where: { $0.id == mapping.id }) {
            proposed[index] = mapping
        } else {
            proposed.append(mapping)
        }
        let updated = try preparedMappings(proposed, profiles: profiles)
        let linkChanges = try changeMappingLinks(to: updated)
        do {
            try corePersistence?.synchronize(mappings: updated, profiles: profiles)
        } catch {
            linkChanges.reversed().forEach { $0.rollback() }
            throw error
        }
        linkChanges.forEach { $0.commit() }
        mountMappings = updated
        persistConfiguration()
    }

    private func preparedMappings(_ proposed: [MountMapping], profiles proposedProfiles: [SSHProfile]) throws -> [MountMapping] {
        let mounted = try MountOperations.checkedMountedPaths()
        var identities: Set<String> = []
        return try proposed.map { candidate in
            var mapping = candidate
            let old = mountMappings.first { $0.id == mapping.id }
            guard let profile = proposedProfiles.first(where: { $0.id == mapping.profileID }) else {
                if old == nil { throw ApplicationStoreError.invalidMapping }
                return mapping
            }
            let identity = try ManagedMountPath.make(profile: profile, local: mapping.userAccessPath, remote: mapping.remotePath)
            guard identities.insert(identity).inserted else {
                throw ApplicationStoreError.mappingConflict("已存在相同主机、端口、本地目录和远程目录的映射。")
            }
            if let old, !ManagedMountPath.isStable(old.managedMountPath) {
                mapping.managedMountPath = old.managedMountPath
            } else {
                mapping.managedMountPath = identity
            }
            if let old {
                let oldProfile = profiles.first { $0.id == old.profileID }
                let oldIdentity = try oldProfile.map {
                    try ManagedMountPath.make(profile: $0, local: old.userAccessPath, remote: old.remotePath)
                }
                let changedIdentity = oldIdentity != identity || old.managedMountPath != mapping.managedMountPath
                if changedIdentity {
                    guard mountOperations[old.id] == nil, old.state != .mounting,
                          !mounted.contains(old.managedMountPath) else {
                        throw ApplicationStoreError.mappingConflict("请先安全卸载“\(old.name)”，再修改主机、端口或目录。")
                    }
                    mapping.state = .idle
                    mapping.lastError = nil
                } else {
                    mapping.state = old.state
                    mapping.lastError = old.lastError
                }
            }
            if old == nil || old?.managedMountPath != mapping.managedMountPath {
                try ManagedMountPath.validateTarget(mapping.managedMountPath, mounted: mounted)
            }
            return mapping
        }
    }

    private func changeMappingLinks(to mappings: [MountMapping]) throws -> [MappingLinkChange] {
        var changes: [MappingLinkChange] = []
        do {
            for mapping in mappings {
                if let old = mountMappings.first(where: { $0.id == mapping.id }) {
                    changes.append(try MappingLinkChange(from: old, to: mapping))
                }
            }
            return changes
        } catch {
            changes.reversed().forEach { $0.rollback() }
            throw error
        }
    }

    public func mount(mappingID: UUID) {
        guard !isPreparingToQuit, mountOperations[mappingID] == nil,
              let index = mountMappings.firstIndex(where: { $0.id == mappingID }),
              mountMappings[index].enabled,
              mountMappings[index].state != .mounting,
              mountMappings[index].state != .mounted,
              let profileID = mountMappings[index].profileID,
              let profile = profiles.first(where: { $0.id == profileID }) else { return }
        mountMappings[index].state = .mounting
        mountMappings[index].lastError = nil
        let mapping = mountMappings[index]
        persistConfiguration()
        mountOperations[mappingID] = Task {
            defer { self.mountOperations.removeValue(forKey: mappingID) }
            let result = await Task.detached(priority: .userInitiated) {
                MountOperations.mount(mapping: mapping, profile: profile)
            }.value
            guard let resultIndex = self.mountMappings.firstIndex(where: { $0.id == mappingID }) else { return }
            self.mountMappings[resultIndex].state = result.state
            self.mountMappings[resultIndex].lastError = result.message
            self.persistConfiguration()
        }
    }

    public func unmount(mappingID: UUID) {
        guard !isPreparingToQuit, mountOperations[mappingID] == nil,
              let index = mountMappings.firstIndex(where: { $0.id == mappingID }) else { return }
        let mapping = mountMappings[index]
        mountMappings[index].state = .mounting
        mountOperations[mappingID] = Task {
            defer { self.mountOperations.removeValue(forKey: mappingID) }
            let result = await Task.detached(priority: .userInitiated) {
                MountOperations.unmount(mapping: mapping)
            }.value
            guard let resultIndex = self.mountMappings.firstIndex(where: { $0.id == mappingID }) else { return }
            self.mountMappings[resultIndex].state = result.state
            self.mountMappings[resultIndex].lastError = result.message
            self.persistConfiguration()
        }
    }

    public func reveal(mappingID: UUID) {
        guard let mapping = mountMappings.first(where: { $0.id == mappingID }) else { return }
        Task {
            do { try await MountOperations.reveal(mapping: mapping) }
            catch { mountActionError = "无法打开“\(mapping.name)”：\(error.localizedDescription)" }
        }
    }

    public func deleteMapping(mappingID: UUID) {
        guard !isPreparingToQuit else { return }
        guard let index = mountMappings.firstIndex(where: { $0.id == mappingID }) else { return }
        guard mountOperations[mappingID] == nil, mountMappings[index].state != .mounting else {
            mountActionError = "“\(mountMappings[index].name)”正在执行挂载或卸载操作，请稍后再删除。"
            return
        }
        let mapping = mountMappings[index]
        mountMappings[index].state = .mounting
        mountActionError = nil
        mountOperations[mappingID] = Task {
            defer { mountOperations.removeValue(forKey: mappingID) }
            let result = await Task.detached(priority: .userInitiated) {
                MountOperations.removeMappingEntry(mapping)
            }.value
            guard let index = mountMappings.firstIndex(where: { $0.id == mappingID }) else { return }
            guard result.state == .idle else {
                mountMappings[index].state = .failed
                mountMappings[index].lastError = result.message
                mountActionError = "无法删除“\(mapping.name)”：\(result.message ?? "安全卸载失败。")"
                persistConfiguration()
                return
            }
            do {
                try corePersistence?.deleteMapping(id: mappingID)
                mountMappings.removeAll { $0.id == mappingID }
                // Prevent an empty SQLite mapping list from restoring legacy mappings.
                defaults.removeObject(forKey: mountsKey)
                persistConfiguration()
            } catch {
                mountMappings[index].state = .idle
                mountActionError = "无法删除映射配置：\(error.localizedDescription)"
            }
        }
    }

    public func refreshMountStates() {
        guard !isPreparingToQuit else { return }
        let mappings = mountMappings
        Task {
            let mounted = await Task.detached(priority: .utility) { MountOperations.mountedPaths() }.value
            guard !isPreparingToQuit else { return }
            var changed = false
            for mapping in mappings {
                guard let index = mountMappings.firstIndex(where: { $0.id == mapping.id }) else { continue }
                guard mountMappings[index].state != .mounting else { continue }
                let previous = mountMappings[index]
                if mounted.contains(mapping.managedMountPath) {
                    mountMappings[index].state = mountMappings[index].state == .mounted ? .mounted : .external
                    mountMappings[index].lastError = nil
                } else if mountMappings[index].state == .mounted || mountMappings[index].state == .external {
                    mountMappings[index].state = .idle
                    mountMappings[index].lastError = "磁盘已卸载或挂载进程已退出，请重新挂载。"
                }
                changed = changed || previous != mountMappings[index]
            }
            if changed { persistConfiguration() }
        }
    }

    /// Block new mount operations, finish in-flight work, then safely unmount
    /// actual registered mounts, including mounts restored from a previous run.
    func prepareForTermination(
        mountedPaths: @escaping @Sendable () throws -> Set<String> = MountOperations.checkedMountedPaths,
        unmount: @escaping @Sendable (MountMapping) -> MountOperationResult = { MountOperations.unmount(mapping: $0) }
    ) async -> [String] {
        isPreparingToQuit = true
        for operation in Array(mountOperations.values) { await operation.value }
        let mappings = mountMappings
        let connections = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.name) })
        let results = await Task.detached(priority: .userInitiated) {
            var failures: [String] = []
            var failedIDs: Set<UUID> = []
            var removed: Set<UUID> = []
            func describe(_ mapping: MountMapping, reason: String) -> String {
                let connection = mapping.profileID.flatMap { connections[$0] } ?? "未绑定连接"
                return "\(mapping.name) · \(connection)\n远程目录：\(mapping.remotePath)\n本地目录：\(mapping.userAccessPath)\n挂载点：\(mapping.managedMountPath)\n原因：\(reason)"
            }
            do {
                let mounted = try mountedPaths()
                for mapping in mappings where mounted.contains(mapping.managedMountPath) {
                    guard MountOperations.isManagedMountPath(mapping.managedMountPath) else {
                        failedIDs.insert(mapping.id)
                        failures.append(describe(mapping, reason: "挂载点不在 Snake 受管目录中。"))
                        continue
                    }
                    let result = unmount(mapping)
                    if result.state == .idle { removed.insert(mapping.id) }
                    else {
                        failedIDs.insert(mapping.id)
                        failures.append(describe(mapping, reason: result.message ?? "无法安全卸载，目录可能正被占用。"))
                    }
                }
                let remaining = try mountedPaths()
                for mapping in mappings where remaining.contains(mapping.managedMountPath) {
                    removed.remove(mapping.id)
                    if !failedIDs.contains(mapping.id) {
                        failures.append(describe(mapping, reason: "磁盘仍处于挂载状态。"))
                    }
                }
            } catch {
                failures.append("无法确认系统挂载状态：\(error.localizedDescription)")
            }
            return (removed, failures)
        }.value
        for index in mountMappings.indices where results.0.contains(mountMappings[index].id) {
            mountMappings[index].state = .idle
            mountMappings[index].lastError = nil
        }
        persistConfiguration()
        if !results.1.isEmpty { isPreparingToQuit = false }
        return results.1
    }

    private func updateJob(_ id: UUID, update: (inout TransferJob) -> Void) {
        guard let index = transferJobs.firstIndex(where: { $0.id == id }) else { return }
        update(&transferJobs[index])
        if !ephemeralTransferJobIDs.contains(id) {
            try? corePersistence?.save(transferJobs[index])
        }
    }

    private func persistConfiguration() {
        try? corePersistence?.synchronize(groups: groups, profiles: profiles)
        try? corePersistence?.synchronize(mappings: mountMappings, profiles: profiles)
    }

    private static func decode<T: Decodable>(_ type: T.Type, data: Data?) -> T {
        guard let data, let value = try? JSONDecoder().decode(T.self, from: data) else {
            if let empty = [] as? T { return empty }
            fatalError("Unable to create an empty configuration value")
        }
        return value
    }
}

public enum ApplicationStoreError: LocalizedError {
    case invalidProfile
    case invalidMapping
    case mappingConflict(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProfile: "请填写名称、主机、端口和用户名。"
        case .invalidMapping: "请填写映射名称、远程目录和本地访问目录。"
        case .mappingConflict(let message): message
        }
    }
}
