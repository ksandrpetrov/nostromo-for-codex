@testable import NostromoCodexApp
import XCTest

final class ChatGPTLauncherTests: XCTestCase {
    func testCurrentVerifiedBuildIsAllowlisted() {
        XCTAssertTrue(ChatGPTLauncher.supportedBuilds.contains("5973"))
    }

    func testVerifiedCompleteBuildPassesCompatibilityGate() throws {
        let compatibility = ChatGPTCompatibility(
            version: "26.721.41059",
            build: "5848",
            supported: true,
            requiredModulesPresent: true,
            reason: nil
        )

        XCTAssertNoThrow(
            try ChatGPTLauncher.validateCompatibility(
                compatibility,
                forceUnsupported: false
            )
        )
    }

    func testForceAllowsUnknownBuildWhenRequiredModulesExist() {
        let compatibility = ChatGPTCompatibility(
            version: "future",
            build: "9999",
            supported: false,
            requiredModulesPresent: true,
            reason: "Unverified build."
        )

        XCTAssertNoThrow(
            try ChatGPTLauncher.validateCompatibility(
                compatibility,
                forceUnsupported: true
            )
        )
    }

    func testUnknownBuildIsRejectedWithoutExpertOverride() {
        let compatibility = ChatGPTCompatibility(
            version: "future",
            build: "9999",
            supported: false,
            requiredModulesPresent: true,
            reason: "Unverified build."
        )

        XCTAssertThrowsError(
            try ChatGPTLauncher.validateCompatibility(
                compatibility,
                forceUnsupported: false
            )
        ) { error in
            guard case let LaunchError.unsupportedBuild(version, build) = error else {
                return XCTFail("Expected unsupportedBuild, got \(error)")
            }
            XCTAssertEqual(version, "future")
            XCTAssertEqual(build, "9999")
        }
    }

    func testForceCannotBypassMissingRequiredModules() {
        let compatibility = ChatGPTCompatibility(
            version: "26.721.41059",
            build: "5848",
            supported: false,
            requiredModulesPresent: false,
            reason: "Required ChatGPT module is missing."
        )

        XCTAssertThrowsError(
            try ChatGPTLauncher.validateCompatibility(
                compatibility,
                forceUnsupported: true
            )
        ) { error in
            guard case LaunchError.incompleteInstallation = error else {
                return XCTFail("Expected incompleteInstallation, got \(error)")
            }
        }
    }

    func testAdapterShapeRequiresEveryPrivateSurface() {
        let complete = Data(
            """
            codex_desktop:message-for-view codex-micro-service- composer.submit
            data-codex-composer-root M4.5 5.75C4.5 5.05964 5.05964 4.5
            size-token-button-composer skills/list
            codex-micro-push-to-talk-start codex-micro-push-to-talk-stop
            codex-micro-insert-composer-text codex-micro-insert-skill-mention
            """.utf8
        )
        XCTAssertTrue(ChatGPTLauncher.validateAdapterShape(in: complete))
        XCTAssertFalse(
            ChatGPTLauncher.validateAdapterShape(
                in: Data(
                    """
                    codex_desktop:message-for-view codex-micro-service- composer.submit
                    data-codex-composer-root skills/list
                    """.utf8
                )
            )
        )
    }
}
