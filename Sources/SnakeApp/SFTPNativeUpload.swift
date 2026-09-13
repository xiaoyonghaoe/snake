import Foundation
import SnakeCoreBindings

extension LocalUploadCoordinator {
    nonisolated static func uploadSFTPOnly(item: SFTPUploadItem, initialVersion: TransferIntegrity.LocalVersion,
        capability: CoreChecksumCapability, operation: CoreSftpHandle, overwrite: Bool,
        thresholdBytes: Int64, concurrency: Int, control: CoreTransferControl, jobID: UUID,
        store: ApplicationStore, makeHandle: @escaping @Sendable () throws -> CoreSftpHandle) async throws -> TransferVerification {
        let parent = (item.remotePath as NSString).deletingLastPathComponent
        let staging = (parent as NSString).appendingPathComponent(".snake-upload-\(UUID()).staging")
        let total = UInt64(max(0, item.size))
        let ranges = uploadRanges(totalBytes: total, workerCount: item.size > thresholdBytes ? concurrency : 1)
        let progress = SFTPMultipartProgress(jobID: jobID, totalBytes: total, store: store)
        try operation.prepareNativeUpload(staging: staging)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (index, range) in ranges.enumerated() {
                    group.addTask {
                        let handle = try makeHandle()
                        try handle.uploadNativeRange(localPath: item.localURL.path, staging: staging,
                            offset: range.offset, length: range.length, control: control,
                            observer: SFTPPartTransferObserver(index: index, progress: progress))
                    }
                }
                do { try await group.waitForAll() } catch { control.cancel(); throw error }
            }
            guard try operation.fileMetadata(path: staging).size == total,
                  try TransferIntegrity.LocalVersion(item.localURL) == initialVersion else {
                throw TransferIntegrity.error("上传长度或源文件已变化，暂存文件未发布")
            }
            try operation.publishNativeUpload(staging: staging, target: item.remotePath, overwrite: overwrite, control: control)
            return .unavailable(capability.reason)
        } catch {
            try? operation.removeTransferTemporary(path: staging)
            throw error
        }
    }
}
