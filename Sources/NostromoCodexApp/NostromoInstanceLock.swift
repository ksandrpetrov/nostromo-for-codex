import Darwin
import Foundation

/// The app retains this lease before constructing any services. The kernel
/// releases it on process exit, including crashes. Never unlink the lock file:
/// another process may already have the same inode open.
final class NostromoInstanceLock {
    enum Failure: Error {
        case alreadyRunning
        case unavailable
    }

    private let descriptor: Int32

    init(fileURL: URL) throws {
        let descriptor = Darwin.open(
            fileURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw Failure.unavailable }
        var acquired = false
        defer {
            if !acquired { Darwin.close(descriptor) }
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o777 == 0o600,
              info.st_uid == geteuid(), info.st_nlink == 1
        else { throw Failure.unavailable }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw errno == EWOULDBLOCK ? Failure.alreadyRunning : Failure.unavailable
        }
        self.descriptor = descriptor
        acquired = true
    }

    deinit {
        Darwin.close(descriptor)
    }

    static func acquireForApplication() throws -> NostromoInstanceLock {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { throw Failure.unavailable }
        let directory = support.appendingPathComponent("Nostromo Codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return try NostromoInstanceLock(fileURL: directory.appendingPathComponent("instance.lock"))
    }
}
