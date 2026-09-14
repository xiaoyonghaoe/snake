import AppKit
import Foundation
import SnakeCoreBindings

struct DownloadConflictPrompt: Identifiable {
    let id = UUID()
    let path: String
}

struct DownloadItem: Sendable {
    let remotePath: String
    let components: [String]
    let metadata: CoreFileMetadata
}

enum DownloadManifest {
    static func roots(_ files: [RemoteFile]) -> [RemoteFile] {
        let sorted = files.sorted { $0.path.count < $1.path.count }
        var result: [RemoteFile] = []
        for file in sorted {
            if result.contains(where: { $0.path == file.path || ($0.isDirectory && !$0.isSymbolicLink && file.path.hasPrefix($0.path + "/")) }) { continue }
            result.append(file)
        }
        return result
    }

    static func scan(files: [RemoteFile], handle: CoreSftpHandle) throws -> [DownloadItem] {
        var result: [DownloadItem] = []
        func visit(_ path: String, _ components: [String]) throws {
            guard components.count <= 256 else { throw TransferIntegrity.error(L10n.text("目录层级超过安全限制")) }
            for name in components { try DownloadLocation.validate(name) }
            let metadata = try handle.fileMetadata(path: path)
            result.append(DownloadItem(remotePath: path, components: components, metadata: metadata))
            if metadata.kind == "directory" {
                for child in try handle.list(path: path) {
                    if child.name == "." || child.name == ".." { continue }
                    try DownloadLocation.validate(child.name)
                    // Construct from the validated name, never trust a remote
                    // server's returned full path for local path derivation.
                    try visit((path as NSString).appendingPathComponent(child.name), components + [child.name])
                }
            }
        }
        for file in roots(files) { try visit(file.path, [file.name]) }
        return result
    }
}

extension LocalUploadCoordinator {
    var transferSummary: String {
        let completed = records.filter { $0.state == .succeeded }
        let passed = completed.filter { if case .passed = $0.verification { true } else { false } }.count
        let unchecked = completed.filter { $0.verification.isWarning }.count
        let failed = records.filter { $0.state == .failed }.count
        let skipped = completed.filter { $0.verification == .notApplicable(L10n.text("已跳过")) }.count
        return L10n.format("已完成 %@ 项 · 校验通过 %@ · 未校验 %@ · 失败 %@ · 跳过 %@",
            completed.count, passed, unchecked, failed, skipped)
    }

    var hasUnverifiedTransfers: Bool { records.contains { $0.state == .succeeded && $0.verification.isWarning } }

    func setVerification(_ id: UUID, _ value: TransferVerification) {
        guard let index = records.firstIndex(where: { $0.jobID == id }) else { return }
        records[index].verification = value
    }

    func resolveDownloadConflict(_ decision: SFTPUploadConflictDecision) {
        pendingDownloadConflict = nil
        downloadConflictContinuation?.resume(returning: decision)
        downloadConflictContinuation = nil
    }

    private func requestDownloadConflict(_ path: String) async -> SFTPUploadConflictDecision {
        guard canPresentTransferConflicts else { return .cancel }
        return await withCheckedContinuation { continuation in
            downloadConflictContinuation = continuation
            pendingDownloadConflict = DownloadConflictPrompt(path: path)
        }
    }

    func download(files: [RemoteFile], to root: URL, store: ApplicationStore) {
        guard !files.isEmpty else { return }
        let concurrency = max(1, store.multipartConcurrency)
        let threshold = store.multipartThresholdBytes
        let profile = profile
        let makeHandle = makeHandle
        errorMessage = nil
        activity.begin()
        let previous = batchTask
        batchTask = Task {
            await previous?.value
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            var outcome = UploadActivity.Outcome()
            defer { activity.finish(outcome) }
            do {
                let (items, capability) = try await Task.detached(priority: .userInitiated) {
                    let handle = try makeHandle()
                    return (try DownloadManifest.scan(files: files, handle: handle), TransferIntegrity.bestEffortCapability { try handle.checksumCapability() })
                }.value
                let location = try DownloadLocation(root: root)
                var tasks: [(UUID, DownloadItem, Bool, CoreTransferControl)] = []
                var allDecision: SFTPUploadConflictDecision?
                applyDownloadConflictToBatch = false
                for item in items {
                    let parent = try location.directory(Array(item.components.dropLast()))
                    let name = item.components.last!
                    let url = parent.url.appendingPathComponent(name)
                    let id = store.registerRealDownload(profile: profile, remotePath: item.remotePath, localURL: url, size: Int64(clamping: item.metadata.size))
                    var record = SFTPUploadRecord(jobID: id, fileName: name, remotePath: item.remotePath,
                        fileSize: Int64(clamping: item.metadata.size), startedAt: .now, state: .queued, localURL: url, overwrite: false)
                    record.isDownload = true
                    records.insert(record, at: 0)
                    if item.metadata.kind == "directory" {
                        _ = try location.directory(item.components)
                        setVerification(id, .notApplicable(L10n.text("目录已创建")))
                        update(jobID: id, state: .succeeded, finishedAt: .now)
                        store.markTransferSucceeded(id); outcome.succeeded += 1
                        continue
                    }
                    if item.metadata.kind == "special" {
                        setVerification(id, .notApplicable(L10n.text("已跳过")))
                        update(jobID: id, state: .succeeded, finishedAt: .now)
                        store.markTransferSucceeded(id); outcome.skipped += 1
                        continue
                    }
                    var overwrite = false
                    if try parent.exists(name) {
                        let decision: SFTPUploadConflictDecision
                        if let allDecision { decision = allDecision }
                        else { decision = await requestDownloadConflict(url.path) }
                        if applyDownloadConflictToBatch { allDecision = decision }
                        switch decision {
                        case .cancel:
                            for (queuedID, _, _, control) in tasks { control.cancel(); update(jobID: queuedID, state: .cancelled, finishedAt: .now); store.cancel(jobID: queuedID) }
                            update(jobID: id, state: .cancelled, finishedAt: .now); store.cancel(jobID: id)
                            outcome.cancelled += tasks.count + 1
                            return
                        case .skip:
                            setVerification(id, .notApplicable(L10n.text("已跳过"))); update(jobID: id, state: .succeeded, finishedAt: .now)
                            store.markTransferSucceeded(id); outcome.skipped += 1
                            continue
                        case .overwrite: overwrite = true
                        }
                    }
                    let control = store.makeTransferControl(for: id)
                    tasks.append((id, item, overwrite, control))
                    let retryOverwrite = overwrite
                    downloadRetries[id] = { [weak self] in
                        guard let self, let record = self.records.first(where: { $0.jobID == id }), [.failed, .cancelled, .interrupted].contains(record.state) else { return }
                        store.prepareTransferRetry(id); self.update(jobID: id, state: .queued)
                        self.activity.begin()
                        let retryControl = store.makeTransferControl(for: id)
                        let retryScope = root.startAccessingSecurityScopedResource()
                        defer { if retryScope { root.stopAccessingSecurityScopedResource() } }
                        // New metadata and staging per retry: no corrupt or
                        // stale ranges survive a failed verification.
                        await self.performDownload(id: id, item: item, location: location, overwrite: retryOverwrite,
                            workers: item.metadata.size > UInt64(threshold) ? concurrency : 1,
                            capability: capability, control: retryControl, store: store, refreshMetadata: true)
                        self.activity.finish(self.outcome(for: [id]))
                    }
                }
                // Small-file waves share the same limit as multipart files.
                // A large file runs between waves, never N files × N workers.
                var index = 0
                while index < tasks.count {
                    let first = tasks[index]
                    if first.1.metadata.size > UInt64(threshold) {
                        await performDownload(id: first.0, item: first.1, location: location, overwrite: first.2,
                            workers: concurrency, capability: capability, control: first.3, store: store)
                        index += 1
                    } else {
                        var wave: [(UUID, DownloadItem, Bool, CoreTransferControl)] = []
                        while index < tasks.count, wave.count < concurrency, tasks[index].1.metadata.size <= UInt64(threshold) {
                            wave.append(tasks[index]); index += 1
                        }
                        await withTaskGroup(of: Void.self) { group in
                            for task in wave {
                                group.addTask {
                                    await self.performDownload(id: task.0, item: task.1, location: location, overwrite: task.2,
                                        workers: 1, capability: capability, control: task.3, store: store)
                                }
                            }
                        }
                    }
                }
                let filesOutcome = self.outcome(for: tasks.map(\.0))
                outcome.succeeded += filesOutcome.succeeded; outcome.failed += filesOutcome.failed; outcome.cancelled += filesOutcome.cancelled
            } catch {
                errorMessage = String(describing: error)
                outcome.failed += 1
                // No orphaned queued records after scan/setup errors.
                for record in records where record.isDownload && record.state == .queued {
                    update(jobID: record.jobID, state: .failed, finishedAt: .now)
                    store.markTransferFailed(record.jobID, message: String(describing: error))
                }
            }
        }
    }

    private func outcome(for ids: [UUID]) -> UploadActivity.Outcome {
        var result = UploadActivity.Outcome()
        for record in records where ids.contains(record.jobID) {
            switch record.state {
            case .succeeded: result.succeeded += 1
            case .cancelled: result.cancelled += 1
            default: result.failed += 1
            }
        }
        return result
    }

    private func performDownload(id: UUID, item: DownloadItem, location: DownloadLocation, overwrite: Bool, workers: Int,
        capability: CoreChecksumCapability, control: CoreTransferControl, store: ApplicationStore, refreshMetadata: Bool = false) async {
        guard records.first(where: { $0.jobID == id })?.state != .cancelled else { return }
        update(jobID: id, state: .running)
        setVerification(id, .pending)
        store.markTransferRunning(id)
        let makeHandle = makeHandle
        do {
            let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                try control.checkpoint()
                let handle = try makeHandle()
                let current = try handle.fileMetadata(path: item.remotePath)
                if !refreshMetadata, current != item.metadata { throw TransferIntegrity.error(L10n.text("下载源文件在扫描后已变化")) }
                guard current.kind == item.metadata.kind else { throw TransferIntegrity.error(L10n.text("下载源文件类型已变化")) }
                let parent = try location.directory(Array(item.components.dropLast()), create: false)
                let name = item.components.last!
                if current.kind == "link" {
                    guard let target = current.linkTarget else { throw TransferIntegrity.error(L10n.text("无法读取软链接目标")) }
                    try control.checkpoint()
                    try parent.createLink(name: name, target: target, overwrite: overwrite)
                    return TransferVerification.notApplicable(L10n.text("软链接目标已核对"))
                }
                let staging = try DownloadStaging(parent: parent, size: current.size)
                let progress = SFTPMultipartProgress(jobID: id, totalBytes: current.size, store: store)
                let ranges = Self.uploadRanges(totalBytes: current.size, workerCount: workers)
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for (index, range) in ranges.enumerated() {
                            group.addTask {
                                let partHandle = try makeHandle()
                                try partHandle.downloadRange(remotePath: item.remotePath, localFd: staging.fd,
                                    offset: range.offset, length: range.length, control: control,
                                    observer: SFTPPartTransferObserver(index: index, progress: progress))
                            }
                        }
                        do { try await group.waitForAll() } catch { control.cancel(); throw error }
                    }
                }
                let verification: TransferVerification
                if capability.algorithm.isEmpty { verification = .unavailable(capability.reason) }
                else {
                    await self?.setVerification(id, .checking(capability.algorithm))
                    verification = try TransferIntegrity.bestEffortVerification(algorithm: capability.algorithm, local: {
                        try TransferIntegrity.localDigest(fd: staging.fd, algorithm: capability.algorithm, control: control)
                    }, remote: {
                        try handle.remoteChecksum(path: item.remotePath, capability: capability, control: control)
                    })
                }
                guard try handle.fileMetadata(path: item.remotePath) == current else { throw TransferIntegrity.error(L10n.text("传输或校验期间远端源文件已变化")) }
                try control.checkpoint()
                try staging.publish(as: name, overwrite: overwrite)
                return verification
            }.value
            setVerification(id, result)
            update(jobID: id, state: .succeeded, finishedAt: .now)
            store.markTransferSucceeded(id)
        } catch {
            if case CoreError.TransferCancelled = error {
                update(jobID: id, state: .cancelled, finishedAt: .now); store.cancel(jobID: id)
            } else {
                let message = String(describing: error)
                setVerification(id, .failed(message))
                update(jobID: id, state: .failed, finishedAt: .now); store.markTransferFailed(id, message: message)
            }
        }
    }
}
