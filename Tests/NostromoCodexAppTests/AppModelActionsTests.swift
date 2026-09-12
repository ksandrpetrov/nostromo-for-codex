import Foundation
@testable import NostromoCodexApp
import NostromoCodexCore
import SwiftUI
import XCTest

@MainActor
final class AppModelActionsTests: AppModelTestCase {
    func testDisconnectedBridgeUsesOnlyBasicFallbackOnFreshPress() async {
        let fixture = makeFixture()
        fixture.model.setBinding(.codexAction("newTask"), for: .key01)
        fixture.bridge.onStatus?(.listening)
        await settle()
        fixture.hid.emitButton(.key01, pressed: true, configuration: fixture.model.configuration)
        await settle()
        XCTAssertEqual(fixture.fallback.actions, [.newTask])
        XCTAssertFalse(fixture.bridge.actions.contains(.runCommand(id: "newTask")))
    }

    func testFallbackBlocksConsequentialActionsAndPermissionFailure() async {
        let fixture = makeFixture()
        fixture.model.setBinding(.codexAction("approval.approve"), for: .key01)
        fixture.bridge.onStatus?(.listening)
        await settle()
        fixture.hid.emitButton(.key01, pressed: true, configuration: fixture.model.configuration)
        await settle()
        XCTAssertTrue(fixture.fallback.actions.isEmpty)
        XCTAssertFalse(fixture.bridge.actions.contains(.runCommand(id: "approval.approve")))
        fixture.hid.emitButton(.key01, pressed: false, configuration: fixture.model.configuration)
        await settle()
        fixture.model.setBinding(.codexAction("newTask"), for: .key01)
        fixture.fallback.hasAccess = false
        fixture.hid.emitButton(.key01, pressed: true, configuration: fixture.model.configuration, timestamp: 2)
        await settle()
        XCTAssertTrue(fixture.fallback.actions.isEmpty)
        XCTAssertNotNil(fixture.model.lastError)
    }

    func testUnrecordedShortcutCannotPostAPlaceholderKey() async {
        let fixture = makeFixture(shortcutAccess: true)
        let model = fixture.model
        model.setBinding(
            .shortcut(ShortcutBinding(configured: false)),
            for: .key01
        )

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()

        XCTAssertTrue(fixture.shortcutPoster.events.isEmpty)
        XCTAssertNotNil(model.lastError)
    }

    func testIncompletePluginPromptCannotReachComposer() async {
        let fixture = makeFixture()
        let model = fixture.model
        model.setBinding(
            .pluginPrompt(PluginPrompt(uri: "plugin://", displayName: "Plugin")),
            for: .key01
        )

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()

        XCTAssertTrue(fixture.bridge.actions.isEmpty)
        XCTAssertNotNil(model.lastError)
    }

    func testCodexPluginAndSkillBindingsDispatchExpectedActions() async throws {
        let fixture = makeFixture()
        let model = fixture.model

        model.setBinding(.codexAction("composer.togglePlanMode"), for: .key01)
        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "run-command")
        XCTAssertEqual(fixture.bridge.actions.last?.payload["commandId"], "composer.togglePlanMode")

        model.setBinding(.codexAction("composer.submit"), for: .key01)
        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "submit-active-composer")
        XCTAssertTrue(fixture.bridge.actions.last?.payload.isEmpty == true)

        model.setBinding(.codexAction("composer.toggleChatWorkMode"), for: .key02)
        fixture.hid.emitButton(.key02, pressed: true, configuration: model.configuration)
        fixture.hid.emitButton(.key02, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "toggle-chat-work-mode")

        model.setBinding(
            .pluginPrompt(PluginPrompt(uri: "plugin://calendar", displayName: "Calendar", template: "Найди окно")),
            for: .key03
        )
        fixture.hid.emitButton(.key03, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "prepare-plugin-prompt")
        XCTAssertEqual(
            fixture.bridge.actions.last?.payload["text"],
            "[@Calendar](plugin://calendar) Найди окно"
        )

        let skill = SkillReference(name: "meeting", displayName: "Meeting", path: "/tmp/SKILL.md")
        model.skills = [skill]
        model.setBinding(.skill(skill), for: .key04)
        fixture.hid.emitButton(.key04, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "insert-skill-mention")
        XCTAssertEqual(fixture.bridge.actions.last?.payload["name"], "meeting")
    }

    func testEveryVerifiedCodexActionDispatchesOrIsExplicitlyUnavailable() async {
        let fixture = makeFixture()
        let model = fixture.model

        for (index, descriptor) in CodexActionCatalog.verified.enumerated() {
            let before = fixture.bridge.actions.count
            let timestamp = TimeInterval(index * 10 + 1)
            model.setBinding(.codexAction(descriptor.id), for: .key01)
            fixture.hid.emitButton(
                .key01,
                pressed: true,
                configuration: model.configuration,
                timestamp: timestamp
            )
            fixture.hid.emitButton(
                .key01,
                pressed: false,
                configuration: model.configuration,
                timestamp: timestamp + 0.1
            )
            await settle()
            let emitted = Array(fixture.bridge.actions.dropFirst(before))

            if !descriptor.available {
                XCTAssertFalse(descriptor.available)
                XCTAssertTrue(emitted.isEmpty)
                XCTAssertNotNil(model.lastError)
                continue
            }

            switch descriptor.execution {
            case .focusChatGPT:
                XCTAssertEqual(emitted.first?.name, "toggle-chatgpt")
            case .stopActive:
                XCTAssertEqual(emitted.first?.name, "stop-active")
            case .submitActiveComposer:
                XCTAssertEqual(emitted.first?.name, "submit-active-composer")
            case .toggleChatWorkMode:
                XCTAssertEqual(emitted.first?.name, "toggle-chat-work-mode")
            case let .insertComposerText(text):
                XCTAssertEqual(emitted.first?.name, "insert-composer-text")
                XCTAssertEqual(emitted.first?.payload["text"], text)
            case .clearComposerProject:
                XCTAssertEqual(emitted.first?.name, "clear-composer-project")
            case .pushToTalk:
                XCTAssertTrue(emitted.contains(where: { $0.name == "push-to-talk-start" }))
                XCTAssertTrue(emitted.contains(where: { $0.name == "push-to-talk-stop" }))
            case .runtimeCommand:
                XCTAssertTrue(
                    emitted.contains(where: {
                        $0.name == "run-command"
                            && $0.payload["commandId"] == descriptor.id
                    }),
                    "Команда не была отправлена: \(descriptor.id)"
                )
            }
        }
    }

    func testFocusChatGPTTogglesShowThenMinimizeWithoutReactivation() async {
        let fixture = makeFixture()
        let model = fixture.model
        model.setBinding(.codexAction("focusChatGPT"), for: .key01)

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()

        XCTAssertEqual(fixture.launcher.activateCalls, 1)
        XCTAssertEqual(fixture.bridge.actions.last?.name, "toggle-chatgpt")
        XCTAssertEqual(fixture.bridge.actions.last?.payload["minimizeIfVisible"], "false")

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()

        XCTAssertEqual(fixture.launcher.activateCalls, 1)
        XCTAssertEqual(fixture.bridge.actions.last?.name, "toggle-chatgpt")
        XCTAssertEqual(fixture.bridge.actions.last?.payload["minimizeIfVisible"], "true")
    }

    func testUnavailableCommandDoesNotReachBridge() async {
        let fixture = makeFixture()
        let model = fixture.model
        let before = fixture.bridge.actions.count
        model.setBinding(.codexAction("composer.openPermissions"), for: .key01)
        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.count, before)
        XCTAssertNotNil(model.lastError)
    }

    func testUnknownCommandUsesRuntimeCommandFallback() async {
        let fixture = makeFixture()
        let model = fixture.model
        let unknownID = "future.runtime.command"

        model.setBinding(.codexAction(unknownID), for: .key01)
        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()

        XCTAssertEqual(fixture.bridge.actions.last?.name, "run-command")
        XCTAssertEqual(fixture.bridge.actions.last?.payload["commandId"], unknownID)
    }

    func testSkillPickerActionInsertsDollarIntoComposer() async {
        let fixture = makeFixture()
        let model = fixture.model

        model.setBinding(.codexAction("composer.openSkillPicker"), for: .key01)
        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()

        XCTAssertEqual(fixture.bridge.actions.last?.name, "insert-composer-text")
        XCTAssertEqual(fixture.bridge.actions.last?.payload["text"], "$")
    }

    func testClearProjectActionUsesDedicatedBridgeAction() async {
        let fixture = makeFixture()
        let model = fixture.model

        model.setBinding(.codexAction("composer.clearProject"), for: .key01)
        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()

        XCTAssertEqual(fixture.bridge.actions.last?.name, "clear-composer-project")
        XCTAssertTrue(fixture.bridge.actions.last?.payload.isEmpty == true)
    }

    func testShortcutRequiresAccessibilityAndPostsBalancedEdgesWhenGranted() async {
        let fixture = makeFixture(shortcutAccess: false)
        let model = fixture.model
        let shortcut = ShortcutBinding(keyCode: 12, command: true)
        model.setBinding(.shortcut(shortcut), for: .key01)

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertTrue(fixture.shortcutPoster.events.isEmpty)
        XCTAssertFalse(model.shortcutPermissionGranted)
        XCTAssertNotNil(model.lastError)

        fixture.shortcutPoster.access = true
        model.requestShortcutPermission()
        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertEqual(fixture.shortcutPoster.events.map(\.keyDown), [true, false])
        XCTAssertEqual(fixture.shortcutPoster.events.map(\.shortcut), [shortcut, shortcut])
        XCTAssertTrue(model.shortcutPermissionGranted)
    }
}
