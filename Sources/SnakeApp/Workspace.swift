import AppKit
import Bonsplit
import Combine
import CryptoKit
import Foundation
import SnakeCoreBindings
import SwiftUI
import SwiftTerm

public struct WindowID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct WorkspaceTabID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct TabTransferPayload: Codable, Sendable {
    public let sourceWindowID: WindowID
    public let tabID: WorkspaceTabID
    public let transactionID: UUID
}

enum TerminalShellIntegration {
    static func hookCommand(for shellName: String) -> String? {
        switch shellName.lowercased() {
        case "bash":
            return " __snake_cwd(){ printf '\\033]7;file://%s%s\\033\\\\' \"${HOSTNAME:-localhost}\" \"$PWD\"; }; case \";${PROMPT_COMMAND:-};\" in *\";__snake_cwd;\"*) ;; *) PROMPT_COMMAND=\"__snake_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}\";; esac; __snake_cwd\n"
        case "zsh":
            return " function __snake_cwd(){ printf '\\033]7;file://%s%s\\033\\\\' \"${HOST:-localhost}\" \"$PWD\"; }; (( ${precmd_functions[(I)__snake_cwd]} )) || precmd_functions+=(__snake_cwd); __snake_cwd\n"
        case "fish":
            return " function __snake_cwd --on-event fish_prompt; printf '\\e]7;file://%s%s\\e\\\\' (hostname) $PWD; end; __snake_cwd\n"
        default:
            return nil
        }
    }
}

@MainActor
public final class TerminalRuntime: ObservableObject, Identifiable {
    public let id = WorkspaceTabID()
    public let profile: SSHProfile
    public let uploader: LocalUploadCoordinator
    @Published public private(set) var state: ConnectionState = .idle
    @Published public private(set) var launchRequested = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var pendingHostKey: SFTPHostKeyPrompt?
    @Published public private(set) var remoteTitle: String?
    @Published public private(set) var securityInfo: CoreConnectionSecurity?
    @Published public private(set) var currentRemoteDirectory: String?
    @Published public private(set) var connectionStatusText = L10n.text("正在建立 Rust SSH PTY 连接…")
    private let ioQueue: DispatchQueue
    private var terminalView: TerminalView?
    private var terminalDelegate: RustTerminalViewBridge?
    private var handle: CoreTerminalHandle?
    private var appliedTheme: TerminalTheme?
    private var appliedFontName: String?
    private var appliedFontSize: Double?
    private var isStarting = false
    private var connectionAttemptID = UUID()
    private var uploaderCancellable: AnyCancellable?

    init(profile: SSHProfile) {
        self.profile = profile
        self.uploader = LocalUploadCoordinator(profile: profile)
        ioQueue = DispatchQueue(label: "com.snake.terminal.\(id.rawValue.uuidString)", qos: .userInitiated)
        uploaderCancellable = uploader.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    public func requestConnection() {
        guard state != .connecting, state != .connected else { return }
        uploader.canPresentTransferConflicts = true
        launchRequested = true
        state = .connecting
        errorMessage = nil
        pendingHostKey = nil
        securityInfo = nil
        currentRemoteDirectory = nil
        connectionStatusText = L10n.text("正在建立 Rust SSH PTY 连接…")
        if let terminalView {
            startIfNeeded(terminalView)
        }
    }

    public func retryConnection() {
        stopHandle()
        requestConnection()
    }

    public func acceptPendingHostKey() {
        guard let prompt = pendingHostKey else { return }
        pendingHostKey = nil
        state = .connecting
        connectionStatusText = L10n.text("正在建立 Rust SSH PTY 连接…")
        connect(accepting: prompt.fingerprint)
    }

    public func rejectPendingHostKey() {
        pendingHostKey = nil
        state = .failed
        errorMessage = L10n.text("未信任主机密钥，终端连接已取消。")
    }

    public func stop() {
        connectionAttemptID = UUID()
        isStarting = false
        stopHandle()
        state = .disconnected
        securityInfo = nil
        currentRemoteDirectory = nil
        uploader.closeTransferPresentation()
    }

    func terminalSurface() -> TerminalView {
        if let terminalView { return terminalView }
        let terminalView = TerminalView(frame: .zero)
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        TerminalTheme.dark.apply(to: terminalView)
        appliedTheme = .dark
        let delegate = RustTerminalViewBridge(runtime: self)
        terminalView.terminalDelegate = delegate
        terminalDelegate = delegate
        self.terminalView = terminalView
        return terminalView
    }

    var existingTerminalSurface: TerminalView? { terminalView }

    func pasteFileNames(_ text: String) {
        guard state == .connected else { return }
        terminalView?.pasteText(text)
    }

    func applyTheme(_ theme: TerminalTheme) {
        guard appliedTheme != theme else { return }
        theme.apply(to: terminalSurface())
        appliedTheme = theme
    }

    func applyFont(name: String, size: Double) {
        guard appliedFontName != name || appliedFontSize != size else { return }
        let font = NSFont(name: name, size: CGFloat(size))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        terminalSurface().font = font
        appliedFontName = name
        appliedFontSize = size
    }

    func startIfNeeded(_ view: TerminalView) {
        guard launchRequested, state == .connecting, !isStarting, handle == nil else { return }
        connect(
            accepting: nil,
            columns: UInt32(clamping: view.getTerminal().cols),
            rows: UInt32(clamping: view.getTerminal().rows)
        )
    }

    func send(_ data: Data) {
        guard let handle, !data.isEmpty else { return }
        ioQueue.async { [weak self] in
            do {
                try handle.write(data: data)
            } catch {
                Task { @MainActor [weak self] in
                    self?.handleIOError(error)
                }
            }
        }
    }

    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        guard let handle, columns > 0, rows > 0 else { return }
        ioQueue.async {
            try? handle.resize(
                columns: UInt32(clamping: columns),
                rows: UInt32(clamping: rows),
                pixelWidth: UInt32(clamping: max(0, pixelWidth)),
                pixelHeight: UInt32(clamping: max(0, pixelHeight))
            )
        }
    }

    func updateTitle(_ title: String) {
        remoteTitle = title.isEmpty ? nil : title
    }

    func updateRemoteDirectory(_ value: String?) {
        currentRemoteDirectory = LocalUploadCoordinator.normalizedRemoteDirectory(from: value)
    }

    func uploadFromFinder(urls: [URL], target: FinderUploadTarget, window: NSWindow, store: ApplicationStore) {
        guard state == .connected else { return }
        if case .directory(let path) = target {
            uploader.upload(urls: urls, destinationRoot: path, store: store)
            return
        }
        guard target == .confirmDirectory, window.attachedSheet == nil else { return }
        let attemptID = connectionAttemptID
        let alert = NSAlert()
        alert.messageText = L10n.text("选择上传目录")
        alert.informativeText = L10n.text("当前终端尚未报告目录，请确认这些文件的远程上传位置。")
        alert.addButton(withTitle: L10n.text("上传"))
        alert.addButton(withTitle: L10n.text("取消"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        field.placeholderString = L10n.text("远程绝对路径，例如 /tmp")
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn,
                  self.connectionAttemptID == attemptID, self.state == .connected else { return }
            self.uploader.upload(urls: urls, destinationRoot: field.stringValue, store: store)
        }
        Task { [weak self, weak field] in
            guard let self, let home = try? await uploader.remoteHomeDirectory(),
                  connectionAttemptID == attemptID, state == .connected,
                  let field, field.stringValue.isEmpty else { return }
            field.stringValue = home
        }
    }

    func feed(_ data: Data, attemptID: UUID) {
        guard attemptID == connectionAttemptID else { return }
        let bytes = [UInt8](data)
        terminalView?.feed(byteArray: bytes[...])
    }

    func terminalDidClose(exitStatus: Int32, message: String?, attemptID: UUID) {
        guard attemptID == connectionAttemptID else { return }
        handle = nil
        isStarting = false
        securityInfo = nil
        currentRemoteDirectory = nil
        if let message, !message.isEmpty {
            state = .failed
            errorMessage = L10n.format("终端连接中断：%@", message)
        } else {
            state = .disconnected
            errorMessage = exitStatus == 0 ? nil : L10n.format("远程 shell 已退出（状态码 %@）。", exitStatus)
        }
    }

    private func connect(accepting fingerprint: String?, columns: UInt32? = nil, rows: UInt32? = nil) {
        guard !isStarting else { return }
        isStarting = true
        state = .connecting
        errorMessage = nil
        pendingHostKey = nil
        let attemptID = UUID()
        connectionAttemptID = attemptID
        let observer = RustTerminalObserver(runtime: self, attemptID: attemptID)
        let profile = profile
        let knownHostsPath = Self.knownHostsPath
        let terminal = terminalView?.getTerminal()
        let initialColumns = columns ?? UInt32(clamping: terminal?.cols ?? 80)
        let initialRows = rows ?? UInt32(clamping: terminal?.rows ?? 24)

        Task {
            for retryIndex in 0...1 {
                do {
                    let newHandle = try await Task.detached(priority: .userInitiated) {
                        let authentication = try Self.authentication(for: profile)
                        defer {
                            if case let .privateKey(_, _, scopedURL) = authentication {
                                scopedURL.stopAccessingSecurityScopedResource()
                            }
                        }
                        switch authentication {
                        case .password(let password):
                            return try openTerminalPassword(
                                host: profile.host,
                                port: UInt16(profile.port),
                                username: profile.username,
                                password: password,
                                knownHostsPath: knownHostsPath,
                                acceptFingerprint: fingerprint,
                                columns: initialColumns,
                                rows: initialRows,
                                observer: observer
                            )
                        case .privateKey(let path, let passphrase, _):
                            return try openTerminalPrivateKey(
                                host: profile.host,
                                port: UInt16(profile.port),
                                username: profile.username,
                                privateKeyPath: path,
                                passphrase: passphrase,
                                knownHostsPath: knownHostsPath,
                                acceptFingerprint: fingerprint,
                                columns: initialColumns,
                                rows: initialRows,
                                observer: observer
                            )
                        }
                    }.value
                    guard connectionAttemptID == attemptID, launchRequested, state == .connecting else {
                        newHandle.close()
                        return
                    }
                    handle = newHandle
                    securityInfo = newHandle.securityInfo()
                    let shellName = newHandle.shellName()
                    connectionStatusText = L10n.text("正在建立 Rust SSH PTY 连接…")
                    isStarting = false
                    state = .connected
                    installDirectoryHook(shellName: shellName)
                    terminalView?.window?.makeFirstResponder(terminalView)
                    return
                } catch let error as CoreError {
                    guard connectionAttemptID == attemptID, launchRequested, state == .connecting else { return }
                    if TerminalConnectionRetryPolicy.shouldRetry(error, retryIndex: retryIndex) {
                        connectionStatusText = L10n.text("首次连接未完成，正在自动重试…")
                        try? await Task.sleep(for: .milliseconds(400))
                        guard connectionAttemptID == attemptID, launchRequested, state == .connecting else { return }
                        continue
                    }
                    isStarting = false
                    handleCoreError(error)
                    return
                } catch {
                    guard connectionAttemptID == attemptID else { return }
                    isStarting = false
                    state = .failed
                    errorMessage = error.localizedDescription
                    return
                }
            }
        }
    }

    private nonisolated static func authentication(for profile: SSHProfile) throws -> TerminalAuthentication {
        switch profile.authMethod {
        case .password:
            guard let account = profile.keychainAccount,
                  let password = try CredentialStore.readData(account: account) else {
                throw TerminalRuntimeError.missingPassword
            }
            return .password(password)
        case .privateKey:
            guard let bookmark = profile.privateKeyBookmark else {
                throw TerminalRuntimeError.missingPrivateKey
            }
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard !stale, url.startAccessingSecurityScopedResource() else {
                throw TerminalRuntimeError.stalePrivateKey
            }
            let passphrase = try profile.keychainAccount.flatMap { try CredentialStore.readData(account: $0) }
            return .privateKey(path: url.path, passphrase: passphrase, scopedURL: url)
        }
    }

    private func handleCoreError(_ error: CoreError) {
        state = .failed
        securityInfo = nil
        currentRemoteDirectory = nil
        switch error {
        case let .HostKeyUnknown(host, port, algorithm, fingerprint):
            pendingHostKey = SFTPHostKeyPrompt(
                host: host,
                port: Int(port),
                algorithm: algorithm,
                fingerprint: fingerprint
            )
            errorMessage = nil
        case let .HostKeyMismatch(host, port, algorithm, fingerprint, previousFingerprints):
            pendingHostKey = SFTPHostKeyPrompt(
                host: host, port: Int(port), algorithm: algorithm, fingerprint: fingerprint,
                previousFingerprints: previousFingerprints
            )
            errorMessage = nil
        case let .Connection(message, stage):
            errorMessage = CoreErrorText.text(message, stage: stage, fallback: "终端连接失败：%@")
        case let .Authentication(message, stage):
            errorMessage = CoreErrorText.text(message, stage: stage, fallback: "终端认证失败：%@")
        case let .InvalidInput(message):
            errorMessage = L10n.format("终端参数无效：%@", message)
        case .TerminalClosed:
            errorMessage = L10n.text("终端连接已关闭。")
        default:
            errorMessage = String(describing: error)
        }
    }

    private func handleIOError(_ error: Error) {
        guard state == .connected else { return }
        state = .failed
        securityInfo = nil
        currentRemoteDirectory = nil
        errorMessage = L10n.format("终端输入失败：%@", error.localizedDescription)
    }

    private func stopHandle() {
        let oldHandle = handle
        handle = nil
        ioQueue.async { oldHandle?.close() }
    }

    private func installDirectoryHook(shellName: String) {
        guard let command = TerminalShellIntegration.hookCommand(for: shellName),
              let data = command.data(using: .utf8) else { return }
        send(data)
    }

    nonisolated private static var knownHostsPath: String {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Snake/known_hosts").path
    }
}

private enum TerminalAuthentication: Sendable {
    case password(Data)
    case privateKey(path: String, passphrase: Data?, scopedURL: URL)
}

private enum TerminalRuntimeError: LocalizedError {
    case missingPassword
    case missingPrivateKey
    case stalePrivateKey

    var errorDescription: String? {
        switch self {
        case .missingPassword: L10n.text("此会话尚未保存密码，请编辑会话后加密保存密码。")
        case .missingPrivateKey: L10n.text("此会话尚未选择私钥文件。")
        case .stalePrivateKey: L10n.text("私钥访问授权已失效，请重新选择私钥文件。")
        }
    }
}

enum TerminalConnectionRetryPolicy {
    static func shouldRetry(_ error: CoreError, retryIndex: Int) -> Bool {
        guard retryIndex == 0 else { return false }
        if case .Connection = error { return true }
        return false
    }
}

private final class RustTerminalObserver: CoreTerminalObserver, @unchecked Sendable {
    private weak var runtime: TerminalRuntime?
    private let attemptID: UUID

    init(runtime: TerminalRuntime, attemptID: UUID) {
        self.runtime = runtime
        self.attemptID = attemptID
    }

    func onOutput(data: Data) {
        Task { @MainActor [weak runtime] in
            runtime?.feed(data, attemptID: attemptID)
        }
    }

    func onClosed(exitStatus: Int32, message: String?) {
        Task { @MainActor [weak runtime] in
            runtime?.terminalDidClose(exitStatus: exitStatus, message: message, attemptID: attemptID)
        }
    }
}

@MainActor
private final class RustTerminalViewBridge: NSObject, @preconcurrency TerminalViewDelegate {
    private weak var runtime: TerminalRuntime?

    init(runtime: TerminalRuntime) {
        self.runtime = runtime
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let scale = source.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        runtime?.resize(
            columns: newCols,
            rows: newRows,
            pixelWidth: Int(source.bounds.width * scale),
            pixelHeight: Int(source.bounds.height * scale)
        )
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        runtime?.updateTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        runtime?.updateRemoteDirectory(directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        runtime?.send(Data(data))
    }

    func scrolled(source: TerminalView, position: Double) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor
public final class LocalUploadCoordinator: ObservableObject {
    // Injected only by isolated integration tests; production uses the same
    // authenticated, host-key-verified factory as before.
    var transferHandleFactory: (@Sendable () throws -> CoreSftpHandle)?
    var makeHandle: @Sendable () throws -> CoreSftpHandle {
        if let transferHandleFactory { return transferHandleFactory }
        let profile = profile
        return { try Self.openTransferHandle(profile: profile) }
    }
    public let profile: SSHProfile
    @Published public internal(set) var records: [SFTPUploadRecord] = []
    @Published public private(set) var pendingConflict: SFTPUploadConflictPrompt?
    @Published public internal(set) var errorMessage: String?
    @Published var activity = UploadActivity()
    @Published var pendingDownloadConflict: DownloadConflictPrompt?
    @Published var applyDownloadConflictToBatch = false
    var downloadConflictContinuation: CheckedContinuation<SFTPUploadConflictDecision, Never>?
    var downloadRetries: [UUID: @MainActor () async -> Void] = [:]
    var canPresentTransferConflicts = true

    func closeTransferPresentation() {
        canPresentTransferConflicts = false
        resolveConflict(.cancel)
        resolveDownloadConflict(.cancel)
    }
    public var isPreparing: Bool { activity.pendingCount > 0 }
    var hasUploadActivity: Bool { activity.startedAt != nil || !records.isEmpty }
    private var conflictContinuation: CheckedContinuation<SFTPUploadConflictDecision, Never>?
    var batchTask: Task<Void, Never>?

    public init(profile: SSHProfile) {
        self.profile = profile
    }

    public func upload(
        urls: [URL],
        destinationRoot: String,
        store: ApplicationStore,
        onFinished: (@MainActor () -> Void)? = nil
    ) {
        guard !urls.isEmpty else { return }
        guard let destinationRoot = Self.validRemoteDirectory(destinationRoot) else {
            errorMessage = L10n.text("上传目录无效，请输入绝对远程路径。")
            return
        }
        let profile = profile
        let threshold = store.multipartThresholdBytes
        let makeHandle = makeHandle
        let concurrency = HostTransferPlan.workerCount(
            requested: store.multipartConcurrency,
            hostLimit: store.hostConcurrencyLimit
        )
        errorMessage = nil
        activity.begin()
        let previousBatch = batchTask
        batchTask = Task {
            await previousBatch?.value
            var outcome = UploadActivity.Outcome()
            defer { activity.finish(outcome) }
            let scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
            do {
                // Validate and scan before contacting the server. An unreadable
                // child must not silently turn into an empty successful upload.
                let items = try await Task.detached(priority: .userInitiated) {
                    try urls.flatMap { try Self.uploadItems(for: $0, destinationRoot: destinationRoot) }
                }.value
                // One operation connection lives for the whole batch (it also spans user
                // conflict prompts), so it stays outside the per-host transfer budget:
                // charging it would let a batch hold budget while its own shards wait.
                let operationHandle = try await Task.detached(priority: .userInitiated) {
                    try makeHandle()
                }.value
                for item in items {
                    if item.isDirectory {
                        try await Task.detached(priority: .utility) {
                            if !operationHandle.pathExists(path: item.remotePath) {
                                try operationHandle.createDirectory(path: item.remotePath)
                            }
                            guard try operationHandle.fileMetadata(path: item.remotePath).kind == "directory" else {
                                throw TransferIntegrity.error(L10n.format("上传目录目标不是普通目录：%@", item.remotePath))
                            }
                        }.value
                        outcome.succeeded += 1
                        continue
                    }
                    let targetExists = await Task.detached(priority: .utility) {
                        operationHandle.pathExists(path: item.remotePath)
                    }.value
                    var overwrite = false
                    if targetExists {
                        switch await requestConflict(localURL: item.localURL, remotePath: item.remotePath) {
                        case .overwrite:
                            overwrite = true
                        case .skip:
                            outcome.skipped += 1
                            continue
                        case .cancel:
                            outcome.cancelled += 1
                            return
                        }
                    }
                    let jobID = store.registerRealUpload(
                        url: item.localURL,
                        to: profile,
                        targetPath: item.remotePath,
                        totalBytes: item.size
                    )
                    register(jobID: jobID, item: item, overwrite: overwrite)
                    await performUpload(
                        item: item,
                        overwrite: overwrite,
                        jobID: jobID,
                        thresholdBytes: threshold,
                        concurrency: concurrency,
                        store: store
                    )
                    switch records.first(where: { $0.jobID == jobID })?.state {
                    case .succeeded: outcome.succeeded += 1
                    case .cancelled: outcome.cancelled += 1
                    default: outcome.failed += 1
                    }
                }
                onFinished?()
            } catch {
                outcome.failed += 1
                errorMessage = Self.message(for: error)
            }
        }
    }

    public func remoteHomeDirectory() async throws -> String {
        let profile = profile
        return try await Task.detached(priority: .userInitiated) {
            // A single short-lived connection, so it takes one slot on its own.
            try await HostTransferBudget.shared.withConnection(host: TransferHost(profile: profile)) {
                try Self.openTransferHandle(profile: profile).homeDirectory()
            }
        }.value
    }

    public func pause(jobID: UUID, store: ApplicationStore) {
        store.pause(jobID: jobID)
        update(jobID: jobID, state: .paused)
    }

    public func resume(jobID: UUID, store: ApplicationStore) {
        store.resume(jobID: jobID)
        update(jobID: jobID, state: .running)
    }

    public func cancel(jobID: UUID, store: ApplicationStore) {
        store.cancel(jobID: jobID)
        update(jobID: jobID, state: .cancelled, finishedAt: .now)
    }

    public func retry(jobID: UUID, store: ApplicationStore, onFinished: (@MainActor () -> Void)? = nil) {
        if let retry = downloadRetries[jobID] {
            // Retry participates in the same batch queue, so repeated retries
            // cannot multiply the per-batch worker limit or race old cleanup.
            let previous = batchTask
            batchTask = Task { await previous?.value; await retry() }
            return
        }
        guard let record = records.first(where: { $0.jobID == jobID }),
              [.failed, .cancelled, .interrupted].contains(record.state) else { return }
        let item = SFTPUploadItem(
            localURL: record.localURL,
            remotePath: record.remotePath,
            size: record.fileSize,
            isDirectory: false
        )
        store.prepareTransferRetry(jobID)
        update(jobID: jobID, state: .queued, finishedAt: nil)
        activity.begin()
        Task {
            await performUpload(
                item: item,
                overwrite: record.overwrite,
                jobID: jobID,
                thresholdBytes: store.multipartThresholdBytes,
                concurrency: HostTransferPlan.workerCount(
                    requested: store.multipartConcurrency,
                    hostLimit: store.hostConcurrencyLimit
                ),
                store: store
            )
            var outcome = UploadActivity.Outcome()
            switch records.first(where: { $0.jobID == jobID })?.state {
            case .succeeded: outcome.succeeded = 1
            case .cancelled: outcome.cancelled = 1
            default: outcome.failed = 1
            }
            activity.finish(outcome)
            onFinished?()
        }
    }

    public func clearFinishedRecords() {
        for record in records where [.succeeded, .failed, .cancelled, .interrupted].contains(record.state) {
            downloadRetries.removeValue(forKey: record.jobID)
        }
        records.removeAll { [.succeeded, .failed, .cancelled, .interrupted].contains($0.state) }
        if !isPreparing { activity = UploadActivity() }
    }

    public func resolveConflict(_ decision: SFTPUploadConflictDecision) {
        pendingConflict = nil
        conflictContinuation?.resume(returning: decision)
        conflictContinuation = nil
    }

    public static func normalizedRemoteDirectory(from value: String?) -> String? {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("file://") {
            let remainder = String(value.dropFirst(7))
            guard let slash = remainder.firstIndex(of: "/") else { return nil }
            value = String(remainder[slash...]).removingPercentEncoding ?? String(remainder[slash...])
        } else {
            value = value.removingPercentEncoding ?? value
        }
        return validRemoteDirectory(value)
    }

    private static func validRemoteDirectory(_ value: String) -> String? {
        guard value.hasPrefix("/"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        let normalized = (value as NSString).standardizingPath
        return normalized.isEmpty ? "/" : normalized
    }

    private func requestConflict(localURL: URL, remotePath: String) async -> SFTPUploadConflictDecision {
        guard canPresentTransferConflicts else { return .cancel }
        if conflictContinuation != nil { resolveConflict(.cancel) }
        return await withCheckedContinuation { continuation in
            conflictContinuation = continuation
            pendingConflict = SFTPUploadConflictPrompt(localName: localURL.lastPathComponent, remotePath: remotePath)
        }
    }

    private func register(jobID: UUID, item: SFTPUploadItem, overwrite: Bool) {
        records.insert(SFTPUploadRecord(
            jobID: jobID,
            fileName: item.localURL.lastPathComponent,
            remotePath: item.remotePath,
            fileSize: max(item.size, 0),
            startedAt: .now,
            state: .queued,
            localURL: item.localURL,
            overwrite: overwrite
        ), at: 0)
    }

    func update(jobID: UUID, state: TransferState, finishedAt: Date? = nil) {
        guard let index = records.firstIndex(where: { $0.jobID == jobID }) else { return }
        records[index].state = state
        records[index].finishedAt = finishedAt
    }

    private func performUpload(
        item: SFTPUploadItem,
        overwrite: Bool,
        jobID: UUID,
        thresholdBytes: Int64,
        concurrency: Int,
        store: ApplicationStore
    ) async {
        let control = store.makeTransferControl(for: jobID)
        // 与下载侧一致：先整笔预留「外层 operation + 分片」，拿到预算后才标记为传输中，
        // 所以等待预算期间记录保持「等待中」而不是「传输中」。
        let plannedWorkers = Self.plannedWorkerCount(
            size: item.size,
            thresholdBytes: thresholdBytes,
            concurrency: concurrency
        )
        do {
            let verification = try await HostTransferBudget.shared.reserve(
                host: TransferHost(profile: profile),
                connections: 1 + plannedWorkers
            ) {
                await MainActor.run {
                    store.markTransferRunning(jobID)
                    update(jobID: jobID, state: .running)
                }
                return try await Self.uploadResumableWork(
                    item: item,
                    profile: profile,
                    overwrite: overwrite,
                    thresholdBytes: thresholdBytes,
                    workers: plannedWorkers,
                    control: control,
                    jobID: jobID,
                    store: store,
                    makeHandle: makeHandle,
                    onVerification: { [weak self] value in
                        await self?.setVerification(jobID, value)
                    }
                )
            }
            setVerification(jobID, verification)
            store.markTransferSucceeded(jobID)
            update(jobID: jobID, state: .succeeded, finishedAt: .now)
        } catch {
            if case CoreError.TransferCancelled = error {
                store.cancel(jobID: jobID)
                update(jobID: jobID, state: .cancelled, finishedAt: .now)
            } else {
                setVerification(jobID, .failed(Self.message(for: error)))
                store.markTransferFailed(jobID, message: Self.message(for: error))
                update(jobID: jobID, state: .failed, finishedAt: .now)
            }
        }
    }

    /// Connections one upload opens: its operation handle plus its shards.
    nonisolated static func plannedWorkerCount(size: Int64, thresholdBytes: Int64, concurrency: Int) -> Int {
        guard size > thresholdBytes else { return 1 }
        return min(max(concurrency, 1), Int(max(size, 1)))
    }

    nonisolated private static func uploadResumableWork(
        item: SFTPUploadItem,
        profile: SSHProfile,
        overwrite: Bool,
        thresholdBytes: Int64,
        workers: Int,
        control: CoreTransferControl,
        jobID: UUID,
        store: ApplicationStore,
        makeHandle: @escaping @Sendable () throws -> CoreSftpHandle,
        onVerification: @escaping @Sendable (TransferVerification) async -> Void
    ) async throws -> TransferVerification {
        // 预算可能让我们等了一会儿；等待期间被取消/暂停要在开连接前就退出。
        try control.checkpoint()
        let initialVersion = try TransferIntegrity.LocalVersion(item.localURL)
        guard initialVersion.size == item.size else { throw TransferIntegrity.error(L10n.text("本地源文件已变化，请重新上传")) }
        let operation = try makeHandle()
        let capability = TransferIntegrity.bestEffortCapability { try operation.checksumCapability() }
        if capability.tool == "sftp-only" {
            return try await uploadSFTPOnly(item: item, initialVersion: initialVersion, capability: capability,
                operation: operation, overwrite: overwrite, thresholdBytes: thresholdBytes, workers: workers,
                control: control, jobID: jobID, store: store, makeHandle: makeHandle)
        }
        let localHash: String?
        if capability.algorithm.isEmpty { localHash = nil }
        else {
            await onVerification(.checking(L10n.format("源文件 %@", capability.algorithm)))
            localHash = try TransferIntegrity.optionalDigest {
                try TransferIntegrity.localDigest(url: item.localURL, algorithm: capability.algorithm, control: control)
            }
            await onVerification(.pending)
        }
        let totalBytes = max(item.size, 0)
        let workerCount = workers
        let ranges = uploadRanges(totalBytes: UInt64(totalBytes), workerCount: workerCount)
        let modified = try? item.localURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let identity = [item.remotePath, String(item.size), String(format: "%.6f", modified?.timeIntervalSince1970 ?? 0), String(ranges.count)].joined(separator: "\u{0}")
        let token = String(SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20))
        let parent = (item.remotePath as NSString).deletingLastPathComponent
        let baseName = ".snake-upload-\(token)"
        let stagingPath = (parent as NSString).appendingPathComponent("\(baseName).staging")
        let partPaths = ranges.indices.map { (parent as NSString).appendingPathComponent("\(baseName).part.\($0)") }
        let progress = SFTPMultipartProgress(jobID: jobID, totalBytes: UInt64(totalBytes), store: store)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (index, range) in ranges.enumerated() {
                    group.addTask {
                        let handle = try makeHandle()
                        let observer = SFTPPartTransferObserver(index: index, progress: progress)
                        try handle.uploadPartResumable(
                            localPath: item.localURL.path,
                            remotePartPath: partPaths[index],
                            localOffset: range.offset,
                            partLength: range.length,
                            control: control,
                            observer: observer
                        )
                    }
                }
                do { try await group.waitForAll() } catch { control.cancel(); throw error }
            }
        } catch {
            control.cancel()
            throw error
        }

        // Resume validates content, not only part lengths. A failed digest
        // invalidates the token's parts before a subsequent retry.
        do {
            try operation.assembleUpload(parts: partPaths, staging: stagingPath, control: control)
            guard try operation.fileMetadata(path: stagingPath).size == UInt64(totalBytes),
                  try TransferIntegrity.LocalVersion(item.localURL) == initialVersion else {
                throw TransferIntegrity.error(L10n.text("上传长度或源文件已变化，暂存文件未发布"))
            }
            let result: TransferVerification
            if let localHash {
                await onVerification(.checking(capability.algorithm))
                result = try TransferIntegrity.bestEffortVerification(algorithm: capability.algorithm, local: { localHash }, remote: {
                    try operation.remoteChecksum(path: stagingPath, capability: capability, control: control)
                })
            } else { result = .unavailable(capability.reason.isEmpty ? L10n.text("源文件摘要无法计算，已跳过校验") : capability.reason) }
            guard try TransferIntegrity.LocalVersion(item.localURL) == initialVersion else {
                throw TransferIntegrity.error(L10n.text("校验期间本地源文件已变化"))
            }
            try operation.publishUpload(staging: stagingPath, target: item.remotePath, parts: partPaths, overwrite: overwrite, control: control)
            return result
        } catch {
            // Remove only exact task-owned staging paths. Do not touch the
            // final target or recursively remove any remote directory.
            for path in partPaths + [stagingPath] { try? operation.removeTransferTemporary(path: path) }
            throw error
        }
    }

    nonisolated static func uploadRanges(totalBytes: UInt64, workerCount: Int) -> [SFTPUploadRange] {
        guard totalBytes > 0 else { return [SFTPUploadRange(offset: 0, length: 0)] }
        let count = max(1, min(workerCount, Int(totalBytes)))
        let base = totalBytes / UInt64(count)
        let remainder = totalBytes % UInt64(count)
        var offset = UInt64(0)
        return (0..<count).map { index in
            let length = base + (UInt64(index) < remainder ? 1 : 0)
            defer { offset += length }
            return SFTPUploadRange(offset: offset, length: length)
        }
    }

    nonisolated static func openTransferHandle(profile: SSHProfile) throws -> CoreSftpHandle {
        let authentication = try authentication(for: profile)
        defer {
            if case let .privateKey(_, _, scopedURL) = authentication {
                scopedURL.stopAccessingSecurityScopedResource()
            }
        }
        switch authentication {
        case .password(let password):
            return try openSftpPassword(host: profile.host, port: UInt16(profile.port), username: profile.username, password: password, knownHostsPath: knownHostsPath, acceptFingerprint: nil)
        case .privateKey(let path, let passphrase, _):
            return try openSftpPrivateKey(host: profile.host, port: UInt16(profile.port), username: profile.username, privateKeyPath: path, passphrase: passphrase, knownHostsPath: knownHostsPath, acceptFingerprint: nil)
        }
    }

    nonisolated private static func authentication(for profile: SSHProfile) throws -> SFTPAuthentication {
        switch profile.authMethod {
        case .password:
            guard let account = profile.keychainAccount, let password = try CredentialStore.readData(account: account) else { throw SFTPRuntimeError.missingPassword }
            return .password(password)
        case .privateKey:
            guard let bookmark = profile.privateKeyBookmark else { throw SFTPRuntimeError.missingPrivateKey }
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale, url.startAccessingSecurityScopedResource() else { throw SFTPRuntimeError.stalePrivateKey }
            let passphrase = try profile.keychainAccount.flatMap { try CredentialStore.readData(account: $0) }
            return .privateKey(path: url.path, passphrase: passphrase, scopedURL: url)
        }
    }

    nonisolated static func uploadItems(for url: URL, destinationRoot: String) throws -> [SFTPUploadItem] {
        let manager = FileManager.default
        guard url.isFileURL, manager.isReadableFile(atPath: url.path) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let rootRemotePath = (destinationRoot as NSString).appendingPathComponent(url.lastPathComponent)
        guard values.isDirectory == true else {
            return [SFTPUploadItem(localURL: url, remotePath: rootRemotePath, size: Int64(values.fileSize ?? 0), isDirectory: false)]
        }
        var items = [SFTPUploadItem(localURL: url, remotePath: rootRemotePath, size: 0, isDirectory: true)]
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        var scanError: Error?
        // macOS enumerates /tmp (and other aliases) using its canonical path.
        // String slicing against the original Finder URL corrupts subpaths.
        let enumerationRoot = url.resolvingSymlinksInPath()
        let rootComponents = enumerationRoot.pathComponents
        guard let enumerator = manager.enumerator(at: enumerationRoot, includingPropertiesForKeys: keys, options: [], errorHandler: { _, error in
            scanError = error
            return false
        }) else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        for case let child as URL in enumerator {
            // Normalize the parent as well: Foundation canonicalizes /private
            // aliases differently between URL resolution and enumeration. Keep
            // the leaf name intact so a symlink retains its Finder name.
            let components = child.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(child.lastPathComponent).pathComponents
            guard components.starts(with: rootComponents), components.count > rootComponents.count else {
                throw CocoaError(.fileReadInvalidFileName, userInfo: [NSFilePathErrorKey: child.path])
            }
            let relative = components.dropFirst(rootComponents.count).joined(separator: "/")
            guard manager.isReadableFile(atPath: child.path) else {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: child.path])
            }
            let childValues = try child.resourceValues(forKeys: Set(keys))
            items.append(SFTPUploadItem(
                localURL: child,
                remotePath: (rootRemotePath as NSString).appendingPathComponent(relative),
                size: Int64(childValues.fileSize ?? 0),
                isDirectory: childValues.isDirectory == true
            ))
        }
        if let scanError { throw scanError }
        return items.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.remotePath < $1.remotePath
        }
    }

    nonisolated private static func message(for error: Error) -> String {
        switch error {
        case let CoreError.Connection(message, stage): CoreErrorText.text(message, stage: stage, fallback: "SFTP 连接失败：%@")
        case let CoreError.Authentication(message, stage): CoreErrorText.text(message, stage: stage, fallback: "SFTP 认证失败：%@")
        case let CoreError.InvalidInput(message): L10n.format("SFTP 参数无效：%@", message)
        case let CoreError.Conflict(path): L10n.format("目标已存在：%@。请选择安全覆盖、跳过或重命名。", path)
        case CoreError.TransferCancelled: L10n.text("传输已取消。")
        default: String(describing: error)
        }
    }

    nonisolated private static var knownHostsPath: String {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Snake/known_hosts").path
    }
}

@MainActor
public final class SFTPRuntime: ObservableObject, Identifiable {
    private static var registry: [UUID: WeakSFTPRuntime] = [:]
    public let id = WorkspaceTabID()
    public let profile: SSHProfile
    @Published public var currentPath = "/"
    @Published var fileSelection = SFTPSelection()
    @Published public private(set) var isDeleting = false
    @Published public private(set) var deletionError: String?
    @Published public private(set) var entries: [RemoteFile] = []
    @Published public private(set) var connectionState: ConnectionState = .idle
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var pendingHostKey: SFTPHostKeyPrompt?
    @Published public private(set) var backHistory: [String] = []
    @Published public private(set) var forwardHistory: [String] = []
    @Published public private(set) var loadingPath: String?
    @Published private(set) var searchCommandRequest = 0
    @Published private(set) var deleteCommandRequest = 0
    @Published private(set) var uploadFileCommandRequest = 0
    @Published private(set) var shortcutNotice: String?
    public let uploader: LocalUploadCoordinator
    private var handle: CoreSftpHandle?
    private var connectionAttemptID = UUID()
    private var navigationRequestID = UUID()
    private var directoryCache: [String: [RemoteFile]] = [:]
    private var failedNavigationPath: String?
    private var uploaderCancellable: AnyCancellable?

    public var pendingUploadConflict: SFTPUploadConflictPrompt? { uploader.pendingConflict }
    public var uploadRecords: [SFTPUploadRecord] { uploader.records }

    var canSearchWithShortcut: Bool { connectionState == .connected && loadingPath == nil }
    var canDeleteWithShortcut: Bool {
        canSearchWithShortcut && !isDeleting && !fileSelection.ids.isEmpty
    }
    var canUploadFileWithShortcut: Bool { directoryActionDestination != nil }

    func requestSearchCommand() { searchCommandRequest &+= 1 }
    func requestDeleteCommand() { deleteCommandRequest &+= 1 }
    func requestUploadFileCommand() { uploadFileCommandRequest &+= 1 }

    func showShortcutUnavailableNotice() {
        shortcutNotice = connectionState == .connected
            ? L10n.text("目录正在加载，请稍后再试。")
            : L10n.text("请先完成 SFTP 连接，再使用快捷键。")
        let notice = shortcutNotice
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.shortcutNotice == notice { self?.shortcutNotice = nil }
        }
    }

    init(profile: SSHProfile) {
        self.profile = profile
        self.uploader = LocalUploadCoordinator(profile: profile)
        uploaderCancellable = uploader.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        Self.registry[id.rawValue] = WeakSFTPRuntime(self)
    }

    public func connectIfNeeded(accepting fingerprint: String? = nil) {
        guard connectionState != .connecting, connectionState != .connected else { return }
        uploader.canPresentTransferConflicts = true
        connectionState = .connecting
        errorMessage = nil
        pendingHostKey = nil
        let attemptID = UUID()
        connectionAttemptID = attemptID
        let profile = profile
        let knownHostsPath = Self.knownHostsPath
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let authentication = try Self.authentication(for: profile)
                    defer {
                        if case let .privateKey(_, _, scopedURL) = authentication {
                            scopedURL.stopAccessingSecurityScopedResource()
                        }
                    }
                    let handle: CoreSftpHandle
                    switch authentication {
                    case .password(let password):
                        handle = try openSftpPassword(
                            host: profile.host,
                            port: UInt16(profile.port),
                            username: profile.username,
                            password: password,
                            knownHostsPath: knownHostsPath,
                            acceptFingerprint: fingerprint
                        )
                    case .privateKey(let path, let passphrase, _):
                        handle = try openSftpPrivateKey(
                            host: profile.host,
                            port: UInt16(profile.port),
                            username: profile.username,
                            privateKeyPath: path,
                            passphrase: passphrase,
                            knownHostsPath: knownHostsPath,
                            acceptFingerprint: fingerprint
                        )
                    }
                    let home = try handle.homeDirectory()
                    let entries = try handle.list(path: home)
                    return (handle, home, entries)
                }.value
                guard connectionAttemptID == attemptID else { return }
                handle = result.0
                currentPath = result.1
                entries = Self.remoteFiles(from: result.2)
                directoryCache[result.1] = entries
                backHistory = []
                forwardHistory = []
                loadingPath = nil
                failedNavigationPath = nil
                connectionState = .connected
            } catch let error as CoreError {
                guard connectionAttemptID == attemptID else { return }
                handleCoreError(error)
            } catch {
                guard connectionAttemptID == attemptID else { return }
                connectionState = .failed
                errorMessage = error.localizedDescription
            }
        }
    }

    public func acceptPendingHostKey() {
        guard let prompt = pendingHostKey else { return }
        connectionState = .idle
        connectIfNeeded(accepting: prompt.fingerprint)
    }

    public func rejectPendingHostKey() {
        pendingHostKey = nil
        connectionState = .failed
        errorMessage = L10n.text("未信任主机密钥，SFTP 连接已取消。")
    }

    public func disconnect() {
        connectionAttemptID = UUID()
        navigationRequestID = UUID()
        handle = nil
        entries = []
        directoryCache = [:]
        loadingPath = nil
        failedNavigationPath = nil
        connectionState = .disconnected
        uploader.closeTransferPresentation()
    }

    public func refresh(path: String? = nil) {
        guard let handle else {
            connectIfNeeded()
            return
        }
        let target = path ?? currentPath
        let previous = currentPath
        load(target, using: handle) { [weak self] in
            guard let self, target != previous else { return }
            backHistory.append(previous)
            forwardHistory.removeAll()
        }
    }

    public func navigate(to address: String) {
        let cleaned = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.hasPrefix("/") else {
            errorMessage = L10n.text("远程地址必须以 / 开头。")
            return
        }
        let normalized = (cleaned as NSString).standardizingPath
        refresh(path: normalized.isEmpty ? "/" : normalized)
    }

    public var canGoBack: Bool { !backHistory.isEmpty }
    public var canGoForward: Bool { !forwardHistory.isEmpty }

    public func goBack() {
        guard let handle, let target = backHistory.last else { return }
        let previous = currentPath
        load(target, using: handle) { [weak self] in
            guard let self else { return }
            _ = backHistory.popLast()
            forwardHistory.append(previous)
        }
    }

    public func goForward() {
        guard let handle, let target = forwardHistory.last else { return }
        let previous = currentPath
        load(target, using: handle) { [weak self] in
            guard let self else { return }
            _ = forwardHistory.popLast()
            backHistory.append(previous)
        }
    }

    public func retryLastOperation() {
        if let failedNavigationPath, handle != nil {
            refresh(path: failedNavigationPath)
        } else {
            connectionState = .idle
            connectIfNeeded()
        }
    }

    private func load(_ target: String, using handle: CoreSftpHandle, onSuccess: @escaping @MainActor () -> Void) {
        let requestID = UUID()
        navigationRequestID = requestID
        let previousPath = currentPath
        let previousEntries = entries
        currentPath = target
        fileSelection = SFTPSelection()
        loadingPath = target
        errorMessage = nil
        failedNavigationPath = nil
        if target != previousPath {
            entries = directoryCache[target] ?? []
        }
        Task {
            do {
                let remoteEntries = try await Task.detached(priority: .userInitiated) {
                    try handle.list(path: target)
                }.value
                guard navigationRequestID == requestID else { return }
                let files = Self.remoteFiles(from: remoteEntries)
                onSuccess()
                directoryCache[target] = files
                entries = files
                loadingPath = nil
                connectionState = .connected
                errorMessage = nil
            } catch {
                guard navigationRequestID == requestID else { return }
                currentPath = previousPath
                entries = previousEntries
                loadingPath = nil
                failedNavigationPath = target
                connectionState = .connected
                errorMessage = Self.message(for: error)
            }
        }
    }

    public func open(_ file: RemoteFile, cache: RemoteOpenCacheConfiguration) {
        if file.isDirectory {
            refresh(path: file.path)
        } else {
            downloadAndOpen(file, cache: cache)
        }
    }

    var finderUploadTarget: FinderUploadTarget {
        guard connectionState == .connected else { return .unavailable(L10n.text("请先完成 SFTP 连接")) }
        guard loadingPath == nil else { return .unavailable(L10n.text("请等待目录打开后再上传")) }
        return .directory(currentPath)
    }

    var directoryActionDestination: SFTPDirectoryDestination? {
        SFTPDirectoryDestination(connectionState: connectionState, currentPath: currentPath, loadingPath: loadingPath)
    }

    func uploadFromFinder(providers: [NSItemProvider], to path: String, store: ApplicationStore) {
        finderDropLog.notice("SFTP drop submitted: items=\(providers.count)")
        let attempt = connectionAttemptID
        Task { @MainActor in
            do {
                let urls = try await FinderUploadPasteboard.urls(from: providers)
                guard connectionAttemptID == attempt, connectionState == .connected else {
                    finderDropLog.notice("SFTP drop cancelled by connection change")
                    return
                }
                finderDropLog.notice("SFTP upload enqueued: files=\(urls.count)")
                upload(urls: urls, to: path, store: store)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    public func upload(urls: [URL], to destination: String? = nil, store: ApplicationStore) {
        guard handle != nil else {
            errorMessage = L10n.text("SFTP 尚未连接，无法上传。")
            connectIfNeeded()
            return
        }
        uploader.upload(urls: urls, destinationRoot: destination ?? currentPath, store: store) { [weak self] in
            self?.refresh()
        }
    }

    public func pauseUpload(jobID: UUID, store: ApplicationStore) {
        uploader.pause(jobID: jobID, store: store)
    }

    public func resumeUpload(jobID: UUID, store: ApplicationStore) {
        uploader.resume(jobID: jobID, store: store)
    }

    public func cancelUpload(jobID: UUID, store: ApplicationStore) {
        uploader.cancel(jobID: jobID, store: store)
    }

    public func retryUpload(jobID: UUID, store: ApplicationStore) {
        uploader.retry(jobID: jobID, store: store) { [weak self] in
            self?.refresh()
        }
    }

    public func clearFinishedUploadRecords() {
        uploader.clearFinishedRecords()
    }

    public func resolveUploadConflict(_ decision: SFTPUploadConflictDecision) {
        uploader.resolveConflict(decision)
    }

    public func copy(file: RemoteFile, from source: SFTPRuntime, store: ApplicationStore) {
        guard let sourceHandle = source.handle, let destinationHandle = handle else {
            errorMessage = L10n.text("来源或目标 SFTP 尚未连接，无法开始远程互传。")
            return
        }
        let destinationPath = (currentPath as NSString).appendingPathComponent(file.name)
        let jobID = store.registerRealRemoteCopy(
            file: file,
            from: source.profile,
            to: profile,
            targetPath: destinationPath
        )
        let control = store.makeTransferControl(for: jobID)
        let observer = SFTPTransferObserver(jobID: jobID, store: store)
        store.markTransferRunning(jobID)
        Task {
            do {
                if file.isSymbolicLink {
                    try await Task.detached(priority: .userInitiated) {
                        try destinationHandle.copySymbolicLinkFrom(
                            source: sourceHandle,
                            sourcePath: file.path,
                            destinationPath: destinationPath
                        )
                    }.value
                } else {
                    try await Task.detached(priority: .userInitiated) {
                        try destinationHandle.copyFromControlled(
                            source: sourceHandle,
                            sourcePath: file.path,
                            destinationPath: destinationPath,
                            isDirectory: file.isDirectory,
                            totalBytes: UInt64(max(file.size, 1)),
                            control: control,
                            observer: observer
                        )
                    }.value
                }
                store.markTransferSucceeded(jobID)
                refresh()
            } catch {
                if case CoreError.TransferCancelled = error {
                    store.cancel(jobID: jobID)
                } else {
                    store.markTransferFailed(jobID, message: Self.message(for: error))
                }
            }
        }
    }

    public func createDirectory(named name: String, in directory: String? = nil) {
        guard let handle else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains("/") else {
            errorMessage = L10n.text("文件夹名称不能为空，也不能包含 /。")
            return
        }
        let path = ((directory ?? currentPath) as NSString).appendingPathComponent(cleaned)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try handle.createDirectory(path: path)
                }.value
                refresh()
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    public func createFile(named name: String, in directory: String? = nil) {
        guard let handle else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains("/") else {
            errorMessage = L10n.text("文件名称不能为空，也不能包含 /。")
            return
        }
        let path = ((directory ?? currentPath) as NSString).appendingPathComponent(cleaned)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try handle.createFile(path: path)
                }.value
                refresh()
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    public func rename(_ file: RemoteFile, to newName: String) {
        guard let handle else { return }
        let cleaned = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains("/") else {
            errorMessage = L10n.text("新名称不能为空，也不能包含 /。")
            return
        }
        let parent = (file.path as NSString).deletingLastPathComponent
        let destination = (parent as NSString).appendingPathComponent(cleaned)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try handle.rename(source: file.path, destination: destination)
                }.value
                refresh()
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    public func setPermissions(_ file: RemoteFile, mode: UInt32, recursively: Bool = false) {
        guard let handle else { return }
        guard mode <= 0o7777 else {
            errorMessage = L10n.text("权限必须是 0000 到 7777 之间的三位或四位八进制数字。")
            return
        }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    if recursively {
                        try handle.setPermissionsRecursive(path: file.path, mode: mode)
                    } else {
                        try handle.setPermissions(path: file.path, mode: mode)
                    }
                }.value
                refresh()
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    public func delete(_ file: RemoteFile) {
        delete(files: [file])
    }

    public func delete(files: [RemoteFile]) {
        guard let handle, !isDeleting, loadingPath == nil else { return }
        // Snapshot and de-duplicate confirmed targets before asynchronous work.
        let targets = SFTPDeletionBatch.targets(files)
        guard !targets.isEmpty else { return }
        let directory = currentPath
        isDeleting = true
        deletionError = nil
        Task {
            let failures = await Task.detached(priority: .userInitiated) {
                var failures: [String] = []
                for file in targets {
                    do {
                        if SFTPDeletionBatch.usesRecursiveRemoval(file) {
                            try handle.removeDirectoryRecursive(path: file.path)
                        } else {
                            try handle.removeFile(path: file.path)
                        }
                    } catch {
                        failures.append(L10n.format("%@：%@", file.name, Self.message(for: error)))
                    }
                }
                return failures
            }.value
            isDeleting = false
            directoryCache.removeValue(forKey: directory)
            if currentPath == directory { refresh() }
            if !failures.isEmpty {
                deletionError = L10n.plural("已删除 %@ 项，%@ 项失败。\n", count: targets.count - failures.count, targets.count - failures.count, failures.count) + failures.joined(separator: "\n")
            }
        }
    }

    public static func runtime(id: UUID) -> SFTPRuntime? {
        registry = registry.filter { $0.value.value != nil }
        return registry[id]?.value
    }

    public func dismissDeletionError() { deletionError = nil }

    public static func connectedRuntimes(excluding id: WorkspaceTabID) -> [SFTPRuntime] {
        registry = registry.filter { $0.value.value != nil }
        return registry.values
            .compactMap(\.value)
            .filter { $0.id != id && $0.connectionState == .connected }
    }

    private func handleCoreError(_ error: CoreError) {
        connectionState = .failed
        switch error {
        case let .HostKeyUnknown(host, port, algorithm, fingerprint):
            pendingHostKey = SFTPHostKeyPrompt(
                host: host,
                port: Int(port),
                algorithm: algorithm,
                fingerprint: fingerprint
            )
            errorMessage = nil
        case let .HostKeyMismatch(host, port, algorithm, fingerprint, previousFingerprints):
            pendingHostKey = SFTPHostKeyPrompt(
                host: host, port: Int(port), algorithm: algorithm, fingerprint: fingerprint,
                previousFingerprints: previousFingerprints
            )
            errorMessage = nil
        default:
            errorMessage = Self.message(for: error)
        }
    }

    private static func remoteFiles(from entries: [CoreRemoteEntry]) -> [RemoteFile] {
        entries.map { entry in
            RemoteFile(
                name: entry.name,
                path: entry.path,
                isDirectory: entry.isDirectory,
                isSymbolicLink: entry.isSymbolicLink,
                linkTarget: entry.linkTarget,
                size: entry.size,
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(entry.modifiedAt)),
                permissions: entry.permissions
            )
        }
    }

    private nonisolated static func authentication(for profile: SSHProfile) throws -> SFTPAuthentication {
        switch profile.authMethod {
        case .password:
            guard let account = profile.keychainAccount,
                  let password = try CredentialStore.readData(account: account) else {
                throw SFTPRuntimeError.missingPassword
            }
            return .password(password)
        case .privateKey:
            guard let bookmark = profile.privateKeyBookmark else {
                throw SFTPRuntimeError.missingPrivateKey
            }
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard !stale, url.startAccessingSecurityScopedResource() else {
                throw SFTPRuntimeError.stalePrivateKey
            }
            let passphrase = try profile.keychainAccount.flatMap { try CredentialStore.readData(account: $0) }
            return .privateKey(path: url.path, passphrase: passphrase, scopedURL: url)
        }
    }

    /// Downloads a remote file into the local cache and hands the copy to the system.
    ///
    /// The cache obeys the user's Settings: location, retention and size limit. Only
    /// files this app created inside that location are ever trimmed.
    private func downloadAndOpen(_ file: RemoteFile, cache: RemoteOpenCacheConfiguration) {
        guard let handle else {
            errorMessage = L10n.text("SFTP 尚未连接，无法打开远程文件。")
            return
        }
        let profileID = profile.id
        Task {
            do {
                let target = try await Task.detached(priority: .userInitiated) { () -> URL in
                    let location = RemoteOpenCache.location(bookmark: cache.directoryBookmark, accessScope: true)
                    defer { if location.scoped { location.url.stopAccessingSecurityScopedResource() } }
                    try RemoteOpenCache.prepare(directory: location.url, owned: location.isDefault)
                    _ = try? RemoteOpenCache.prune(
                        root: location.url,
                        policy: cache.policy,
                        sizeLimit: cache.sizeLimit
                    )
                    let directory = RemoteOpenCache.profileDirectory(root: location.url, profileID: profileID)
                    try RemoteOpenCache.prepare(directory: directory, owned: true)
                    let target = RemoteOpenCache.fileURL(in: directory, remotePath: file.path, fileName: file.name)
                    try RemoteOpenCache.store(at: target) { temporary in
                        try handle.download(remotePath: file.path, localPath: temporary.path)
                    }
                    if location.isDefault { RemoteOpenCache.excludeFromBackup(target) }
                    return target
                }.value
                NSWorkspace.shared.open(target)
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    nonisolated private static func message(for error: Error) -> String {
        switch error {
        case let CoreError.Connection(message, stage): CoreErrorText.text(message, stage: stage, fallback: "SFTP 连接失败：%@")
        case let CoreError.Authentication(message, stage): CoreErrorText.text(message, stage: stage, fallback: "SFTP 认证失败：%@")
        case let CoreError.InvalidInput(message): L10n.format("SFTP 参数无效：%@", message)
        case let CoreError.Conflict(path): L10n.format("目标已存在：%@。当前安全策略不会自动覆盖，请重命名后重试。", path)
        case CoreError.TransferCancelled: L10n.text("传输已取消。")
        default: String(describing: error)
        }
    }

    nonisolated private static var knownHostsPath: String {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Snake/known_hosts").path
    }
}

enum RemotePermissionMode {
    static func parse(_ value: String) -> UInt32? {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.hasPrefix("0o") { cleaned.removeFirst(2) }
        guard (3...4).contains(cleaned.count),
              cleaned.allSatisfy({ ("0"..."7").contains($0) }),
              let mode = UInt32(cleaned, radix: 8),
              mode <= 0o7777 else { return nil }
        return mode
    }

    static func display(_ value: String, isDirectory: Bool) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if parse(cleaned) != nil {
            return String(cleaned.suffix(4))
        }
        return isDirectory ? "0755" : "0644"
    }
}

enum RemotePermissionBit: UInt32, CaseIterable {
    case ownerRead = 0o400
    case ownerWrite = 0o200
    case ownerExecute = 0o100
    case groupRead = 0o040
    case groupWrite = 0o020
    case groupExecute = 0o010
    case otherRead = 0o004
    case otherWrite = 0o002
    case otherExecute = 0o001
}

struct RemotePermissionSelection: Equatable {
    private(set) var mode: UInt32

    init(modeText: String, isDirectory: Bool) {
        let displayed = RemotePermissionMode.display(modeText, isDirectory: isDirectory)
        mode = RemotePermissionMode.parse(displayed) ?? (isDirectory ? 0o755 : 0o644)
    }

    func contains(_ bit: RemotePermissionBit) -> Bool {
        mode & bit.rawValue != 0
    }

    mutating func set(_ bit: RemotePermissionBit, enabled: Bool) {
        if enabled {
            mode |= bit.rawValue
        } else {
            mode &= ~bit.rawValue
        }
    }

    var display: String {
        String(format: "%04o", mode)
    }
}

public struct SFTPHostKeyPrompt: Identifiable, Sendable {
    public let id = UUID()
    public let host: String
    public let port: Int
    public let algorithm: String
    public let fingerprint: String
    public var previousFingerprints: [String]? = nil

    var title: String { previousFingerprints == nil ? L10n.text("确认主机密钥") : L10n.text("主机密钥已变化") }
    var acceptTitle: String { previousFingerprints == nil ? L10n.text("信任并连接") : L10n.text("信任新密钥并连接") }
    var message: String {
        if let previousFingerprints {
            let previous = previousFingerprints.isEmpty ? L10n.text("无法读取原指纹") : previousFingerprints.joined(separator: "\n")
            return L10n.format("%@:%@ 的主机密钥与已保存的记录不同。\n\n原指纹：\n%@\n\n新指纹（%@）：\n%@\n\n这可能是服务器重装或更换密钥，也可能是连接被冒充。请通过可信渠道核对新指纹。信任后将更新此地址的记录并重新连接；取消则保留原记录。",
                              host, String(port), previous, algorithm, fingerprint)
        }
        return L10n.format("首次连接 %@:%@\n%@\n%@\n\n请在可信渠道核对指纹后再信任。",
                           host, String(port), algorithm, fingerprint)
    }
}

public struct SFTPUploadRecord: Identifiable, Sendable {
    public var id: UUID { jobID }
    public let jobID: UUID
    public let fileName: String
    public let remotePath: String
    public let fileSize: Int64
    public let startedAt: Date
    public var finishedAt: Date?
    public var state: TransferState
    let localURL: URL
    let overwrite: Bool
    var isDownload = false
    var verification: TransferVerification = .pending

    init(
        jobID: UUID,
        fileName: String,
        remotePath: String,
        fileSize: Int64,
        startedAt: Date,
        finishedAt: Date? = nil,
        state: TransferState,
        localURL: URL,
        overwrite: Bool
    ) {
        self.jobID = jobID
        self.fileName = fileName
        self.remotePath = remotePath
        self.fileSize = fileSize
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.state = state
        self.localURL = localURL
        self.overwrite = overwrite
    }

    public func duration(at date: Date = .now) -> TimeInterval {
        max(0, (finishedAt ?? date).timeIntervalSince(startedAt))
    }
}

public struct SFTPUploadConflictPrompt: Identifiable, Sendable {
    public let id = UUID()
    public let localName: String
    public let remotePath: String
}

public enum SFTPUploadConflictDecision: Sendable {
    case overwrite
    case skip
    case cancel
}

private enum SFTPAuthentication: Sendable {
    case password(Data)
    case privateKey(path: String, passphrase: Data?, scopedURL: URL)
}

struct SFTPUploadItem: Sendable {
    let localURL: URL
    let remotePath: String
    let size: Int64
    let isDirectory: Bool
}

struct SFTPUploadRange: Sendable {
    let offset: UInt64
    let length: UInt64
}

private final class WeakSFTPRuntime {
    weak var value: SFTPRuntime?
    init(_ value: SFTPRuntime) { self.value = value }
}

private final class SFTPTransferObserver: CoreTransferObserver, @unchecked Sendable {
    private let jobID: UUID
    private weak var store: ApplicationStore?
    private let lock = NSLock()
    private var lastUpdate = Date.distantPast
    private var lastBytes: UInt64 = 0

    init(jobID: UUID, store: ApplicationStore) {
        self.jobID = jobID
        self.store = store
    }

    func onProgress(completedBytes: UInt64, totalBytes: UInt64) {
        lock.lock()
        let now = Date()
        let elapsed = now.timeIntervalSince(lastUpdate)
        guard elapsed >= 0.1 || completedBytes >= totalBytes else {
            lock.unlock()
            return
        }
        let delta = completedBytes.saturatingSubtract(lastBytes)
        let speed = elapsed > 0 && lastUpdate != .distantPast ? Int64(Double(delta) / elapsed) : 0
        lastUpdate = now
        lastBytes = completedBytes
        lock.unlock()
        Task { @MainActor [weak store] in
            store?.updateRealTransferProgress(
                jobID,
                completed: Int64(clamping: completedBytes),
                total: Int64(clamping: totalBytes),
                speed: speed
            )
        }
    }
}

final class SFTPPartTransferObserver: CoreTransferObserver, @unchecked Sendable {
    private let index: Int
    private let progress: SFTPMultipartProgress

    init(index: Int, progress: SFTPMultipartProgress) {
        self.index = index
        self.progress = progress
    }

    func onProgress(completedBytes: UInt64, totalBytes: UInt64) {
        progress.update(part: index, completedBytes: min(completedBytes, totalBytes))
    }
}

final class SFTPMultipartProgress: @unchecked Sendable {
    private let jobID: UUID
    private let totalBytes: UInt64
    private weak var store: ApplicationStore?
    private let lock = NSLock()
    private var parts: [Int: UInt64] = [:]
    private var lastUpdate = Date.distantPast
    private var lastAggregate = UInt64(0)

    init(jobID: UUID, totalBytes: UInt64, store: ApplicationStore) {
        self.jobID = jobID
        self.totalBytes = totalBytes
        self.store = store
    }

    func update(part: Int, completedBytes: UInt64) {
        lock.lock()
        parts[part] = completedBytes
        let aggregate = min(parts.values.reduce(0, +), totalBytes)
        let now = Date()
        let elapsed = now.timeIntervalSince(lastUpdate)
        guard elapsed >= 0.1 || aggregate >= totalBytes else {
            lock.unlock()
            return
        }
        let delta = aggregate.saturatingSubtract(lastAggregate)
        let speed = elapsed > 0 && lastUpdate != .distantPast ? Int64(Double(delta) / elapsed) : 0
        lastUpdate = now
        lastAggregate = aggregate
        lock.unlock()
        Task { @MainActor [weak store] in
            store?.updateRealTransferProgress(
                jobID,
                completed: Int64(clamping: aggregate),
                total: Int64(clamping: totalBytes),
                speed: speed
            )
        }
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}

private enum SFTPRuntimeError: LocalizedError {
    case missingPassword
    case missingPrivateKey
    case stalePrivateKey

    var errorDescription: String? {
        switch self {
        case .missingPassword: L10n.text("此会话尚未保存密码，请编辑会话后加密保存密码。")
        case .missingPrivateKey: L10n.text("此会话尚未选择私钥文件。")
        case .stalePrivateKey: L10n.text("私钥访问授权已失效，请重新选择私钥文件。")
        }
    }
}

@MainActor
public final class WorkspaceTabRuntime: ObservableObject, Identifiable {
    public let id: WorkspaceTabID
    @Published public private(set) var kind: WorkspaceTabKind
    public private(set) var profile: SSHProfile?
    public private(set) var terminal: TerminalRuntime?
    public private(set) var sftp: SFTPRuntime?
    @Published var searchQuery = ""
    @Published var selectedTags = Set<String>()
    @Published var selectedProfileID: UUID?
    @Published var selectedMappingID: UUID?
    @Published var searchFocusRequest = 0
    private var handledSearchFocusRequest = 0

    func takeSearchFocusRequest() -> Bool {
        guard kind == .sessions, searchFocusRequest > handledSearchFocusRequest else { return false }
        handledSearchFocusRequest = searchFocusRequest
        return true
    }

    init(manager kind: WorkspaceTabKind = .sessions) {
        precondition(kind == .sessions || kind == .mounts)
        id = WorkspaceTabID()
        self.kind = kind
    }

    /// Only a chooser may become a connection. The identity survives the change.
    func connect(profile: SSHProfile, asSFTP: Bool) -> Bool {
        guard kind == .sessions else { return false }
        self.profile = profile
        if asSFTP {
            sftp = SFTPRuntime(profile: profile)
            kind = .sftp(profileID: profile.id)
        } else {
            terminal = TerminalRuntime(profile: profile)
            kind = .terminal(profileID: profile.id)
            terminal?.requestConnection()
        }
        return true
    }

    init(terminal profile: SSHProfile) {
        id = WorkspaceTabID()
        kind = .terminal(profileID: profile.id)
        self.profile = profile
        let terminalRuntime = TerminalRuntime(profile: profile)
        terminal = terminalRuntime
        sftp = nil
        terminalRuntime.requestConnection()
    }

    init(sftp profile: SSHProfile) {
        id = WorkspaceTabID()
        kind = .sftp(profileID: profile.id)
        self.profile = profile
        terminal = nil
        sftp = SFTPRuntime(profile: profile)
    }

    public var title: String {
        switch kind {
        case .sessions: L10n.text("SSH 会话")
        case .mounts: L10n.text("磁盘映射")
        case .terminal: L10n.format("终端 · %@", profile?.name ?? "")
        case .sftp: L10n.format("SFTP · %@", profile?.name ?? "")
        }
    }

    var finderUploadTarget: FinderUploadTarget {
        if let terminal {
            guard terminal.state == .connected else { return .unavailable(L10n.text("请先完成 SSH 连接")) }
            return terminal.currentRemoteDirectory.map(FinderUploadTarget.directory) ?? .confirmDirectory
        }
        if let sftp { return sftp.finderUploadTarget }
        return .unavailable(L10n.text("请先完成 SFTP 连接"))
    }

    func uploadFromFinder(urls: [URL], target: FinderUploadTarget, window: NSWindow, store: ApplicationStore) {
        if let terminal {
            terminal.uploadFromFinder(urls: urls, target: target, window: window, store: store)
        } else if let sftp, sftp.connectionState == .connected, case .directory(let path) = target {
            sftp.upload(urls: urls, to: path, store: store)
        }
    }

    public func close() {
        terminal?.stop()
        sftp?.disconnect()
    }
}

@MainActor
public final class WorkspaceWindowState: ObservableObject, Identifiable {
    public let id: WindowID
    public let bonsplit: BonsplitController
    @Published public private(set) var tabs: [TabID: WorkspaceTabRuntime] = [:]
    @Published public private(set) var activePaneID: PaneID?
    var tabDetachHandler: ((WorkspaceWindowState, TabID, PaneID) -> Void)?

    init(id: WindowID = WindowID()) {
        self.id = id
        bonsplit = BonsplitController(configuration: BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: false,
            allowCloseLastPane: false,
            allowTabReordering: true,
            allowCrossPaneTabMove: true,
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .current,
            appearance: .init(
                tabBarHeight: 34,
                tabMinWidth: 150,
                tabMaxWidth: 260,
                tabSpacing: 0,
                minimumPaneWidth: 260,
                minimumPaneHeight: 180,
                showSplitButtons: true,
                animationDuration: 0.15,
                enableAnimations: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
        ))
        bonsplit.usesNativeDragRouting = true
        // Bonsplit's default controller seeds a documentation "Welcome" tab.
        // Snake starts with an intentionally empty workspace instead.
        for defaultTab in bonsplit.allTabIds {
            _ = bonsplit.closeTab(defaultTab)
        }
        activePaneID = bonsplit.focusedPaneId
        bonsplit.onActivePaneChange = { [weak self] paneID in
            self?.activePaneID = paneID
        }
        bonsplit.onTabBarTrailingDoubleClick = { [weak self] paneID in
            _ = self?.openManager(.sessions, to: paneID)
        }
        bonsplit.onTabContextAction = { [weak self] tabID, paneID, action in
            self?.performTabContextAction(action, tabID: tabID, paneID: paneID)
        }
    }

    public var selectedRuntime: WorkspaceTabRuntime? {
        guard let pane = activePaneID ?? bonsplit.focusedPaneId,
              let tab = bonsplit.selectedTab(inPane: pane) else { return nil }
        return tabs[tab.id]
    }

    /// Resolve the visible tab owning a focused native upload surface. The
    /// last-focused pane alone can lag behind AppKit's current first responder.
    func visibleRuntime(id: WorkspaceTabID) -> WorkspaceTabRuntime? {
        for paneID in bonsplit.allPaneIds {
            guard let tab = bonsplit.selectedTab(inPane: paneID),
                  let runtime = tabs[tab.id], runtime.id == id else { continue }
            activePaneID = paneID
            return runtime
        }
        return nil
    }

    @discardableResult
    func add(_ runtime: WorkspaceTabRuntime, to pane: PaneID? = nil, at index: Int? = nil) -> Bool {
        if let pane, !bonsplit.allPaneIds.contains(pane) { return false }
        guard let tabID = bonsplit.createTab(title: runtime.title, icon: runtime.kind.symbolName, inPane: pane, at: index) else { return false }
        tabs[tabID] = runtime
        bonsplit.selectTab(tabID)
        return true
    }

    @discardableResult
    func openManager(_ kind: WorkspaceTabKind, to pane: PaneID? = nil) -> Bool {
        let runtime = WorkspaceTabRuntime(manager: kind)
        if kind == .sessions { runtime.searchFocusRequest = 1 }
        return add(runtime, to: pane ?? activePaneID ?? bonsplit.focusedPaneId)
    }

    func focusSessionSearch() {
        if selectedRuntime?.kind != .sessions {
            openManager(.sessions)
            return
        }
        selectedRuntime?.searchFocusRequest += 1
    }

    @discardableResult
    func connectChooser(tabID: TabID, profileID: UUID, asSFTP: Bool, store: ApplicationStore) -> Bool {
        objectWillChange.send()
        guard let runtime = tabs[tabID], runtime.kind == .sessions,
              let profile = store.profiles.first(where: { $0.id == profileID }),
              runtime.connect(profile: profile, asSFTP: asSFTP) else { return false }
        bonsplit.updateTab(tabID, title: runtime.title, icon: runtime.kind.symbolName)
        bonsplit.selectTab(tabID)
        return true
    }

    func closeSelectedTab() {
        guard let pane = bonsplit.focusedPaneId,
              let tab = bonsplit.selectedTab(inPane: pane),
              let runtime = tabs[tab.id] else { return }
        runtime.close()
        _ = bonsplit.closeTab(tab.id, inPane: pane)
        tabs.removeValue(forKey: tab.id)
    }

    func performTabContextAction(_ action: TabContextAction, tabID: TabID, paneID: PaneID) {
        guard tabs[tabID] != nil else { return }
        activePaneID = paneID
        bonsplit.selectTab(tabID)
        switch action {
        case .splitHorizontal:
            _ = bonsplit.splitPane(paneID, orientation: .horizontal)
        case .splitVertical:
            _ = bonsplit.splitPane(paneID, orientation: .vertical)
        case .close:
            close(tabID: tabID, paneID: paneID)
        case .closeOthers:
            closeOtherTabs(keeping: tabID, in: paneID)
        case .detach:
            tabDetachHandler?(self, tabID, paneID)
        }
    }

    private func close(tabID: TabID, paneID: PaneID) {
        guard let runtime = tabs[tabID] else { return }
        runtime.close()
        _ = bonsplit.closeTab(tabID, inPane: paneID)
        tabs.removeValue(forKey: tabID)
    }

    private func closeOtherTabs(keeping tabID: TabID, in paneID: PaneID) {
        let otherTabs = bonsplit.tabs(inPane: paneID).map(\.id).filter { $0 != tabID }
        for otherTabID in otherTabs {
            close(tabID: otherTabID, paneID: paneID)
        }
        bonsplit.selectTab(tabID)
    }

    var canCloseCurrentItem: Bool {
        guard let pane = resolvedActivePaneID else { return false }
        return bonsplit.selectedTab(inPane: pane) != nil || bonsplit.allPaneIds.count > 1
    }

    /// Implements the workspace meaning of Command-W: close the selected tab in
    /// the last interacted pane, otherwise close that empty split. The final
    /// empty pane intentionally stays open.
    @discardableResult
    func closeCurrentItem() -> Bool {
        guard let pane = resolvedActivePaneID else { return false }
        if let tab = bonsplit.selectedTab(inPane: pane) {
            close(tabID: tab.id, paneID: pane)
            return true
        }
        guard bonsplit.allPaneIds.count > 1 else { return false }
        return bonsplit.closePane(pane)
    }

    private var resolvedActivePaneID: PaneID? {
        if let activePaneID, bonsplit.allPaneIds.contains(activePaneID) {
            return activePaneID
        }
        return bonsplit.focusedPaneId
    }

    func extractSelectedRuntime() -> WorkspaceTabRuntime? {
        guard let pane = bonsplit.focusedPaneId,
              let tab = bonsplit.selectedTab(inPane: pane) else { return nil }
        return extract(tab.id, from: pane)
    }

    func extract(_ tabID: TabID, from pane: PaneID) -> WorkspaceTabRuntime? {
        guard let runtime = tabs[tabID] else { return nil }
        guard bonsplit.closeTab(tabID, inPane: pane) else { return nil }
        tabs.removeValue(forKey: tabID)
        return runtime
    }

    func closeTabs(profileID: UUID) {
        let matching = tabs.filter { $0.value.profile?.id == profileID }
        for (tabID, runtime) in matching {
            runtime.close()
            _ = bonsplit.closeTab(tabID)
            tabs.removeValue(forKey: tabID)
        }
    }

    @discardableResult
    func splitFocusedPane(_ orientation: SplitOrientation) -> PaneID? {
        bonsplit.splitPane(orientation: orientation)
    }

}

@MainActor
public final class WorkspaceWindowCoordinator: NSObject {
    private let store: ApplicationStore
    private var windows: [WindowID: WindowRecord] = [:]
    private var parkedWindows: [ParkedWindowRecord] = []
    private var discardOnClose: Set<WindowID> = []
    private var sftpSearchMenuItem: NSMenuItem?
    private var sftpDeleteMenuItem: NSMenuItem?
    private var sftpUploadMenuItem: NSMenuItem?
    private var newSessionTabMenuItem: NSMenuItem?
    private var fileMenuItem: NSMenuItem?
    nonisolated(unsafe) private var sftpShortcutMonitor: Any?
    private(set) lazy var dragging = WorkspaceDragCoordinator(owner: self)

    init(store: ApplicationStore) {
        self.store = store
        super.init()
        _ = dragging
        // Menus (including SwiftUI's rebuilt Edit menu) may consume Command-F
        // before a window's performKeyEquivalent runs. Scope the early monitor
        // to the actual key Snake window; the window override is the fallback.
        sftpShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = NSApp.keyWindow as? SnakeWorkspaceWindow,
                  event.window == nil || event.window === window else { return event }
            if self.handleNewSessionTabShortcut(event, in: window) { return nil }
            return self.handleSFTPShortcut(event, in: window) ? nil : event
        }
    }

    deinit { if let sftpShortcutMonitor { NSEvent.removeMonitor(sftpShortcutMonitor) } }

    func handleNewSessionTabShortcut(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown,
              (event.window === window || (event.window == nil && NSApp.keyWindow === window)),
              SFTPShortcut.from(event: event) == store.newSessionTabShortcut,
              let record = windows.values.first(where: { $0.window === window }) else { return false }
        guard !event.isARepeat, NSApp.modalWindow == nil, window.attachedSheet == nil,
              dragging.active == nil else { return true }
        record.state.openManager(.sessions)
        return true
    }

    /// The window receiving the key equivalent is authoritative. App-wide
    /// monitors can see a stale key window while SwiftUI rebuilds Settings.
    func handleSFTPShortcut(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown,
              (event.window === window || (event.window == nil && NSApp.keyWindow === window)),
              let record = windows.values.first(where: { $0.window === window }),
              let runtime = record.state.selectedRuntime?.sftp,
              NSApp.modalWindow == nil,
              window.attachedSheet == nil else { return false }
        guard dragging.active == nil,
              let action = SFTPShortcutPolicy.action(for: event, configured: store.sftpShortcuts) else { return false }
        // Holding the key must not reopen file pickers or repeat confirmation.
        if !event.isARepeat {
            switch action {
            case .search:
                if runtime.canSearchWithShortcut { runtime.requestSearchCommand() }
                else { runtime.showShortcutUnavailableNotice() }
            case .delete:
                if !keyWindowIsEditingText && runtime.canDeleteWithShortcut { runtime.requestDeleteCommand() }
            case .uploadFile:
                if runtime.canUploadFileWithShortcut { runtime.requestUploadFileCommand() }
                else { runtime.showShortcutUnavailableNotice() }
            }
        }
        return true
    }

    func installApplicationCommands() {
        guard let mainMenu = NSApp.mainMenu else {
            DispatchQueue.main.async { [weak self] in self?.installApplicationCommands() }
            return
        }

        // Locate the menu by action rather than by title so it survives a
        // language change.
        let workspaceActions: Set<Selector> = [
            #selector(closeCurrentItem(_:)), #selector(newSessionTab(_:)),
            #selector(searchSFTP(_:)), #selector(deleteSFTPSelection(_:)), #selector(uploadSFTPFile(_:))
        ]
        let fileMenu: NSMenu
        if let existing = mainMenu.items.first(where: { item in
            item.submenu?.items.contains { submenuItem in
                guard let action = submenuItem.action else { return false }
                return workspaceActions.contains(action)
            } == true
        })?.submenu {
            fileMenu = existing
        } else {
            let rootItem = NSMenuItem(title: L10n.text("文件"), action: nil, keyEquivalent: "")
            fileMenu = NSMenu(title: L10n.text("文件"))
            rootItem.submenu = fileMenu
            mainMenu.insertItem(rootItem, at: min(1, mainMenu.items.count))
        }
        fileMenuItem = mainMenu.items.first { $0.submenu === fileMenu }

        if fileMenu.items.contains(where: { $0.action == #selector(closeCurrentItem(_:)) }) == false {
            let closeItem = NSMenuItem(title: L10n.text("关闭标签"), action: #selector(closeCurrentItem(_:)), keyEquivalent: "w")
            closeItem.keyEquivalentModifierMask = [.command]
            closeItem.target = self
            fileMenu.insertItem(closeItem, at: 0)
        }
        newSessionTabMenuItem = menuItem(in: fileMenu, title: L10n.text("新建 SSH 会话标签"),
            action: #selector(newSessionTab(_:)), existing: newSessionTabMenuItem)

        let hadSFTPCommands = fileMenu.items.contains { $0.action == #selector(searchSFTP(_:)) }
        if !hadSFTPCommands { fileMenu.addItem(.separator()) }
        sftpSearchMenuItem = menuItem(
            in: fileMenu, title: L10n.text("在 SFTP 中检索"), action: #selector(searchSFTP(_:)), existing: sftpSearchMenuItem)
        sftpDeleteMenuItem = menuItem(
            in: fileMenu, title: L10n.text("删除所选 SFTP 项目…"), action: #selector(deleteSFTPSelection(_:)), existing: sftpDeleteMenuItem)
        sftpUploadMenuItem = menuItem(
            in: fileMenu, title: L10n.text("上传文件到 SFTP…"), action: #selector(uploadSFTPFile(_:)), existing: sftpUploadMenuItem)
        localizeMenuTitles(fileMenu)
        applyConfiguredShortcuts()
    }

    /// Re-applies the interface language to the application menu.
    func applyLocalization() {
        installApplicationCommands()
    }

    private func localizeMenuTitles(_ fileMenu: NSMenu) {
        fileMenuItem?.title = L10n.text("文件")
        fileMenu.title = L10n.text("文件")
        for item in fileMenu.items {
            guard let action = item.action else { continue }
            switch action {
            case #selector(closeCurrentItem(_:)): item.title = L10n.text("关闭标签")
            case #selector(newSessionTab(_:)): item.title = L10n.text("新建 SSH 会话标签")
            case #selector(searchSFTP(_:)): item.title = L10n.text("在 SFTP 中检索")
            case #selector(deleteSFTPSelection(_:)): item.title = L10n.text("删除所选 SFTP 项目…")
            case #selector(uploadSFTPFile(_:)): item.title = L10n.text("上传文件到 SFTP…")
            default: break
            }
        }
    }

    private func menuItem(in menu: NSMenu, title: String, action: Selector, existing: NSMenuItem?) -> NSMenuItem {
        if let existing, existing.menu === menu { existing.target = self; return existing }
        if let item = menu.items.first(where: { $0.action == action }) { item.target = self; return item }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    func refreshApplicationCommands() {
        installApplicationCommands()
    }

    private func applyConfiguredShortcuts() {
        configure(newSessionTabMenuItem, shortcut: store.newSessionTabShortcut)
        configure(sftpSearchMenuItem, shortcut: store.sftpSearchShortcut)
        configure(sftpDeleteMenuItem, shortcut: store.sftpDeleteShortcut)
        configure(sftpUploadMenuItem, shortcut: store.sftpUploadShortcut)
        NSApp.mainMenu?.update()
    }

    private func configure(_ item: NSMenuItem?, shortcut: SFTPShortcut) {
        item?.keyEquivalent = shortcut.keyEquivalent
        item?.keyEquivalentModifierMask = shortcut.modifiers
    }

    func register(window: NSWindow, state: WorkspaceWindowState) {
        guard windows[state.id] == nil else { return }
        (window as? SnakeWorkspaceWindow)?.workspaceCoordinator = self
        window.title = "Snake"
        window.titleVisibility = .hidden
        // Keep sidebar material and split dividers below the full-width header.
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .line
        window.isRestorable = false
        window.minSize = NSSize(width: 1024, height: 700)
        let delegate = SnakeWindowDelegate(id: state.id, coordinator: self)
        window.delegate = delegate
        window.registerForDraggedTypes([.fileURL] + WorkspaceDragPayload.types)
        installExternalDragHandler(on: state)
        windows[state.id] = WindowRecord(window: window, controller: nil, state: state, delegate: delegate)
    }

    func openInitialWindow() {
        guard windows.isEmpty else { return }
        _ = createWindow(initialRuntime: WorkspaceTabRuntime(manager: .sessions))
    }

    func openTerminal(for profile: SSHProfile) {
        guard let window = activeWindowRecord else {
            let state = createWindow()
            state.add(WorkspaceTabRuntime(terminal: profile))
            return
        }
        window.state.add(WorkspaceTabRuntime(terminal: profile))
    }

    func openSFTP(for profile: SSHProfile) {
        guard let window = activeWindowRecord else {
            let state = createWindow()
            state.add(WorkspaceTabRuntime(sftp: profile))
            return
        }
        window.state.add(WorkspaceTabRuntime(sftp: profile))
    }

    func closeConnections(profileID: UUID) {
        for record in windows.values {
            record.state.closeTabs(profileID: profileID)
        }
    }

    func detachSelectedTab(from state: WorkspaceWindowState) {
        guard let paneID = state.bonsplit.focusedPaneId,
              let tab = state.bonsplit.selectedTab(inPane: paneID) else { return }
        detach(tabID: tab.id, paneID: paneID, from: state)
    }

    func closeWindow(id: WindowID) {
        guard let record = windows.removeValue(forKey: id) else { return }
        if discardOnClose.remove(id) != nil { return }

        parkedWindows.removeAll { $0.state.id == id }
        parkedWindows.append(ParkedWindowRecord(
            state: record.state,
            frame: record.window?.frame
        ))
    }

    @discardableResult
    private func createWindow(
        state: WorkspaceWindowState = WorkspaceWindowState(),
        initialRuntime: WorkspaceTabRuntime? = nil,
        near point: NSPoint? = nil,
        restoring frame: NSRect? = nil
    ) -> WorkspaceWindowState {
        let rootView = SnakeWorkspaceRootView(windowState: state)
            .environmentObject(store)
        let controller = NSWindowController()
        let window = SnakeWorkspaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.workspaceCoordinator = self
        window.title = "Snake"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .line
        window.isRestorable = false
        window.minSize = NSSize(width: 1024, height: 700)
        if let frame {
            window.setFrame(frame, display: false)
        } else {
            place(window: window, near: point)
        }
        let delegate = SnakeWindowDelegate(id: state.id, coordinator: self)
        window.delegate = delegate
        window.registerForDraggedTypes([.fileURL] + WorkspaceDragPayload.types)
        let hosting = WorkspaceHostingView(rootView: rootView)
        hosting.workspaceCoordinator = self
        window.contentView = hosting
        controller.window = window
        installExternalDragHandler(on: state)
        windows[state.id] = WindowRecord(window: window, controller: controller, state: state, delegate: delegate)
        controller.showWindow(nil)
        if let initialRuntime { state.add(initialRuntime) }
        return state
    }

    func reopenWindows() {
        let visibleWindows = windows.values.compactMap(\.window).filter(\.isVisible)
        if let window = visibleWindows.first {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let records = parkedWindows
        parkedWindows.removeAll()
        if records.isEmpty {
            _ = createWindow(initialRuntime: WorkspaceTabRuntime(manager: .sessions))
        } else {
            for record in records {
                _ = createWindow(state: record.state, restoring: record.frame)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installExternalDragHandler(on state: WorkspaceWindowState) {
        state.tabDetachHandler = { [weak self] source, tabID, paneID in
            self?.detach(tabID: tabID, paneID: paneID, from: source)
        }
    }

    private func detach(tabID: TabID, paneID: PaneID, from state: WorkspaceWindowState) {
        detachDraggedTab(.tab(windowID: state.id, tabID: tabID), near: nil)
    }

    func workspaceState(for window: NSWindow) -> WorkspaceWindowState? {
        windows.values.first { $0.window === window }?.state
    }

    func dragWindow(at point: NSPoint) -> (NSWindow, WorkspaceWindowState)? {
        for window in NSApp.orderedWindows where window.isVisible && !window.isMiniaturized && window.frame.contains(point) {
            // Panels/sheets over a workspace are invalid targets, not a reason
            // to fall through into the workspace behind them.
            guard let state = workspaceState(for: window) else { return nil }
            return (window, state)
        }
        return nil
    }

    func dragSourceExists(_ source: WorkspaceDragSource) -> Bool {
        switch source {
        case .tab(let windowID, let tabID): windows[windowID]?.state.tabs[tabID] != nil
        case .profile(let id): store.profiles.contains { $0.id == id }
        }
    }

    func containsSnakeWindow(at point: NSPoint) -> Bool {
        windows.values.contains { record in
            guard let window = record.window else { return false }
            return window.isVisible && !window.isMiniaturized && window.frame.contains(point)
        }
    }

    var visibleWorkspaceWindows: [NSWindow] {
        NSApp.orderedWindows.filter { $0.isVisible && !$0.isMiniaturized && workspaceState(for: $0) != nil }
    }

    @discardableResult
    func commitWorkspaceDrop(_ source: WorkspaceDragSource, target: WorkspaceDropTarget, openSFTP: Bool) -> Bool {
        guard let targetRecord = windows[target.windowID], targetRecord.window?.attachedSheet == nil,
              targetRecord.state.bonsplit.allPaneIds.contains(target.paneID), dragSourceExists(source) else { return false }
        let targetState = targetRecord.state
        // The content center is a target only for an empty pane. Populated
        // panes merge or reorder exclusively through their tab bar.
        if target.placement == .center, !targetState.bonsplit.tabs(inPane: target.paneID).isEmpty { return false }
        let sourceState: WorkspaceWindowState?
        let sourceTabID: TabID?
        let sourcePane: PaneID?
        let runtime: WorkspaceTabRuntime
        switch source {
        case .tab(let windowID, let tabID):
            guard let state = windows[windowID]?.state, let existing = state.tabs[tabID],
                  let pane = state.bonsplit.allPaneIds.first(where: { state.bonsplit.tabs(inPane: $0).contains { $0.id == tabID } }) else { return false }
            sourceState = state; sourceTabID = tabID; sourcePane = pane; runtime = existing
        case .profile(let id):
            guard let profile = store.profiles.first(where: { $0.id == id }) else { return false }
            sourceState = nil; sourceTabID = nil; sourcePane = nil
            runtime = openSFTP ? WorkspaceTabRuntime(sftp: profile) : WorkspaceTabRuntime(terminal: profile)
        }
        let oldFocus = targetState.activePaneID
        var destination = target.paneID
        var createdPane: PaneID?
        var insertionIndex: Int?
        if case .split(let edge) = target.placement {
            guard let pane = targetState.bonsplit.splitPane(target.paneID, orientation: edge.orientation, insertFirst: edge.insertFirst) else {
                if sourceState == nil { runtime.close() }
                return false
            }
            destination = pane; createdPane = pane
        } else if case .insert(let index) = target.placement { insertionIndex = index }
        func rollback() {
            if let createdPane { _ = targetState.bonsplit.closePane(createdPane) }
            if let oldFocus { targetState.bonsplit.focusPane(oldFocus) }
            if sourceState == nil { runtime.close() }
        }
        if sourceState === targetState, let sourceTabID {
            guard targetState.bonsplit.relocateTab(sourceTabID, to: destination, at: insertionIndex,
                                                   keepEmptySource: createdPane != nil && sourcePane == target.paneID) else { rollback(); return false }
        } else {
            let previousIDs = Set(targetState.tabs.keys)
            guard targetState.add(runtime, to: destination, at: insertionIndex) else { rollback(); return false }
            if let sourceState, let sourceTabID, let sourcePane, sourceState.extract(sourceTabID, from: sourcePane) == nil {
                if let addedID = targetState.tabs.keys.first(where: { !previousIDs.contains($0) }) { _ = targetState.extract(addedID, from: destination) }
                rollback()
                return false
            }
        }
        targetRecord.window?.makeKeyAndOrderFront(nil)
        if let sourceState, sourceState !== targetState { closeEmptyMovedWindow(sourceState) }
        return true
    }

    func detachDraggedTab(_ source: WorkspaceDragSource, near point: NSPoint?) {
        guard case .tab(let windowID, let tabID) = source, let sourceState = windows[windowID]?.state,
              let runtime = sourceState.tabs[tabID],
              let paneID = sourceState.bonsplit.allPaneIds.first(where: { sourceState.bonsplit.tabs(inPane: $0).contains { $0.id == tabID } }) else { return }
        let target = createWindow(near: point)
        guard target.add(runtime), sourceState.extract(tabID, from: paneID) != nil else {
            if let added = target.bonsplit.allTabIds.first, let pane = target.bonsplit.allPaneIds.first { _ = target.extract(added, from: pane) }
            if let window = windows[target.id]?.window { discardOnClose.insert(target.id); window.performClose(nil) }
            return
        }
        closeEmptyMovedWindow(sourceState)
    }

    private func closeEmptyMovedWindow(_ state: WorkspaceWindowState) {
        guard state.tabs.isEmpty, let record = windows[state.id], record.controller != nil, let window = record.window else { return }
        discardOnClose.insert(state.id)
        window.performClose(nil)
    }

    private func place(window: NSWindow, near point: NSPoint?) {
        guard let point else {
            window.center()
            return
        }
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(point) } ?? NSScreen.main
        guard let screen else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(
            x: min(max(visible.minX, point.x - 90), visible.maxX - size.width),
            y: min(max(visible.minY, point.y - size.height + 40), visible.maxY - size.height)
        )
        window.setFrameOrigin(origin)
    }

    private var activeWindowRecord: WindowRecord? {
        if let keyWindow = NSApp.keyWindow,
           let record = windows.values.first(where: { $0.window === keyWindow }) {
            return record
        }
        return windows.values.first
    }

    /// A Finder copy is intercepted before SwiftTerm's text-only paste and
    /// before the menu sends `paste:` to whichever split had keyboard focus.
    func handleFinderPasteShortcut(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard FinderClipboardPaste.isShortcut(event), NSApp.keyWindow === window,
              NSApp.modalWindow == nil, window.attachedSheet == nil,
              dragging.active == nil,
              let record = windows.values.first(where: { $0.window === window }),
              let responderView = window.firstResponder as? NSView,
              let surface = pasteSurface(above: responderView),
              let runtimeID = surface.pasteRuntimeID,
              let runtime = record.state.visibleRuntime(id: runtimeID) else { return false }

        // Path/search editors keep native text paste, even when Finder also
        // supplies a file URL representation on the clipboard.
        if let textView = responderView as? NSTextView, textView.isEditable || textView.isFieldEditor { return false }
        if responderView is NSTextField { return false }
        if let terminal = runtime.terminal {
            guard let terminalView = terminal.existingTerminalSurface,
                  responderView === terminalView || responderView.isDescendant(of: terminalView) else { return false }
        } else if runtime.sftp == nil {
            return false
        }

        let pasteboard = NSPasteboard.general
        guard FinderUploadPasteboard.accepts(pasteboard) else { return false }
        // Consume key repeats without opening more sheets or enqueuing twice.
        if event.isARepeat { return true }
        let urls: [URL]
        do {
            urls = try FinderUploadPasteboard.urls(from: pasteboard)
        } catch {
            showFinderPasteMessage(error.localizedDescription, in: window)
            return true
        }
        let target = runtime.finderUploadTarget
        guard target.canUpload else {
            showFinderPasteMessage(target.title, in: window)
            return true
        }
        if runtime.sftp != nil {
            runtime.uploadFromFinder(urls: urls, target: target, window: window, store: store)
            return true
        }
        presentTerminalFilePaste(urls: urls, target: target, runtime: runtime, in: window)
        return true
    }

    private func pasteSurface(above view: NSView) -> (any FinderUploadPasteSurface)? {
        var current: NSView? = view
        while let node = current {
            if let surface = node as? any FinderUploadPasteSurface { return surface }
            current = node.superview
        }
        return nil
    }

    private func presentTerminalFilePaste(
        urls: [URL], target: FinderUploadTarget, runtime: WorkspaceTabRuntime, in window: NSWindow
    ) {
        let alert = NSAlert()
        alert.messageText = L10n.text("粘贴访达文件")
        let destination: String
        if case .directory(let path) = target {
            destination = path
        } else {
            destination = L10n.text("待确认远程目录")
        }
        alert.informativeText = L10n.plural("已复制 %@ 个项目。目标目录：%@", count: urls.count, urls.count, destination)
        alert.addButton(withTitle: L10n.text("上传文件"))
        let namesButton = alert.addButton(withTitle: L10n.text("粘贴文件名"))
        let names = FinderClipboardPaste.fileNamesText(for: urls)
        namesButton.isEnabled = names != nil
        alert.addButton(withTitle: L10n.text("取消"))
        alert.beginSheetModal(for: window) { [weak self, weak runtime, weak window] response in
            guard let self, let runtime, let window,
                  self.windows.values.contains(where: { $0.state.tabs.values.contains { $0 === runtime } }) else { return }
            switch response {
            case .alertFirstButtonReturn:
                // The directory-confirmation sheet, if needed, must begin only
                // after this choice sheet has fully detached from the window.
                DispatchQueue.main.async { [weak self, weak runtime, weak window] in
                    guard let self, let runtime, let window else { return }
                    let ownerWindow = self.windows.values.first(where: {
                        $0.state.tabs.values.contains { $0 === runtime }
                    })?.window ?? window
                    runtime.uploadFromFinder(urls: urls, target: target, window: ownerWindow, store: self.store)
                }
            case .alertSecondButtonReturn:
                if let names { runtime.terminal?.pasteFileNames(names) }
            default:
                break
            }
        }
    }

    private func showFinderPasteMessage(_ message: String, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = L10n.text("无法上传文件")
        alert.informativeText = message
        alert.addButton(withTitle: L10n.text("确定"))
        alert.beginSheetModal(for: window) { _ in }
    }

    @objc private func closeCurrentItem(_ sender: Any?) {
        guard NSApp.modalWindow == nil, let record = keyWindowRecord,
              record.window?.attachedSheet == nil else { return }
        _ = record.state.closeCurrentItem()
    }

    /// Consume Command-W even for the last empty pane or a blocked workspace.
    /// Returning false in those cases would fall through to native Close Window.
    func handleWorkspaceCloseShortcut(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command],
              event.charactersIgnoringModifiers?.lowercased() == "w",
              let record = windows.values.first(where: { $0.window === window }) else { return false }
        guard !event.isARepeat, NSApp.modalWindow == nil, window.attachedSheet == nil,
              dragging.active == nil else { return true }
        _ = record.state.closeCurrentItem()
        return true
    }

    @objc private func newSessionTab(_ sender: Any?) {
        guard NSApp.modalWindow == nil, let record = keyWindowRecord,
              record.window?.attachedSheet == nil else { return }
        record.state.openManager(.sessions)
    }

    @objc private func searchSFTP(_ sender: Any?) {
        performSFTPCommand(.search)
    }

    @objc private func deleteSFTPSelection(_ sender: Any?) {
        performSFTPCommand(.delete)
    }

    @objc private func uploadSFTPFile(_ sender: Any?) {
        performSFTPCommand(.uploadFile)
    }

    private func canPerformSFTPCommand(_ action: SFTPShortcutAction) -> Bool {
        guard NSApp.modalWindow == nil, let record = keyWindowRecord,
              record.window?.attachedSheet == nil, let runtime = record.state.selectedRuntime?.sftp else { return false }
        switch action {
        case .search: return runtime.canSearchWithShortcut
        case .delete: return !keyWindowIsEditingText && runtime.canDeleteWithShortcut
        case .uploadFile: return runtime.canUploadFileWithShortcut
        }
    }

    private func performSFTPCommand(_ action: SFTPShortcutAction) {
        guard canPerformSFTPCommand(action), let runtime = selectedSFTP else { return }
        switch action {
        case .search: runtime.requestSearchCommand()
        case .delete: runtime.requestDeleteCommand()
        case .uploadFile: runtime.requestUploadFileCommand()
        }
    }

    private var selectedSFTP: SFTPRuntime? { keyWindowRecord?.state.selectedRuntime?.sftp }

    private var keyWindowIsEditingText: Bool {
        guard let textView = keyWindowRecord?.window?.firstResponder as? NSTextView else { return false }
        return textView.isEditable || textView.isFieldEditor
    }

    private var keyWindowRecord: WindowRecord? {
        guard let keyWindow = NSApp.keyWindow else { return nil }
        return windows.values.first(where: { $0.window === keyWindow })
    }

}

@MainActor
private final class WindowRecord {
    weak var window: NSWindow?
    let controller: NSWindowController?
    let state: WorkspaceWindowState
    let delegate: SnakeWindowDelegate

    init(window: NSWindow?, controller: NSWindowController?, state: WorkspaceWindowState, delegate: SnakeWindowDelegate) {
        self.window = window
        self.controller = controller
        self.state = state
        self.delegate = delegate
    }
}

@MainActor
private struct ParkedWindowRecord {
    let state: WorkspaceWindowState
    let frame: NSRect?
}

@MainActor
private final class SnakeWindowDelegate: NSObject, NSWindowDelegate, NSDraggingDestination {
    private let finderUploadRouter = FinderUploadWindowRouter()

    private func isWorkspaceDrag(_ sender: any NSDraggingInfo) -> Bool {
        (sender.draggingPasteboard.types ?? []).contains { WorkspaceDragPayload.types.contains($0) }
    }
    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isWorkspaceDrag(sender) ? (coordinator?.dragging.draggingUpdated(sender) ?? []) : finderUploadRouter.draggingUpdated(sender)
    }
    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        finderUploadRouter.draggingExited(sender); coordinator?.dragging.draggingExited(sender)
    }
    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isWorkspaceDrag(sender) ? (coordinator?.dragging.prepareForDragOperation(sender) ?? false) : finderUploadRouter.prepareForDragOperation(sender)
    }
    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isWorkspaceDrag(sender) ? (coordinator?.dragging.performDragOperation(sender) ?? false) : finderUploadRouter.performDragOperation(sender)
    }
    func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { draggingExited(sender) }
    func draggingEnded(_ sender: any NSDraggingInfo) { draggingExited(sender) }
    let id: WindowID
    weak var coordinator: WorkspaceWindowCoordinator?

    init(id: WindowID, coordinator: WorkspaceWindowCoordinator) {
        self.id = id
        self.coordinator = coordinator
    }

    func windowWillClose(_ notification: Notification) {
        coordinator?.closeWindow(id: id)
    }
}

@MainActor
extension WorkspaceWindowCoordinator: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasUnblockedWindow = NSApp.modalWindow == nil && keyWindowRecord?.window?.attachedSheet == nil
        if menuItem.action == #selector(newSessionTab(_:)) {
            return hasUnblockedWindow && keyWindowRecord != nil
        }
        if menuItem.action == #selector(searchSFTP(_:)) {
            return canPerformSFTPCommand(.search)
        }
        if menuItem.action == #selector(deleteSFTPSelection(_:)) {
            return canPerformSFTPCommand(.delete)
        }
        if menuItem.action == #selector(uploadSFTPFile(_:)) {
            return canPerformSFTPCommand(.uploadFile)
        }
        guard menuItem.action == #selector(closeCurrentItem(_:)) else { return true }
        guard NSApp.modalWindow == nil,
              let record = keyWindowRecord,
              record.window?.attachedSheet == nil else { return false }
        return record.state.canCloseCurrentItem
    }
}

@MainActor
public final class SnakeAppDelegate: NSObject, NSApplicationDelegate {
    public let store = ApplicationStore.shared
    private var coordinator: WorkspaceWindowCoordinator?
    private var terminationPending = false

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor in
            do {
                let mounted = try await Task.detached(priority: .utility) { try MountOperations.checkedMountedPaths() }.value
                let pending = store.mountMappings.filter { mounted.contains($0.managedMountPath) || $0.state == .mounting }
                if !pending.isEmpty {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = L10n.plural("还有 %@ 个目录尚未卸载", count: pending.count, pending.count)
                    alert.informativeText = L10n.text("退出前将安全卸载以下目录。正在进行的挂载操作会先完成；如果卸载失败，将保留应用运行。")
                    let details = pending.map { mapping in
                        let connection = store.profiles.first { $0.id == mapping.profileID }?.name ?? L10n.text("未绑定连接")
                        return L10n.format("%@ · %@\n远程目录：%@\n本地目录：%@\n挂载点：%@",
                                           mapping.name, connection, mapping.remotePath, mapping.userAccessPath, mapping.managedMountPath)
                    }.joined(separator: "\n\n")
                    alert.accessoryView = terminationDetailsView(details)
                    alert.addButton(withTitle: L10n.text("卸载并退出"))
                    alert.addButton(withTitle: L10n.text("取消"))
                    sender.activate(ignoringOtherApps: true)
                    guard alert.runModal() == .alertFirstButtonReturn else {
                        terminationPending = false
                        sender.reply(toApplicationShouldTerminate: false)
                        return
                    }
                }
            } catch {
                terminationPending = false
                sender.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.messageText = L10n.text("无法确认挂载状态，已取消退出")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: L10n.text("返回应用"))
                alert.runModal()
                return
            }
            let failures = await store.prepareForTermination()
            if failures.isEmpty {
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                terminationPending = false
                sender.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.text("无法安全卸载，已取消退出")
                alert.informativeText = L10n.text("以下目录未能安全卸载。请关闭正在使用这些目录的文件或终端后，再次退出 Snake。")
                alert.accessoryView = terminationDetailsView(failures.joined(separator: "\n\n"))
                alert.addButton(withTitle: L10n.text("返回应用"))
                sender.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
        return .terminateLater
    }

    private func terminationDetailsView(_ details: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.font = .systemFont(ofSize: 12)
        text.textColor = .labelColor
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)
        text.string = details
        scroll.documentView = text
        return scroll
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationIcon()
        let coordinator = WorkspaceWindowCoordinator(store: store)
        store.workspaceCoordinator = coordinator
        self.coordinator = coordinator
        coordinator.openInitialWindow()
        DispatchQueue.main.async {
            coordinator.installApplicationCommands()
        }
        Task { @MainActor in
            do {
                // Migrate on launch as well as on first access, including
                // credentials for profiles the user does not connect today.
                try await Task.detached(priority: .userInitiated) { try CredentialStore.prepare() }.value
            } catch {
                guard !store.isPreparingToQuit else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.text("凭据存储初始化未完成")
                alert.informativeText = error.localizedDescription + L10n.text("\n\n未覆盖原凭据文件；在问题解决前，无法正常读取或更新已保存的密码。")
                alert.addButton(withTitle: L10n.text("知道了"))
                if let window = NSApp.keyWindow, window.attachedSheet == nil {
                    alert.beginSheetModal(for: window) { _ in }
                } else {
                    alert.runModal()
                }
            }
        }
        pruneRemoteOpenCacheOnLaunch()
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        installApplicationIcon()
        coordinator?.installApplicationCommands()
    }

    /// Trims the open-remote-file cache once per launch, off the main thread.
    private func pruneRemoteOpenCacheOnLaunch() {
        Task { @MainActor in
            _ = await store.pruneRemoteOpenCache()
        }
    }

    private func installApplicationIcon() {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApp.applicationIconImage = icon
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    public func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        coordinator?.reopenWindows()
        return true
    }
}

public struct TerminalHost: NSViewRepresentable {
    @ObservedObject var runtime: TerminalRuntime
    let theme: TerminalTheme
    let fontName: String
    let fontSize: Double

    init(
        runtime: TerminalRuntime,
        theme: TerminalTheme,
        fontName: String,
        fontSize: Double
    ) {
        self.runtime = runtime
        self.theme = theme
        self.fontName = fontName
        self.fontSize = fontSize
    }

    public func makeNSView(context: Context) -> TerminalView {
        let terminalView = runtime.terminalSurface()
        runtime.applyTheme(theme)
        runtime.applyFont(name: fontName, size: fontSize)
        runtime.startIfNeeded(terminalView)
        return terminalView
    }

    public func updateNSView(_ nsView: TerminalView, context: Context) {
        runtime.applyTheme(theme)
        runtime.applyFont(name: fontName, size: fontSize)
        runtime.startIfNeeded(nsView)
    }
}
