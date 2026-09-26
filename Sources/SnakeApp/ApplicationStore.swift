import AppKit
import Foundation
import Combine
import SnakeCoreBindings

@MainActor
public final class ApplicationStore: ObservableObject {
    public static let shared = ApplicationStore()

    @Published public private(set) var groups: [SessionGroup]
    @Published public private(set) var profiles: [SSHProfile]
    @Published public private(set) var savedPasswords: [SavedPassword]
    @Published public private(set) var transferJobs: [TransferJob]
    @Published public private(set) var mountMappings: [MountMapping]
    @Published var mountActionError: String?
    @Published public var selectedProfileID: UUID?
    @Published public var isDarkAppearancePreferred: Bool {
        didSet { defaults.set(isDarkAppearancePreferred, forKey: appearanceKey) }
    }
    @Published public var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: appLanguageKey)
            LocalizationStore.shared.setLanguage(appLanguage)
            workspaceCoordinator?.applyLocalization()
        }
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
    /// Ceiling on transfer connections to one host, shared by every window and tab.
    @Published public var hostConcurrencyLimit: Int {
        didSet {
            let value = HostTransferBudget.clamp(hostConcurrencyLimit)
            if value != hostConcurrencyLimit { hostConcurrencyLimit = value; return }
            defaults.set(value, forKey: hostConcurrencyKey)
            HostTransferBudget.shared.setLimit(value)
        }
    }
    /// Bookmarked folder used when opening a remote file; `nil` means the system cache.
    @Published public var remoteOpenDirectoryBookmark: Data? {
        didSet { persistRemoteOpenLocation() }
    }
    /// Resolved location, for display in Settings.
    @Published public private(set) var remoteOpenDirectoryPath: String = ""
    @Published public var remoteOpenCleanupPolicy: RemoteOpenCleanupPolicy {
        didSet { defaults.set(remoteOpenCleanupPolicy.rawValue, forKey: remoteOpenRetentionKey) }
    }
    @Published public var remoteOpenSizeLimit: RemoteOpenSizeLimit {
        didSet { defaults.set(remoteOpenSizeLimit.rawValue, forKey: remoteOpenSizeLimitKey) }
    }
    /// Set when a stored folder could not be resolved and the default is in use.
    @Published public private(set) var remoteOpenCacheNotice: String?
    @Published public var terminalFontName: String {
        didSet { defaults.set(terminalFontName, forKey: terminalFontNameKey) }
    }
    @Published var selectedTerminalThemeID: String {
        didSet { defaults.set(selectedTerminalThemeID, forKey: terminalThemeKey) }
    }
    @Published private(set) var importedTerminalThemes: [ImportedTerminalTheme]
    @Published var terminalThemeNotice: String?
    var terminalThemePreset: TerminalThemePreset {
        get { TerminalThemePreset(rawValue: selectedTerminalThemeID) ?? .tokyoNight }
        set { selectedTerminalThemeID = newValue.rawValue }
    }
    @Published var terminalLogHighlightEnabled: Bool {
        didSet { defaults.set(terminalLogHighlightEnabled, forKey: terminalHighlightKey) }
    }
    @Published var terminalFieldHighlightEnabled: Bool {
        didSet { defaults.set(terminalFieldHighlightEnabled, forKey: terminalFieldHighlightKey) }
    }
    @Published public var terminalFontSize: Double {
        didSet {
            let value = min(max(terminalFontSize, 9), 32)
            if value != terminalFontSize { terminalFontSize = value; return }
            defaults.set(value, forKey: terminalFontSizeKey)
        }
    }
    @Published private(set) var sftpSearchShortcut: SFTPShortcut {
        didSet { persist(shortcut: sftpSearchShortcut, key: sftpSearchShortcutKey) }
    }
    @Published private(set) var sftpDeleteShortcut: SFTPShortcut {
        didSet { persist(shortcut: sftpDeleteShortcut, key: sftpDeleteShortcutKey) }
    }
    @Published private(set) var sftpUploadShortcut: SFTPShortcut {
        didSet { persist(shortcut: sftpUploadShortcut, key: sftpUploadShortcutKey) }
    }
    @Published private(set) var newSessionTabShortcut: SFTPShortcut {
        didSet { persist(shortcut: newSessionTabShortcut, key: newSessionTabShortcutKey) }
    }

    weak var workspaceCoordinator: WorkspaceWindowCoordinator?

    private let defaults: UserDefaults
    private let corePersistence: CorePersistence?
    private let groupsKey = "com.snake.groups"
    private let profilesKey = "com.snake.profiles"
    private let mountsKey = "com.snake.mounts"
    private let multipartThresholdKey = "com.snake.transfer.multipart-threshold-mb"
    private let multipartConcurrencyKey = "com.snake.transfer.multipart-concurrency"
    private let hostConcurrencyKey = "com.snake.transfer.host-concurrency"
    private let remoteOpenDirectoryKey = "com.snake.transfer.remote-open-directory"
    private let remoteOpenRetentionKey = "com.snake.transfer.remote-open-retention"
    private let remoteOpenSizeLimitKey = "com.snake.transfer.remote-open-size-limit"
    private let terminalFontNameKey = "com.snake.terminal.font-name"
    private let terminalFontSizeKey = "com.snake.terminal.font-size"
    private let terminalThemeKey = "com.snake.terminal.theme"
    private let terminalHighlightKey = "com.snake.terminal.log-highlight"
    private let terminalFieldHighlightKey = "com.snake.terminal.field-highlight"
    private let terminalThemeLibrary: TerminalThemeLibrary
    private let tokyoMigrationKey = "com.snake.terminal.tokyo-migration-v1"
    private let appearanceKey = "com.snake.appearance.dark"
    private let appLanguageKey = "com.snake.appearance.language"
    private let sftpSearchShortcutKey = "com.snake.shortcuts.sftp-search"
    private let sftpDeleteShortcutKey = "com.snake.shortcuts.sftp-delete"
    private let sftpUploadShortcutKey = "com.snake.shortcuts.sftp-upload"
    private let newSessionTabShortcutKey = "com.snake.shortcuts.new-session-tab"
    private var transferControls: [UUID: CoreTransferControl] = [:]
    private var ephemeralTransferJobIDs: Set<UUID> = []
    private var mountStateMonitor: AnyCancellable?
    private var mountOperations: [UUID: Task<Void, Never>] = [:]
    private(set) var isPreparingToQuit = false

    public init(databaseURL: URL? = nil, userDefaults: UserDefaults = .standard,
                terminalThemeDirectoryURL: URL? = nil) {
        defaults = userDefaults
        let themeLibrary = TerminalThemeLibrary(directoryURL: terminalThemeDirectoryURL)
        terminalThemeLibrary = themeLibrary
        let loadedThemes = themeLibrary.load()
        importedTerminalThemes = loadedThemes
        self.isDarkAppearancePreferred = defaults.bool(forKey: appearanceKey)
        let initialLanguage = AppLanguage(rawValue: defaults.string(forKey: appLanguageKey) ?? "") ?? .system
        self.appLanguage = initialLanguage
        LocalizationStore.shared.setLanguage(initialLanguage)
        if !defaults.bool(forKey: tokyoMigrationKey) {
            if defaults.string(forKey: terminalThemeKey) == nil {
                defaults.set(TerminalThemePreset.tokyoNight.rawValue, forKey: terminalThemeKey)
            }
            defaults.set(true, forKey: tokyoMigrationKey)
        }
        let savedThemeID = defaults.string(forKey: terminalThemeKey) ?? TerminalThemePreset.tokyoNight.rawValue
        if TerminalThemePreset(rawValue: savedThemeID) != nil || loadedThemes.contains(where: { $0.selectionID == savedThemeID }) {
            self.selectedTerminalThemeID = savedThemeID
        } else {
            self.selectedTerminalThemeID = TerminalThemePreset.tokyoNight.rawValue
            self.terminalThemeNotice = L10n.text("已导入主题不可用，已恢复 Tokyo Night。")
            defaults.set(TerminalThemePreset.tokyoNight.rawValue, forKey: terminalThemeKey)
        }
        self.terminalLogHighlightEnabled = defaults.object(forKey: terminalHighlightKey) == nil
            ? true : defaults.bool(forKey: terminalHighlightKey)
        self.terminalFieldHighlightEnabled = defaults.object(forKey: terminalFieldHighlightKey) == nil
            ? true : defaults.bool(forKey: terminalFieldHighlightKey)
        let savedThreshold = defaults.integer(forKey: multipartThresholdKey)
        let savedConcurrency = defaults.integer(forKey: multipartConcurrencyKey)
        self.multipartThresholdMB = savedThreshold == 0 ? 50 : min(max(savedThreshold, 1), 10_240)
        self.multipartConcurrency = savedConcurrency == 0 ? 4 : min(max(savedConcurrency, 1), 8)
        let storedHostLimit = defaults.object(forKey: hostConcurrencyKey) as? Int
        let hostLimit = storedHostLimit.flatMap { HostTransferBudget.allowedLimits.contains($0) ? $0 : nil }
            ?? HostTransferBudget.defaultLimit
        self.hostConcurrencyLimit = hostLimit
        HostTransferBudget.shared.setLimit(hostLimit)
        let storedBookmark = defaults.data(forKey: remoteOpenDirectoryKey)
        let openLocation = RemoteOpenCache.location(bookmark: storedBookmark, accessScope: false)
        self.remoteOpenDirectoryBookmark = storedBookmark
        self.remoteOpenDirectoryPath = openLocation.url.path
        self.remoteOpenCacheNotice = openLocation.fellBackFromBookmark
            ? L10n.text("所选目录不可用，已恢复默认位置。") : nil
        self.remoteOpenCleanupPolicy = defaults.object(forKey: remoteOpenRetentionKey) == nil
            ? .sevenDays
            : (RemoteOpenCleanupPolicy(rawValue: defaults.integer(forKey: remoteOpenRetentionKey)) ?? .sevenDays)
        self.remoteOpenSizeLimit = defaults.object(forKey: remoteOpenSizeLimitKey) == nil
            ? .mb500
            : (RemoteOpenSizeLimit(rawValue: defaults.integer(forKey: remoteOpenSizeLimitKey)) ?? .mb500)
        self.terminalFontName = defaults.string(forKey: terminalFontNameKey)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName
        let savedFontSize = defaults.double(forKey: terminalFontSizeKey)
        self.terminalFontSize = savedFontSize == 0 ? 13 : min(max(savedFontSize, 9), 32)
        let defaultSFTPShortcuts = Dictionary(uniqueKeysWithValues:
            SFTPShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
        let savedNewTab = Self.loadShortcut(from: defaults, key: newSessionTabShortcutKey,
            fallback: WorkspaceShortcutPolicy.defaultNewTab)
        let newTabShortcut = WorkspaceShortcutPolicy.validationError(
            savedNewTab, sftpShortcuts: defaultSFTPShortcuts) == nil
            ? savedNewTab : WorkspaceShortcutPolicy.defaultNewTab
        self.newSessionTabShortcut = newTabShortcut
        let loadedShortcuts = Self.loadSFTPShortcuts(
            from: defaults,
            keys: [.search: sftpSearchShortcutKey, .delete: sftpDeleteShortcutKey, .uploadFile: sftpUploadShortcutKey],
            workspaceShortcut: newTabShortcut
        )
        self.sftpSearchShortcut = loadedShortcuts[.search]!
        self.sftpDeleteShortcut = loadedShortcuts[.delete]!
        self.sftpUploadShortcut = loadedShortcuts[.uploadFile]!
        let persistence = try? CorePersistence(databaseURL: databaseURL)
        self.corePersistence = persistence
        let sqliteGroups = (try? persistence?.loadGroups()) ?? []
        let sqliteProfiles = (try? persistence?.loadProfiles()) ?? []
        let sqliteSavedPasswords = (try? persistence?.loadSavedPasswords()) ?? []
        let legacyGroups = Self.decode([SessionGroup].self, data: defaults.data(forKey: groupsKey))
        let legacyProfiles = Self.decode([SSHProfile].self, data: defaults.data(forKey: profilesKey))
        let restoredGroups = sqliteGroups.isEmpty ? legacyGroups : sqliteGroups
        let restoredProfiles = sqliteProfiles.isEmpty ? legacyProfiles : sqliteProfiles
        let sqliteMounts = (try? persistence?.loadMountMappings()) ?? []
        let legacyMounts = Self.decode([MountMapping].self, data: defaults.data(forKey: mountsKey))
        let restoredMounts = sqliteMounts.isEmpty ? legacyMounts : sqliteMounts
        let persistedTransfers = (try? persistence?.loadTransferJobs()) ?? []
        let obsoleteLocalUploadRecords = persistedTransfers.filter { $0.sourceProfileName == TransferJob.localEndpointName }
        self.transferJobs = persistedTransfers.filter { $0.sourceProfileName != TransferJob.localEndpointName }

        self.groups = restoredGroups
        self.profiles = restoredProfiles
        self.savedPasswords = sqliteSavedPasswords
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

    var sftpShortcuts: [SFTPShortcutAction: SFTPShortcut] {
        [
            .search: sftpSearchShortcut,
            .delete: sftpDeleteShortcut,
            .uploadFile: sftpUploadShortcut
        ]
    }

    @discardableResult
    func updateSFTPShortcut(_ action: SFTPShortcutAction, shortcut: SFTPShortcut) -> String? {
        if let error = SFTPShortcutPolicy.validationError(action: action, shortcut: shortcut,
            configured: sftpShortcuts, workspaceShortcut: newSessionTabShortcut) {
            return error
        }
        switch action {
        case .search: sftpSearchShortcut = shortcut
        case .delete: sftpDeleteShortcut = shortcut
        case .uploadFile: sftpUploadShortcut = shortcut
        }
        workspaceCoordinator?.refreshApplicationCommands()
        return nil
    }

    @discardableResult
    func updateNewSessionTabShortcut(_ shortcut: SFTPShortcut) -> String? {
        if let error = WorkspaceShortcutPolicy.validationError(shortcut, sftpShortcuts: sftpShortcuts) {
            return error
        }
        newSessionTabShortcut = shortcut
        workspaceCoordinator?.refreshApplicationCommands()
        return nil
    }

    func resetAllShortcuts() {
        newSessionTabShortcut = WorkspaceShortcutPolicy.defaultNewTab
        resetSFTPShortcuts()
    }

    func resetSFTPShortcuts() {
        sftpSearchShortcut = SFTPShortcutAction.search.defaultShortcut
        sftpDeleteShortcut = SFTPShortcutAction.delete.defaultShortcut
        sftpUploadShortcut = SFTPShortcutAction.uploadFile.defaultShortcut
        workspaceCoordinator?.refreshApplicationCommands()
    }

    private func persist(shortcut: SFTPShortcut, key: String) {
        if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: key) }
    }

    private static func loadShortcut(from defaults: UserDefaults, key: String, fallback: SFTPShortcut) -> SFTPShortcut {
        guard let data = defaults.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(SFTPShortcut.self, from: data) else { return fallback }
        return shortcut
    }

    private static func loadSFTPShortcuts(
        from defaults: UserDefaults,
        keys: [SFTPShortcutAction: String],
        workspaceShortcut: SFTPShortcut
    ) -> [SFTPShortcutAction: SFTPShortcut] {
        var result = Dictionary(uniqueKeysWithValues: SFTPShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
        for action in SFTPShortcutAction.allCases {
            let candidate = loadShortcut(from: defaults, key: keys[action]!, fallback: action.defaultShortcut)
            if SFTPShortcutPolicy.validationError(action: action, shortcut: candidate,
                configured: result, workspaceShortcut: workspaceShortcut) == nil {
                result[action] = candidate
            }
        }
        return result
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

    public func save(profile: SSHProfile, credential: String? = nil, fromSavedPassword sourceID: UUID? = nil) throws {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65535).contains(profile.port) else {
            throw ApplicationStoreError.invalidProfile
        }

        guard !isPreparingToQuit else { throw ApplicationStoreError.invalidProfile }
        var stored = profile
        var credentialToSave = credential
        if let sourceID {
            guard profile.authMethod == .password,
                  let source = savedPasswords.first(where: { $0.id == sourceID }),
                  let data = try CredentialStore.readData(account: source.credentialAccount),
                  let secret = String(data: data, encoding: .utf8) else {
                throw ApplicationStoreError.savedPasswordUnavailable
            }
            stored.username = source.username
            stored.savedPasswordID = sourceID
            credentialToSave = secret
        } else if let previous = profiles.first(where: { $0.id == profile.id }),
                  previous.savedPasswordID != nil,
                  (profile.username != previous.username || credential?.isEmpty == false || profile.authMethod != .password) {
            stored.savedPasswordID = nil
        }
        var credentialChanges: [CredentialChange] = []
        if let credential = credentialToSave, !credential.isEmpty {
            let account = profile.authMethod == .password ? profile.keychainPasswordAccount : profile.keychainPassphraseAccount
            stored.keychainAccount = account
            credentialChanges.append(CredentialChange(account: account, secret: credential))
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
            try CredentialStore.withChanges(credentialChanges) {
                try corePersistence?.save(stored)
                try corePersistence?.synchronize(mappings: updatedMappings, profiles: proposedProfiles)
            }
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

    func linkedProfiles(for savedPasswordID: UUID) -> [SSHProfile] {
        profiles.filter { $0.authMethod == .password && $0.savedPasswordID == savedPasswordID }
    }

    /// Returns IDs skipped because the profile was deleted, changed authentication,
    /// or unlinked before the save was committed.
    @discardableResult
    func saveSavedPassword(_ record: SavedPassword, password: String?, selectedProfileIDs: Set<UUID>) throws -> [UUID] {
        guard !record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let persistence = corePersistence else { throw ApplicationStoreError.invalidSavedPassword }
        let old = savedPasswords.first(where: { $0.id == record.id })
        if old == nil && (password?.isEmpty ?? true) { throw ApplicationStoreError.invalidSavedPassword }
        let usernameChanged = old?.username != record.username
        let passwordChanged = password != nil && !(password?.isEmpty ?? true)
        let eligible = linkedProfiles(for: record.id).filter { selectedProfileIDs.contains($0.id) }
        let skipped = selectedProfileIDs.subtracting(Set(eligible.map(\.id)))
        var changes: [CredentialChange] = []
        if passwordChanged, let password {
            changes.append(CredentialChange(account: record.credentialAccount, secret: password))
            changes += eligible.map { CredentialChange(account: $0.keychainPasswordAccount, secret: password) }
        }
        let updated = try CredentialStore.withChanges(changes) {
            let updated = try persistence.save(record, selectedProfileIDs: eligible.map(\.id), syncUsername: usernameChanged)
            guard Set(updated) == Set(eligible.map(\.id)) else { throw ApplicationStoreError.savedPasswordSyncChanged }
            return updated
        }
        if let index = savedPasswords.firstIndex(where: { $0.id == record.id }) { savedPasswords[index] = record }
        else { savedPasswords.append(record) }
        if usernameChanged {
            for id in updated {
                if let index = profiles.firstIndex(where: { $0.id == id }) { profiles[index].username = record.username }
            }
        }
        return Array(skipped)
    }

    func deleteSavedPassword(_ record: SavedPassword) throws {
        guard let persistence = corePersistence else { throw ApplicationStoreError.invalidSavedPassword }
        try CredentialStore.withChanges([CredentialChange(account: record.credentialAccount, secret: nil)]) {
            try persistence.deleteSavedPassword(id: record.id)
        }
        savedPasswords.removeAll { $0.id == record.id }
        for index in profiles.indices where profiles[index].savedPasswordID == record.id {
            profiles[index].savedPasswordID = nil
        }
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
            disabled.lastError = L10n.text("原 SSH 会话已删除，请重新绑定会话。")
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
        cleanRemoteOpenCache(for: profile.id)
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
            sourceProfileName: TransferJob.localEndpointName,
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

    func registerRealDownload(profile: SSHProfile, remotePath: String, localURL: URL, size: Int64) -> UUID {
        let job = TransferJob(sourceProfileName: profile.name, targetProfileName: TransferJob.localEndpointName,
                              sourcePath: remotePath, targetPath: localURL.path, totalBytes: max(1, size))
        transferJobs.insert(job, at: 0)
        ephemeralTransferJobIDs.insert(job.id)
        return job.id
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
            $0.errorMessage = L10n.text("应用重启或连接关闭后需从 SFTP 页面重新发起传输。")
        }
    }

    public func cancel(jobID: UUID) {
        transferControls[jobID]?.cancel()
        updateJob(jobID) { $0.state = .cancelled; $0.speedBytesPerSecond = 0 }
    }

    public func retry(jobID: UUID) {
        updateJob(jobID) {
            $0.state = .failed
            $0.errorMessage = L10n.text("请回到 SFTP 文件列表重新发起此传输。")
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

    // MARK: - Open-remote-file cache

    /// Settings the SFTP "open remote file" path needs to locate and trim its cache.
    public var remoteOpenCacheConfiguration: RemoteOpenCacheConfiguration {
        RemoteOpenCacheConfiguration(
            directoryBookmark: remoteOpenDirectoryBookmark,
            policy: remoteOpenCleanupPolicy,
            sizeLimit: remoteOpenSizeLimit
        )
    }

    /// Stores a folder for opened remote files; `nil` restores the system cache location.
    ///
    /// Returns a localized error message when the folder cannot be used, otherwise `nil`.
    @discardableResult
    public func setRemoteOpenDirectory(_ url: URL?) -> String? {
        let previous = RemoteOpenCache.location(bookmark: remoteOpenDirectoryBookmark, accessScope: false)
        if let url {
            do {
                try RemoteOpenCache.prepare(directory: url, owned: false)
            } catch {
                return L10n.format("无法写入所选目录：%@", error.localizedDescription)
            }
            guard let bookmark = try? RemoteOpenCache.bookmark(for: url) else {
                return L10n.format("无法写入所选目录：%@", url.path)
            }
            remoteOpenDirectoryBookmark = bookmark
        } else {
            remoteOpenDirectoryBookmark = nil
        }
        // The folder we just left is no longer reachable from Settings; trim it once so
        // its files do not sit there forever.
        let current = RemoteOpenCache.location(bookmark: remoteOpenDirectoryBookmark, accessScope: false)
        if previous.url != current.url {
            let policy = remoteOpenCleanupPolicy
            let limit = remoteOpenSizeLimit
            Task.detached(priority: .utility) {
                try? RemoteOpenCache.prune(root: previous.url, policy: policy, sizeLimit: limit)
            }
        }
        return nil
    }

    /// Current cache usage, or `nil` when the location cannot be read.
    public func remoteOpenCacheUsage() async -> RemoteOpenCacheReport? {
        let bookmark = remoteOpenDirectoryBookmark
        return await Task.detached(priority: .utility) {
            let location = RemoteOpenCache.location(bookmark: bookmark, accessScope: true)
            defer { if location.scoped { location.url.stopAccessingSecurityScopedResource() } }
            return try? RemoteOpenCache.usage(root: location.url)
        }.value
    }

    /// Removes every cached copy this app created, leaving the rest of the folder alone.
    public func clearRemoteOpenCache() async -> RemoteOpenCacheReport? {
        let bookmark = remoteOpenDirectoryBookmark
        return await Task.detached(priority: .utility) {
            let location = RemoteOpenCache.location(bookmark: bookmark, accessScope: true)
            defer { if location.scoped { location.url.stopAccessingSecurityScopedResource() } }
            return try? RemoteOpenCache.clear(root: location.url)
        }.value
    }

    /// Applies the retention and size policy without user interaction (launch, or before a write).
    @discardableResult
    public func pruneRemoteOpenCache() async -> RemoteOpenCacheReport? {
        let bookmark = remoteOpenDirectoryBookmark
        let policy = remoteOpenCleanupPolicy
        let limit = remoteOpenSizeLimit
        return await Task.detached(priority: .utility) {
            let location = RemoteOpenCache.location(bookmark: bookmark, accessScope: true)
            defer { if location.scoped { location.url.stopAccessingSecurityScopedResource() } }
            return try? RemoteOpenCache.prune(root: location.url, policy: policy, sizeLimit: limit)
        }.value
    }

    private func persistRemoteOpenLocation() {
        if let bookmark = remoteOpenDirectoryBookmark {
            defaults.set(bookmark, forKey: remoteOpenDirectoryKey)
        } else {
            defaults.removeObject(forKey: remoteOpenDirectoryKey)
        }
        let location = RemoteOpenCache.location(bookmark: remoteOpenDirectoryBookmark, accessScope: false)
        remoteOpenDirectoryPath = location.url.path
        remoteOpenCacheNotice = location.fellBackFromBookmark
            ? L10n.text("所选目录不可用，已恢复默认位置。") : nil
    }

    /// Clears the copies cached for a deleted session.
    ///
    /// Only entries this app created are removed, and the session folder is dropped only
    /// once it ends up empty: the cache can live in a folder the user chose, so deleting a
    /// session must never take unrelated files with it.
    private func cleanRemoteOpenCache(for profileID: UUID) {
        let bookmark = remoteOpenDirectoryBookmark
        Task.detached(priority: .utility) {
            let location = RemoteOpenCache.location(bookmark: bookmark, accessScope: true)
            defer { if location.scoped { location.url.stopAccessingSecurityScopedResource() } }
            RemoteOpenCache.removeProfileDirectory(root: location.url, profileID: profileID)
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
                throw ApplicationStoreError.mappingConflict(L10n.text("已存在相同主机、端口、本地目录和远程目录的映射。"))
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
                        throw ApplicationStoreError.mappingConflict(L10n.format("请先安全卸载“%@”，再修改主机、端口或目录。", old.name))
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
            catch { mountActionError = L10n.format("无法打开“%@”：%@", mapping.name, error.localizedDescription) }
        }
    }

    public func deleteMapping(mappingID: UUID) {
        guard !isPreparingToQuit else { return }
        guard let index = mountMappings.firstIndex(where: { $0.id == mappingID }) else { return }
        guard mountOperations[mappingID] == nil, mountMappings[index].state != .mounting else {
            mountActionError = L10n.format("“%@”正在执行挂载或卸载操作，请稍后再删除。", mountMappings[index].name)
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
                mountActionError = L10n.format("无法删除“%@”：%@", mapping.name, result.message ?? L10n.text("安全卸载失败。"))
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
                mountActionError = L10n.format("无法删除映射配置：%@", error.localizedDescription)
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
                    mountMappings[index].lastError = L10n.text("磁盘已卸载或挂载进程已退出，请重新挂载。")
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
                let connection = mapping.profileID.flatMap { connections[$0] } ?? L10n.text("未绑定连接")
                return L10n.format("%@ · %@\n远程目录：%@\n本地目录：%@\n挂载点：%@\n原因：%@",
            mapping.name, connection, mapping.remotePath, mapping.userAccessPath, mapping.managedMountPath, reason)
            }
            do {
                let mounted = try mountedPaths()
                for mapping in mappings where mounted.contains(mapping.managedMountPath) {
                    guard MountOperations.isManagedMountPath(mapping.managedMountPath) else {
                        failedIDs.insert(mapping.id)
                        failures.append(describe(mapping, reason: L10n.text("挂载点不在 Snake 受管目录中。")))
                        continue
                    }
                    let result = unmount(mapping)
                    if result.state == .idle { removed.insert(mapping.id) }
                    else {
                        failedIDs.insert(mapping.id)
                        failures.append(describe(mapping, reason: result.message ?? L10n.text("无法安全卸载，目录可能正被占用。")))
                    }
                }
                let remaining = try mountedPaths()
                for mapping in mappings where remaining.contains(mapping.managedMountPath) {
                    removed.remove(mapping.id)
                    if !failedIDs.contains(mapping.id) {
                        failures.append(describe(mapping, reason: L10n.text("磁盘仍处于挂载状态。")))
                    }
                }
            } catch {
                failures.append(L10n.format("无法确认系统挂载状态：%@", error.localizedDescription))
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

    func terminalTheme(isDark: Bool) -> TerminalTheme {
        let imported = importedTerminalThemes.first { $0.selectionID == selectedTerminalThemeID }
        return TerminalTheme(preset: terminalThemePreset, isDark: isDark,
                             logHighlightEnabled: terminalLogHighlightEnabled,
                             fieldHighlightEnabled: terminalFieldHighlightEnabled,
                             importedPalette: imported?.palette(isDark: isDark))
    }

    func importTerminalTheme(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard url.pathExtension.lowercased() == "itermcolors" else { throw TerminalThemeImportError.invalidPlist }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 1_048_576 else { throw TerminalThemeImportError.oversized }
            let data = try Data(contentsOf: url)
            let theme = try terminalThemeLibrary.add(data: data, name: url.deletingPathExtension().lastPathComponent)
            importedTerminalThemes = terminalThemeLibrary.load()
            selectedTerminalThemeID = theme.selectionID
            terminalThemeNotice = nil
        } catch {
            terminalThemeNotice = error.localizedDescription
        }
    }

    func deleteSelectedImportedTerminalTheme() {
        guard let theme = importedTerminalThemes.first(where: { $0.selectionID == selectedTerminalThemeID }) else { return }
        do {
            try terminalThemeLibrary.remove(theme)
            importedTerminalThemes.removeAll { $0.id == theme.id }
            selectedTerminalThemeID = TerminalThemePreset.tokyoNight.rawValue
            terminalThemeNotice = L10n.text("已删除导入主题，已恢复 Tokyo Night。")
        } catch {
            terminalThemeNotice = error.localizedDescription
        }
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
    case invalidSavedPassword
    case savedPasswordUnavailable
    case savedPasswordSyncChanged

    public var errorDescription: String? {
        switch self {
        case .invalidProfile: L10n.text("请填写名称、主机、端口和用户名。")
        case .invalidMapping: L10n.text("请填写映射名称、远程目录和本地访问目录。")
        case .mappingConflict(let message): message
        case .invalidSavedPassword: L10n.text("请填写密码条目的名称、用户名和密码。")
        case .savedPasswordUnavailable: L10n.text("无法读取密码管理中的凭据，请重新保存该条目。")
        case .savedPasswordSyncChanged: L10n.text("关联会话已变化，本次同步未完成。请刷新后重试。")
        }
    }
}
