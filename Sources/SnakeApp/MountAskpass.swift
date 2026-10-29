import Darwin
import Foundation

/// Hands a session's password (or private-key passphrase) to the `ssh` that one
/// sshfs mount spawns, through `SSH_ASKPASS`, without putting it in argv, the
/// environment or a file.
///
/// The helper only learns a socket path. When `ssh` needs the secret it runs the
/// helper in askpass mode, which connects here. A connection is answered only
/// when its peer belongs to this user, is the SnakeMountHelper binary, and is
/// in the mount's process group. The helper makes itself a group leader before
/// it `execv`s sshfs, so that group's ID is the helper PID. Ancestry alone is
/// not enough: sshfs double-forks ssh, which leaves ssh parented to launchd but
/// still in the group. Everything else is closed without a reply.
/// The broker lives as long as the mount process so `reconnect` can ask again.
final class MountAskpassBroker: @unchecked Sendable {
    static let socketDirectoryPrefix = "snake-askpass-"
    static let socketName = "s"

    let socketPath: String
    private let directoryPath: String
    private let helperPath: String
    private let lock = NSLock()
    private var secret: [UInt8]
    private var listener: Int32 = -1
    private var mountPID: pid_t = 0
    private var closed = false

    init(secret: Data, helperPath: String) throws {
        self.secret = Array(secret)
        self.helperPath = Self.realPath(helperPath) ?? helperPath
        let directory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent(Self.socketDirectoryPrefix + UUID().uuidString.prefix(8).lowercased())
        directoryPath = directory
        socketPath = (directory as NSString).appendingPathComponent(Self.socketName)
        guard mkdir(directory, 0o700) == 0 else { throw Self.posixError() }
        do {
            try startListening()
        } catch {
            rmdir(directory)
            wipeSecret()
            throw error
        }
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit { close() }

    /// Answers only this process's group or descendants; call right after it starts.
    func authorize(mountPID: pid_t) {
        lock.lock()
        self.mountPID = mountPID
        lock.unlock()
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let fd = listener
        listener = -1
        wipeSecret()
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        unlink(socketPath)
        rmdir(directoryPath)
    }

    private func startListening() throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { throw MountAskpassError.socketPathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.posixError() }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(fd, 4) == 0 else {
            let error = Self.posixError()
            Darwin.close(fd)
            unlink(socketPath)
            throw error
        }
        listener = fd
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listener
            lock.unlock()
            guard fd >= 0 else { return }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            serve(client)
            Darwin.close(client)
        }
    }

    private func serve(_ client: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var uid = uid_t(0), gid = gid_t(0)
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        var peer = pid_t(0)
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) == 0, peer > 0 else { return }

        lock.lock()
        let allowedAncestor = mountPID
        let reply = closed ? [] : secret + [0x0A]
        lock.unlock()
        guard allowedAncestor > 0, !reply.isEmpty,
              Self.executablePath(of: peer) == helperPath,
              getpgid(peer) == allowedAncestor || Self.process(peer, descendsFrom: allowedAncestor) else { return }
        var payload = reply
        defer { for index in payload.indices { payload[index] = 0 } }
        var sent = 0
        while sent < payload.count {
            let written = payload.withUnsafeBytes { write(client, $0.baseAddress! + sent, payload.count - sent) }
            guard written > 0 else { return }
            sent += written
        }
    }

    /// The askpass process is ssh's child, and ssh is the sshfs child.
    static func process(_ pid: pid_t, descendsFrom ancestor: pid_t, maxDepth: Int = 4) -> Bool {
        var current = pid
        for _ in 0..<maxDepth {
            guard let parent = parentPID(of: current), parent > 1 else { return false }
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return realPath(String(cString: buffer))
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func wipeSecret() {
        for index in secret.indices { secret[index] = 0 }
        secret.removeAll()
    }

    private static func posixError() -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

enum MountAskpassError: LocalizedError {
    case socketPathTooLong

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong: L10n.text("临时目录路径过长，无法建立 SSHFS 密码通道。")
        }
    }
}
