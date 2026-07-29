import Foundation
@testable import NostromoCodexCore
import XCTest

final class CodexActionCatalogTests: XCTestCase {
    func testRuntimeCatalogDisablesCommandsMissingFromRunningBuild() {
        let catalog = CodexActionCatalog.runtimeCatalog(
            commandIDs: ["composer.submit", "newTask"]
        )

        XCTAssertTrue(catalog.first(where: { $0.id == "composer.submit" })?.available == true)
        XCTAssertTrue(catalog.first(where: { $0.id == "newTask" })?.available == true)
        XCTAssertTrue(
            catalog.first(where: { $0.id == "composer.togglePlanMode" })?.available == false
        )
    }

    func testNonCommandBridgeActionsDoNotDependOnDesktopRegistry() {
        let catalog = CodexActionCatalog.runtimeCatalog(commandIDs: [])

        for descriptor in catalog where !descriptor.requiresRuntimeRegistration {
            XCTAssertTrue(descriptor.available, descriptor.id)
        }
    }

    func testExecutionAndRiskMetadataCentralizeSpecialActionBehavior() {
        let byID = Dictionary(
            uniqueKeysWithValues: CodexActionCatalog.verified.map { ($0.id, $0) }
        )
        XCTAssertEqual(byID["focusChatGPT"]?.execution, .focusChatGPT)
        XCTAssertEqual(byID["pushToTalk"]?.execution, .pushToTalk)
        XCTAssertEqual(byID["composer.stop"]?.execution, .stopActive)
        XCTAssertEqual(byID["composer.submit"]?.execution, .submitActiveComposer)
        XCTAssertEqual(
            byID["composer.toggleChatWorkMode"]?.execution,
            .toggleChatWorkMode
        )
        XCTAssertEqual(byID["settings"]?.execution, .runtimeCommand)

        let consequential = Set(
            CodexActionCatalog.verified.filter(\.consequential).map(\.id)
        )
        XCTAssertEqual(
            consequential,
            [
                "approval.approve",
                "approval.decline",
                "composer.stop",
                "composer.submit",
                "git.commit",
                "git.createPullRequest",
            ]
        )
    }

    func testEveryAvailableRuntimeCommandIsAllowlistedByPreload() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let preloadURL = repositoryRoot.appendingPathComponent(
            "Sources/NostromoCodexApp/Resources/chatgpt-preload.cjs"
        )
        let preload = try String(contentsOf: preloadURL, encoding: .utf8)
        let startMarker = "const SAFE_COMMAND_CANDIDATES = new Set(["
        let endMarker = "]);"
        let start = try XCTUnwrap(preload.range(of: startMarker)?.upperBound)
        let end = try XCTUnwrap(preload.range(of: endMarker, range: start ..< preload.endIndex)?.lowerBound)
        let allowlistBody = String(preload[start ..< end])
        let expression = try NSRegularExpression(pattern: "\"([^\"]+)\"")
        let allowlisted = Set(
            expression.matches(
                in: allowlistBody,
                range: NSRange(allowlistBody.startIndex..., in: allowlistBody)
            ).compactMap { match -> String? in
                guard
                    let range = Range(match.range(at: 1), in: allowlistBody)
                else { return nil }
                return String(allowlistBody[range])
            }
        )
        let required = Set(
            CodexActionCatalog.verified
                .filter { $0.available && $0.requiresRuntimeRegistration }
                .map(\.id)
        )

        XCTAssertTrue(
            required.isSubset(of: allowlisted),
            "Команды отсутствуют в preload allowlist: \(required.subtracting(allowlisted).sorted())"
        )
    }
}
