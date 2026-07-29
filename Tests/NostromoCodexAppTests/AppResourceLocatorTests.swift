import Foundation
@testable import NostromoCodexApp
import XCTest

final class AppResourceLocatorTests: XCTestCase {
    func testFallsBackToInstalledApplicationWhenOriginalBundleWasMoved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missingPackagedURL = root
            .appendingPathComponent("old-location/Nostromo Codex.app")
            .appendingPathComponent("Contents/Resources/chatgpt-preload.cjs")
        let installedApplicationURL = root
            .appendingPathComponent("Applications/Nostromo Codex.app")
        let installedPreloadURL = installedApplicationURL
            .appendingPathComponent("Contents/Resources/chatgpt-preload.cjs")
        try FileManager.default.createDirectory(
            at: installedPreloadURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("preload".utf8).write(to: installedPreloadURL)

        let resolved = AppResourceLocator.preloadURL(
            packagedURL: missingPackagedURL,
            applicationURLs: [installedApplicationURL],
            currentDirectoryURL: root.appendingPathComponent("worktree")
        )

        XCTAssertEqual(resolved?.standardizedFileURL, installedPreloadURL.standardizedFileURL)
    }

    func testReturnsNilWhenEveryPreloadCandidateIsMissing() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let resolved = AppResourceLocator.preloadURL(
            packagedURL: root.appendingPathComponent("missing.cjs"),
            applicationURLs: [root.appendingPathComponent("Missing.app")],
            currentDirectoryURL: root
        )

        XCTAssertNil(resolved)
    }
}
