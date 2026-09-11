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

        var stored = profile
        if let credential, !credential.isEmpty {
            let account = profile.authMethod == .password ? profile.keychainPasswordAccount : profile.keychainPassphraseAccount
            try CredentialStore.save(credential, account: account)
            stored.keychainAccount = account
        }

        if let index = profiles.firstIndex(where: { $0.id == stored.id }) {
            profiles[index] = stored
        } else {
            profiles.append(stored)
        }
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
        guard !mapping.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !mapping.remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !mapping.userAccessPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApplicationStoreError.invalidMapping
        }
        if let index = mountMappings.firstIndex(where: { $0.id == mapping.id }) {
            mountMappings[index] = mapping
        } else {
            mountMappings.append(mapping)
        }
        persistConfiguration()
    }

    public func mount(mappingID: UUID) {
        guard let index = mountMappings.firstIndex(where: { $0.id == mappingID }),
              mountMappings[index].enabled,
              mountMappings[index].state != .mounting,
              mountMappings[index].state != .mounted,
              let profileID = mountMappings[index].profileID,
              let profile = profiles.first(where: { $0.id == profileID }) else { return }
        mountMappings[index].state = .mounting
        mountMappings[index].lastError = nil
        let mapping = mountMappings[index]
        persistConfiguration()
        Task {
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
        guard let index = mountMappings.firstIndex(where: { $0.id == mappingID }) else { return }
        let mapping = mountMappings[index]
        mountMappings[index].state = .mounting
        Task {
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
        MountOperations.reveal(mapping: mapping)
    }

    public func refreshMountStates() {
        let mappings = mountMappings
        Task {
            let mounted = await Task.detached(priority: .utility) { MountOperations.mountedPaths() }.value
            for mapping in mappings {
                guard let index = mountMappings.firstIndex(where: { $0.id == mapping.id }) else { continue }
                if mounted.contains(mapping.managedMountPath) {
                    mountMappings[index].state = mapping.state == .mounted ? .mounted : .external
                    mountMappings[index].lastError = nil
                } else if mapping.state == .mounted || mapping.state == .external || mapping.state == .mounting {
                    mountMappings[index].state = .idle
                }
            }
            persistConfiguration()
        }
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

    public var errorDescription: String? {
        switch self {
        case .invalidProfile: "请填写名称、主机、端口和用户名。"
        case .invalidMapping: "请填写映射名称、远程目录和本地访问目录。"
        }
    }
}
