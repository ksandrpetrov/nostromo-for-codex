import Foundation
@testable import NostromoCodexCore
import XCTest

final class BridgeProtocolContractTests: XCTestCase {
    func testEveryTypedActionPreservesProtocolV2WireShape() throws {
        let actions: [(BridgeAppAction, String, [String: String])] = [
            (.clearComposerProject, "clear-composer-project", [:]),
            (.focusChatGPT, "focus-chatgpt", [:]),
            (.insertComposerText(text: "draft"), "insert-composer-text", ["text": "draft"]),
            (
                .insertSkillMention(name: "audit", displayName: "Audit", path: "/tmp/SKILL.md"),
                "insert-skill-mention",
                ["displayName": "Audit", "name": "audit", "path": "/tmp/SKILL.md"]
            ),
            (.navigateRoute(path: "/settings"), "navigate-route", ["path": "/settings"]),
            (.preparePluginPrompt(text: "prompt"), "prepare-plugin-prompt", ["text": "prompt"]),
            (.pushToTalkStart, "push-to-talk-start", [:]),
            (.pushToTalkStop, "push-to-talk-stop", [:]),
            (.queryRuntimeState, "query-runtime-state", [:]),
            (.runCommand(id: "settings"), "run-command", ["commandId": "settings"]),
            (.scrollTask(deltaY: -52), "scroll-task", ["deltaY": "-52"]),
            (.stopActive, "stop-active", [:]),
            (.submitActiveComposer, "submit-active-composer", [:]),
            (.toggleChatWorkMode, "toggle-chat-work-mode", [:]),
            (
                .toggleChatGPT(minimizeIfVisible: true),
                "toggle-chatgpt",
                ["minimizeIfVisible": "true"]
            ),
        ]

        XCTAssertEqual(actions.count, BridgeAppAction.Kind.allCases.count)
        for (index, entry) in actions.enumerated() {
            let object = entry.0.jsonObject(id: index + 1)
            XCTAssertEqual((object["v"] as? NSNumber)?.intValue, 2)
            XCTAssertEqual(object["type"] as? String, "app-action")
            XCTAssertEqual((object["id"] as? NSNumber)?.intValue, index + 1)
            XCTAssertEqual(object["action"] as? String, entry.1)
            XCTAssertEqual(object["payload"] as? [String: String], entry.2)
        }
    }

    func testSwiftActionsMatchSharedContractManifest() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/bridge-actions.json")
        let manifest = try JSONDecoder().decode(
            [BridgeActionContract].self,
            from: Data(contentsOf: manifestURL)
        )
        let swiftContract = Dictionary(
            uniqueKeysWithValues: sampleActions.map {
                ($0.kind.rawValue, $0.requiredPayloadKeys.sorted())
            }
        )
        let sharedContract = Dictionary(
            uniqueKeysWithValues: manifest.map {
                ($0.name, $0.requiredPayloadKeys.sorted())
            }
        )

        XCTAssertEqual(swiftContract, sharedContract)
        XCTAssertEqual(
            Set(BridgeAppAction.Kind.allCases.map(\.rawValue)),
            Set(sharedContract.keys)
        )
    }

    private var sampleActions: [BridgeAppAction] {
        [
            .clearComposerProject,
            .runCommand(id: ""),
            .focusChatGPT,
            .toggleChatGPT(minimizeIfVisible: false),
            .toggleChatWorkMode,
            .submitActiveComposer,
            .navigateRoute(path: ""),
            .scrollTask(deltaY: 0),
            .insertComposerText(text: ""),
            .insertSkillMention(name: "", displayName: "", path: ""),
            .preparePluginPrompt(text: ""),
            .pushToTalkStart,
            .pushToTalkStop,
            .stopActive,
            .queryRuntimeState,
        ]
    }
}

private struct BridgeActionContract: Decodable {
    let name: String
    let requiredPayloadKeys: [String]
}
