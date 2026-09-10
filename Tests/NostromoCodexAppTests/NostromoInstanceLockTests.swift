import Foundation
@testable import NostromoCodexApp
import XCTest

final class NostromoInstanceLockTests: XCTestCase {
    func testSecondInstanceCannotOwnStateUntilFirstExits() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("instance.lock")
        var first: NostromoInstanceLock? = try NostromoInstanceLock(fileURL: url)
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try NostromoInstanceLock(fileURL: url)) { error in
                guard case NostromoInstanceLock.Failure.alreadyRunning = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        first = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNoThrow(try NostromoInstanceLock(fileURL: url))
    }

    func testSymlinkCannotRedirectLockToAnotherFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("unrelated")
        let link = root.appendingPathComponent("instance.lock")
        let original = Data("preserve this file".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try NostromoInstanceLock(fileURL: link))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testPubliclyWritableLockIsRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("instance.lock")
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)

        XCTAssertThrowsError(try NostromoInstanceLock(fileURL: url))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
