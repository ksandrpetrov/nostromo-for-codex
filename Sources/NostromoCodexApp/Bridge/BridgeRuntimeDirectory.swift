import Darwin
import Foundation

/// Owns the private filesystem scope used by one bridge process. Cleanup only
/// removes directories whose owner marker, uid, permissions and inode still
/// match the values observed before process-liveness validation. `cleanupLock`
/// serializes the only mutable lifecycle transition.
final class BridgeRuntimeDirectory: @unchecked Sendable {
    typealias ProcessLivenessChecker = @Sendable (Int32) -> OwnerProcessLiveness

    enum OwnerProcessLiveness: Sendable {
        case alive
        case dead
        case unknown
    }

    static let directoryPrefix = "nostromo-codex-runtime-"
    static let ownerMarkerFileName = ".owner"

    private static let ownerMarkerVersion = 1

    private struct OwnerMarker: Codable, Equatable {
        let version: Int
        let pid: Int32
        let runtimeID: UUID
    }

    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private enum RuntimeDirectoryError: Error {
        case invalidOwnerPID
        case invalidRuntimeDirectory
        case invalidOwnerMarker
    }

    let url: URL
    let socketPath: String

    private let fileManager: FileManager
    private let identity: DirectoryIdentity
    private let cleanupLock = NSLock()
    private var removed = false

    init(
        fileManager: FileManager,
        runtimeRoot: URL,
        currentPID: Int32,
        processLiveness: ProcessLivenessChecker
    ) throws {
        guard currentPID > 0 else {
            throw RuntimeDirectoryError.invalidOwnerPID
        }

        Self.removeStaleDirectories(
            in: runtimeRoot,
            fileManager: fileManager,
            currentPID: currentPID,
            processLiveness: processLiveness
        )

        // sockaddr_un.sun_path is only 104 bytes. /tmp keeps the complete
        // per-process path short enough even after adding a UUID.
        let runtimeID = UUID()
        let base = runtimeRoot.appendingPathComponent(
            "\(Self.directoryPrefix)\(runtimeID.uuidString)",
            isDirectory: true
        )
        let marker = OwnerMarker(
            version: Self.ownerMarkerVersion,
            pid: currentPID,
            runtimeID: runtimeID
        )
        var createdDirectory = false
        let directoryIdentity: DirectoryIdentity
        do {
            try fileManager.createDirectory(at: base, withIntermediateDirectories: false)
            createdDirectory = true
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: base.path
            )

            guard
                let status = Self.itemStatus(at: base),
                Self.isDirectory(status),
                status.st_uid == Darwin.geteuid(),
                Self.permissions(of: status) == 0o700
            else {
                throw RuntimeDirectoryError.invalidRuntimeDirectory
            }
            directoryIdentity = Self.identity(of: status)

            let markerURL = base.appendingPathComponent(Self.ownerMarkerFileName)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(marker).write(to: markerURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: markerURL.path
            )
            guard Self.validOwnerMarker(
                at: markerURL,
                expectedRuntimeID: runtimeID,
                expectedOwner: status.st_uid
            ) == marker else {
                throw RuntimeDirectoryError.invalidOwnerMarker
            }
        } catch {
            if createdDirectory {
                try? fileManager.removeItem(at: base)
            }
            throw error
        }

        self.fileManager = fileManager
        identity = directoryIdentity
        url = base
        socketPath = base.appendingPathComponent("project2077.sock").path
    }

    func remove() {
        cleanupLock.lock()
        defer { cleanupLock.unlock() }
        guard !removed else { return }
        guard let status = Self.itemStatus(at: url) else { return }
        guard Self.identity(of: status) == identity else {
            removed = true
            return
        }
        do {
            try fileManager.removeItem(at: url)
            removed = true
        } catch {
            // A later idempotent stop may retry a transient filesystem error.
        }
    }

    static func defaultProcessLiveness(_ pid: Int32) -> OwnerProcessLiveness {
        guard pid > 0 else { return .unknown }
        if Darwin.kill(pid, 0) == 0 {
            return .alive
        }
        switch errno {
        case ESRCH:
            return .dead
        case EPERM:
            return .alive
        default:
            return .unknown
        }
    }

    private static func removeStaleDirectories(
        in runtimeRoot: URL,
        fileManager: FileManager,
        currentPID: Int32,
        processLiveness: ProcessLivenessChecker
    ) {
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: runtimeRoot,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        let currentUser = Darwin.geteuid()
        for candidate in candidates {
            guard let runtimeID = runtimeID(fromDirectoryName: candidate.lastPathComponent) else {
                continue
            }
            guard
                let status = itemStatus(at: candidate),
                isDirectory(status),
                status.st_uid == currentUser,
                permissions(of: status) == 0o700
            else {
                continue
            }

            let initialIdentity = identity(of: status)
            let markerURL = candidate.appendingPathComponent(ownerMarkerFileName)
            guard
                let marker = validOwnerMarker(
                    at: markerURL,
                    expectedRuntimeID: runtimeID,
                    expectedOwner: currentUser
                ),
                marker.pid != currentPID,
                processLiveness(marker.pid) == .dead
            else {
                continue
            }

            // Revalidate after the liveness check so a changed or replaced
            // candidate is preserved instead of recursively removed.
            guard
                let currentStatus = itemStatus(at: candidate),
                isDirectory(currentStatus),
                currentStatus.st_uid == currentUser,
                permissions(of: currentStatus) == 0o700,
                identity(of: currentStatus) == initialIdentity,
                validOwnerMarker(
                    at: markerURL,
                    expectedRuntimeID: runtimeID,
                    expectedOwner: currentUser
                ) == marker
            else {
                continue
            }

            try? fileManager.removeItem(at: candidate)
        }
    }

    private static func runtimeID(fromDirectoryName name: String) -> UUID? {
        guard name.hasPrefix(directoryPrefix) else { return nil }
        let rawID = String(name.dropFirst(directoryPrefix.count))
        guard
            rawID.count == 36,
            let runtimeID = UUID(uuidString: rawID),
            runtimeID.uuidString == rawID
        else {
            return nil
        }
        return runtimeID
    }

    private static func validOwnerMarker(
        at markerURL: URL,
        expectedRuntimeID: UUID,
        expectedOwner: uid_t
    ) -> OwnerMarker? {
        guard
            let status = itemStatus(at: markerURL),
            isRegularFile(status),
            status.st_uid == expectedOwner,
            permissions(of: status) == 0o600,
            status.st_nlink == 1,
            status.st_size > 0,
            status.st_size <= 4_096,
            let data = try? Data(contentsOf: markerURL),
            let marker = try? JSONDecoder().decode(OwnerMarker.self, from: data),
            marker.version == ownerMarkerVersion,
            marker.pid > 0,
            marker.runtimeID == expectedRuntimeID
        else {
            return nil
        }
        return marker
    }

    private static func itemStatus(at url: URL) -> stat? {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else { return nil }
        return status
    }

    private static func isDirectory(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFDIR
    }

    private static func isRegularFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
    }

    private static func permissions(of status: stat) -> mode_t {
        status.st_mode & 0o777
    }

    private static func identity(of status: stat) -> DirectoryIdentity {
        DirectoryIdentity(device: status.st_dev, inode: status.st_ino)
    }
}
