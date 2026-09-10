import Foundation
@testable import NostromoCodexApp
import NostromoCodexCore
import SwiftUI
import XCTest

@MainActor
final class AppModelTests: XCTestCase {
    func testShutdownCancelsFallbackWaitingForActivation() async {
        let fixture = makeFixture()
        fixture.fallback.delay = .milliseconds(100)
        fixture.model.setBinding(.codexAction("newTask"), for: .key01)
        fixture.bridge.onStatus?(.listening)
        await settle()
        fixture.hid.emitButton(.key01, pressed: true, configuration: fixture.model.configuration)
        await settle()
        fixture.model.shutdown()
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(fixture.fallback.actions.isEmpty)
        XCTAssertFalse(fixture.bridge.actions.contains(.runCommand(id: "newTask")))
    }

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

    func testUnsupportedRestartPreservesRunningApplication() async {
        let fixture = makeFixture()
        fixture.launcher.setCompatibility(ChatGPTCompatibility(version: "future", build: "9999", supported: false))
        fixture.model.restartThroughNostromo()
        await settle()
        XCTAssertEqual(fixture.launcher.terminateCalls, 0)
        XCTAssertEqual(fixture.launcher.launchCalls, 0)
        XCTAssertNotNil(fixture.model.lastError)
    }

    func testInstallationChangeInvalidatesOldCapabilitiesWithoutEditingProfiles() async {
        let fixture = makeFixture()
        await settle()
        fixture.model.refreshChatGPTConnection()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let configuration = try? encoder.encode(fixture.model.configuration)
        XCTAssertTrue(fixture.model.fullBridgeReady)
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.blue ?? false)
        fixture.launcher.setCompatibility(ChatGPTCompatibility(version: "future", build: "9999", supported: false))
        fixture.model.refreshChatGPTConnection()
        XCTAssertFalse(fixture.model.fullBridgeReady)
        XCTAssertNil(fixture.model.runtimeCapabilities)
        XCTAssertEqual(try? encoder.encode(fixture.model.configuration), configuration)
        XCTAssertEqual(fixture.launcher.terminateCalls, 0)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.red ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.blue ?? true)
    }

    func testMappingWorkspaceRendersAllBindingKindsAtMinimumWindowSize() throws {
        let fixture = makeFixture()
        fixture.model.preferences.markSetupCompleted(autoLaunch: false)
        fixture.model.dashboardSection = .mappings
        fixture.model.setBinding(.taskSlot(0), for: .key01)
        fixture.model.setBinding(.codexAction("approval.approve"), for: .key02)
        fixture.model.setBinding(
            .skill(
                SkillReference(
                    name: "release-readiness",
                    displayName: "Очень длинное имя навыка",
                    path: "/tmp/SKILL.md"
                )
            ),
            for: .key03
        )
        fixture.model.setBinding(
            .pluginPrompt(
                PluginPrompt(
                    uri: "plugin://release-readiness",
                    displayName: "Очень длинное имя плагина"
                )
            ),
            for: .key04
        )
        fixture.model.setBinding(
            .shortcut(
                ShortcutBinding(
                    keyCode: 1,
                    command: true,
                    option: true,
                    shift: true
                )
            ),
            for: .key05
        )
        fixture.model.setBinding(
            .profileSwitch(
                profileID: fixture.model.activeProfile.id,
                behavior: .momentary
            ),
            for: .key06
        )
        fixture.model.setBinding(.none, for: .key07)

        let renderer = ImageRenderer(
            content: HStack(spacing: 0) {
                Color(nsColor: .underPageBackgroundColor)
                    .frame(width: 190)
                HStack(alignment: .top, spacing: 16) {
                    DeviceMapView()
                        .environmentObject(fixture.model)
                        .frame(width: 520)
                    AssignmentInspector()
                        .environmentObject(fixture.model)
                        .frame(width: 300, height: 510, alignment: .top)
                }
                .padding(20)
                .frame(width: 910, height: 700, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .frame(width: 1_100, height: 700)
        )
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 1_100, height: 700)
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 1_100)
        XCTAssertEqual(image.height, 700)

        if let path = ProcessInfo.processInfo.environment[
            "NOSTROMO_LAYOUT_SNAPSHOT_PATH"
        ] {
            let representation = NSBitmapImageRep(cgImage: image)
            let data = try XCTUnwrap(
                representation.representation(
                    using: .png,
                    properties: [:]
                )
            )
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testUnavailableBridgeBecomesRecoverableReadinessError() async {
        let preferences = AppPreferences.ephemeral()
        preferences.markSetupCompleted(autoLaunch: false)
        let hid = FakeHID()
        let model = AppModel(
            launcher: FakeLauncher(),
            hid: hid,
            bridge: UnavailableBridge(reason: "read-only runtime directory"),
            shortcutPoster: FakeShortcutPoster(access: true),
            keyboardSuppressor: FakeKeyboardSuppressor(),
            preferences: preferences
        )

        model.start()
        hid.emit(
            state: .connected(interfaceCount: 2, captureMode: .shared)
        )
        await settle()

        XCTAssertEqual(model.bridgeStatus, .failed(
            "Не удалось запустить приватное подключение к Codex: read-only runtime directory"
        ))
        XCTAssertEqual(model.readiness, .fallback)
        XCTAssertEqual(
            model.lastError,
            "Не удалось запустить приватное подключение к Codex: read-only runtime directory"
        )
    }

    func testFreshStartWaitsForSetupBeforeCapturingHIDOrLaunchingChatGPT() async {
        let fixture = makeFixture()
        let model = fixture.model

        model.start()
        await settle()

        XCTAssertFalse(model.preferences.setupCompleted)
        XCTAssertEqual(model.readiness, .setupRequired)
        XCTAssertEqual(fixture.hid.startCalls, 0)
        XCTAssertEqual(fixture.bridge.startCalls, 1)
        XCTAssertEqual(fixture.launcher.launchCalls, 0)
        XCTAssertEqual(fixture.launcher.terminateCalls, 0)
    }

    func testExistingConfigurationIsAdoptedOnlyOnFirstRedesignedLaunch() throws {
        let suiteName = "io.nostromo-codex.tests.preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigurationStore(fileURL: root.appendingPathComponent("profiles.json"))
        try store.save(.defaults())
        let preferences = AppPreferences(defaults: defaults)

        _ = AppModel(
            store: store,
            launcher: FakeLauncher(),
            hid: FakeHID(),
            bridge: FakeBridge(),
            shortcutPoster: FakeShortcutPoster(access: true),
            keyboardSuppressor: FakeKeyboardSuppressor(),
            preferences: preferences
        )

        XCTAssertTrue(preferences.setupCompleted)
        XCTAssertTrue(preferences.autoLaunchChatGPT)
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func testPartiallyCompletedSetupDoesNotBecomeLegacyConfigurationOnRelaunch() throws {
        let suiteName = "io.nostromo-codex.tests.preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        _ = AppPreferences(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigurationStore(fileURL: root.appendingPathComponent("profiles.json"))
        try store.save(.defaults())
        let relaunchedPreferences = AppPreferences(defaults: defaults)

        _ = AppModel(
            store: store,
            launcher: FakeLauncher(),
            hid: FakeHID(),
            bridge: FakeBridge(),
            shortcutPoster: FakeShortcutPoster(access: true),
            keyboardSuppressor: FakeKeyboardSuppressor(),
            preferences: relaunchedPreferences
        )

        XCTAssertFalse(relaunchedPreferences.setupCompleted)
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func testCompletingSetupStartsHIDWithoutTerminatingRunningChatGPT() async {
        let fixture = makeFixture()
        let model = fixture.model
        model.start()
        await settle()

        model.completeSetup(autoLaunch: true)
        await settle()

        XCTAssertTrue(model.preferences.setupCompleted)
        XCTAssertTrue(model.preferences.autoLaunchChatGPT)
        XCTAssertEqual(fixture.hid.startCalls, 1)
        XCTAssertEqual(fixture.launcher.launchCalls, 0)
        XCTAssertEqual(fixture.launcher.terminateCalls, 0)
        XCTAssertTrue(model.chatGPTNeedsRestart)
    }

    func testReturningFromInputMonitoringSettingsRetriesHIDConnection() async {
        let fixture = makeFixture()
        fixture.hid.emit(state: .waitingForPermission)
        await settle()

        let lightingCount = fixture.hid.lightingSummaries.count
        fixture.model.refreshInputMonitoringAfterSettings()

        XCTAssertEqual(fixture.hid.startCalls, 1)
        XCTAssertEqual(fixture.hid.lightingSummaries.count, lightingCount + 1)
    }

    func testControllerAlwaysRequestsExclusiveCapture() {
        let fixture = makeFixture()

        fixture.model.connectController()

        XCTAssertEqual(fixture.hid.startSeizeValues, [true])
    }

    func testBecomingActiveDoesNotRestartHIDOutsidePermissionFlow() {
        let fixture = makeFixture()

        fixture.model.refreshInputMonitoringAfterSettings()

        XCTAssertEqual(fixture.hid.startCalls, 0)
        XCTAssertTrue(fixture.hid.lightingSummaries.isEmpty)
    }

    func testInputTestHighlightsControlsAndNeverDispatchesAssignment() async {
        let fixture = makeFixture()
        let model = fixture.model
        model.setBinding(.codexAction("composer.submit"), for: .key01)
        model.setInputTestMode(true)

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertTrue(model.activeControls.contains(.key01))
        XCTAssertTrue(fixture.bridge.actions.isEmpty)

        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertFalse(model.activeControls.contains(.key01))
        XCTAssertTrue(fixture.bridge.actions.isEmpty)

        fixture.hid.emit(
            signature: HIDSignature(usagePage: 0x01, usage: 0x38, cookie: 90, kind: .axis),
            value: 1
        )
        fixture.hid.emitButton(.wheelPress, pressed: true, configuration: model.configuration)
        fixture.hid.emitButton(.wheelPress, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.wheelMode, .scroll)
        XCTAssertTrue(fixture.bridge.actions.isEmpty)
    }

    func testClearingActiveProfileRemovesEveryAssignmentAndPersistsBlankLayout() throws {
        let fixture = makeFixture()
        let model = fixture.model
        let untouchedProfile = ControllerProfile(
            name: "Отдельный профиль",
            bindings: [.key01: .codexAction("composer.submit")]
        )
        model.configuration.profiles.append(untouchedProfile)

        model.clearActiveProfileBindings()

        XCTAssertEqual(Set(model.activeProfile.bindings.keys), Set(ControlID.allCases))
        XCTAssertTrue(model.activeProfile.bindings.values.allSatisfy { $0 == .none })
        XCTAssertEqual(
            model.configuration.profiles.first(where: { $0.id == untouchedProfile.id })?.bindings[.key01],
            .codexAction("composer.submit")
        )

        let persisted = try fixture.model.store.load()
        let persistedActiveProfile = try XCTUnwrap(
            persisted.profiles.first(where: { $0.id == persisted.activeProfileID })
        )
        XCTAssertEqual(Set(persistedActiveProfile.bindings.keys), Set(ControlID.allCases))
        XCTAssertTrue(persistedActiveProfile.bindings.values.allSatisfy { $0 == .none })
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

    func testMomentaryProfileReturnsUsingPressedActionFromOriginalProfile() async {
        let fixture = makeFixture()
        let model = fixture.model
        let originalID = model.configuration.activeProfileID
        let target = ControllerProfile(name: "Momentary", bindings: [.key01: .none])
        model.configuration.profiles.append(target)
        model.setBinding(.profileSwitch(profileID: target.id, behavior: .momentary), for: .key01)

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, target.id)
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, originalID)
    }

    func testOverlappingMomentaryProfilesAreRuntimeOnlyAndReleaseOutOfOrder() async throws {
        let fixture = makeFixture()
        let model = fixture.model
        let originalID = model.configuration.activeProfileID
        let second = ControllerProfile(name: "Second", bindings: [:])
        var third = ControllerProfile(name: "Third", bindings: [:])
        third.bindings[.key02] = BindingAction.none
        var secondWithBinding = second
        secondWithBinding.bindings[.key02] =
            .profileSwitch(profileID: third.id, behavior: .momentary)
        model.configuration.profiles.append(contentsOf: [secondWithBinding, third])
        model.setBinding(
            .profileSwitch(profileID: second.id, behavior: .momentary),
            for: .key01
        )

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, second.id)
        XCTAssertEqual(try fixture.model.store.load().activeProfileID, originalID)

        fixture.hid.emitButton(.key02, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, third.id)
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, third.id)
        fixture.hid.emitButton(.key02, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, originalID)
        XCTAssertEqual(try fixture.model.store.load().activeProfileID, originalID)
    }

    func testMomentaryProfileExportsPersistentBaseAndDeleteTargetsVisibleProfile() async throws {
        let fixture = makeFixture()
        let model = fixture.model
        let originalID = model.configuration.activeProfileID
        let target = ControllerProfile(name: "Visible momentary profile", bindings: [:])
        model.configuration.profiles.append(target)
        model.setBinding(
            .profileSwitch(profileID: target.id, behavior: .momentary),
            for: .key01
        )

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, target.id)
        XCTAssertEqual(model.persistedConfigurationSnapshot().activeProfileID, originalID)

        model.deleteActiveProfile()
        XCTAssertFalse(model.configuration.profiles.contains(where: { $0.id == target.id }))
        XCTAssertTrue(model.configuration.profiles.contains(where: { $0.id == originalID }))
        XCTAssertEqual(model.configuration.activeProfileID, originalID)
        XCTAssertEqual(try model.store.load().activeProfileID, originalID)

        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, originalID)
    }

    func testDisconnectStopsLatchedPushToTalk() async {
        let fixture = makeFixture()
        let model = fixture.model
        model.setBinding(.codexAction("pushToTalk"), for: .key01)
        let signature = try! XCTUnwrap(model.configuration.calibration.signatures[.key01])

        fixture.hid.emit(signature: signature, value: 1, timestamp: 1)
        await settle()
        fixture.hid.emit(signature: signature, value: 0, timestamp: 1.1)
        await settle()
        fixture.hid.emit(signature: signature, value: 1, timestamp: 1.25)
        await settle()
        fixture.hid.emit(signature: signature, value: 0, timestamp: 1.3)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.suffix(2).map(\.name), [
            "push-to-talk-stop",
            "push-to-talk-start",
        ])

        fixture.hid.emit(state: .disconnected)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "push-to-talk-stop")
    }

    func testBridgeDisconnectResetsPushToTalkStateBeforeReconnect() async {
        let fixture = makeFixture()
        let model = fixture.model
        model.setBinding(.codexAction("pushToTalk"), for: .key01)
        fixture.bridge.onStatus?(.connected)
        fixture.bridge.onCapabilities?(completeTestCapabilities())
        await settle()

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "push-to-talk-start")

        fixture.bridge.onStatus?(.listening)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "push-to-talk-stop")

        fixture.bridge.onStatus?(.connected)
        fixture.bridge.onCapabilities?(completeTestCapabilities())
        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertNotEqual(fixture.bridge.actions.last?.name, "push-to-talk-start")
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()
        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "push-to-talk-start")
    }

    func testTaskSlotMetadataReplacesGenericLabelAndClearsOnDisconnect() async {
        let fixture = makeFixture()
        let model = fixture.model
        model.setBinding(.taskSlot(3), for: .key01)

        fixture.bridge.onStatus?(.connected)
        fixture.bridge.onCapabilities?(completeTestCapabilities())
        fixture.bridge.onTaskSlots?([
            CodexTaskSlot(
                id: 3,
                title: "Исправить меню дока",
                status: .working,
                selected: true
            ),
        ])
        await settle()

        XCTAssertEqual(model.compactBindingSummary(for: .key01), "Исправить меню дока")
        XCTAssertEqual(
            model.bindingSummary(for: .key01),
            "Задача 4 · Исправить меню дока"
        )
        XCTAssertEqual(model.taskSlot(3)?.status, .working)

        fixture.bridge.onStatus?(.listening)
        await settle()

        XCTAssertTrue(model.taskSlots.isEmpty)
        XCTAssertEqual(model.compactBindingSummary(for: .key01), "Задача 4")
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

    func testCalibrationWaitsForReleaseAndRejectsRepeatedPhysicalButton() async {
        let fixture = makeFixture()
        let model = fixture.model
        let originalCalibration = model.configuration.calibration
        let first = HIDSignature(usagePage: 7, usage: 100, cookie: 41, kind: .button)
        let second = HIDSignature(usagePage: 7, usage: 101, cookie: 42, kind: .button)

        model.beginCalibration()
        fixture.hid.emit(signature: first, value: 1)
        await settle()
        XCTAssertEqual(model.calibrationTarget, .key02)
        XCTAssertEqual(model.configuration.calibration, originalCalibration)

        // Hardware auto-repeat while the first key remains held must not
        // consume the next calibration slot.
        fixture.hid.emit(signature: first, value: 1)
        await settle()
        XCTAssertEqual(model.calibrationTarget, .key02)

        fixture.hid.emit(signature: first, value: 0)
        await settle()
        fixture.hid.emit(signature: first, value: 1)
        await settle()
        XCTAssertEqual(model.calibrationTarget, .key02)
        XCTAssertNotNil(model.lastError)

        fixture.hid.emit(signature: first, value: 0)
        await settle()
        fixture.hid.emit(signature: second, value: 1)
        await settle()
        XCTAssertEqual(model.calibrationTarget, .key03)
        XCTAssertEqual(model.configuration.calibration, originalCalibration)
    }

    func testCancelCalibrationDiscardsAmbiguousDraftAndPreservesPhysicalMapping() async throws {
        let fixture = makeFixture()
        let model = fixture.model
        let originalCalibration = model.configuration.calibration
        let key02Signature = try XCTUnwrap(originalCalibration.signatures[.key02])
        let plugin = PluginPrompt(uri: "plugin://safe", displayName: "Safe")
        model.setBinding(.none, for: .key01)
        model.setBinding(.pluginPrompt(plugin), for: .key02)

        model.beginCalibration()
        // Deliberately press key02 while the wizard asks for key01. The draft
        // is temporarily ambiguous, but the live map must remain untouched.
        fixture.hid.emit(signature: key02Signature, value: 1)
        await settle()
        fixture.hid.emit(signature: key02Signature, value: 0)
        await settle()
        XCTAssertEqual(model.calibrationTarget, .key02)
        XCTAssertEqual(model.configuration.calibration, originalCalibration)

        model.cancelCalibration()
        XCTAssertEqual(model.configuration.calibration, originalCalibration)
        fixture.hid.emit(signature: key02Signature, value: 1)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "prepare-plugin-prompt")
    }

    func testCalibrationDoesNotExecuteBindings() async {
        let fixture = makeFixture()
        let model = fixture.model
        model.setBinding(.codexAction("composer.togglePlanMode"), for: .key01)
        let signature = HIDSignature(usagePage: 7, usage: 110, cookie: 50, kind: .button)
        let before = fixture.bridge.actions.count

        model.beginCalibration()
        fixture.hid.emit(signature: signature, value: 1)
        await settle()
        fixture.hid.emit(
            signature: HIDSignature(usagePage: 0x01, usage: 0x38, cookie: 101, kind: .axis),
            value: 1
        )
        await settle()
        fixture.hid.emit(signature: signature, value: 0)
        await settle()

        XCTAssertEqual(fixture.bridge.actions.count, before)
        XCTAssertEqual(model.calibrationTarget, .key02)
    }

    func testHighRateDPadStreamResolvesBeforeStreamStops() async {
        let fixture = makeFixture()
        let model = fixture.model
        let target = ControllerProfile(name: "High-rate D-pad", bindings: [:])
        model.configuration.profiles.append(target)
        model.setBinding(
            .profileSwitch(profileID: target.id, behavior: .momentary),
            for: .dpadUp
        )
        let yAxis = HIDSignature(usagePage: 0x01, usage: 0x31, cookie: 103, kind: .axis)
        var activatedDuringStream = false

        for _ in 0 ..< 40 {
            fixture.hid.emit(
                signature: yAxis,
                value: -1,
                timestamp: ProcessInfo.processInfo.systemUptime
            )
            try? await Task.sleep(for: .milliseconds(2))
            activatedDuringStream = activatedDuringStream
                || model.configuration.activeProfileID == target.id
        }

        XCTAssertTrue(activatedDuringStream)
    }

    func testPhysicalKeyboardPageDPadExecutesDiagonalExactlyOnce() async {
        let fixture = makeFixture()
        let model = fixture.model
        let originalID = model.configuration.activeProfileID
        let target = ControllerProfile(name: "Keyboard D-pad", bindings: [:])
        model.configuration.profiles.append(target)
        model.setBinding(
            .profileSwitch(profileID: target.id, behavior: .momentary),
            for: .dpadUpRight
        )
        let now = ProcessInfo.processInfo.systemUptime

        fixture.hid.emit(
            signature: HIDSignature(
                usagePage: 0x07,
                usage: 0x50,
                cookie: 201,
                kind: .button
            ),
            value: 1,
            timestamp: now
        )
        fixture.hid.emit(
            signature: HIDSignature(
                usagePage: 0x07,
                usage: 0x52,
                cookie: 202,
                kind: .button
            ),
            value: 1,
            timestamp: now + 0.002
        )
        try? await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(model.configuration.activeProfileID, target.id)

        fixture.hid.emit(
            signature: HIDSignature(
                usagePage: 0x07,
                usage: 0x50,
                cookie: 201,
                kind: .button
            ),
            value: 0,
            timestamp: now + 0.050
        )
        fixture.hid.emit(
            signature: HIDSignature(
                usagePage: 0x07,
                usage: 0x52,
                cookie: 202,
                kind: .button
            ),
            value: 0,
            timestamp: now + 0.052
        )
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, originalID)
    }

    func testHIDOnlyModeRecordsInputWithoutStartingBridgeOrExecutingActions() async throws {
        let fixture = makeFixture(hidOnlyMode: true)
        let model = fixture.model
        model.setBinding(.codexAction("composer.togglePlanMode"), for: .key01)

        model.start()
        await settle()
        XCTAssertEqual(fixture.hid.startCalls, 1)
        XCTAssertEqual(fixture.bridge.startCalls, 0)
        XCTAssertFalse(model.chatGPTNeedsRestart)
        XCTAssertEqual(
            fixture.hid.lightingSummaries.last,
            NostromoLightingSummary(
                red: false,
                green: false,
                blue: false,
                backlightBrightness: 41
            )
        )

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        fixture.hid.emit(
            signature: HIDSignature(usagePage: 0x01, usage: 0x38, cookie: 90, kind: .axis),
            value: 1
        )
        await settle()

        XCTAssertTrue(fixture.bridge.actions.isEmpty)
        XCTAssertEqual(model.hidDiagnosticEvents.count, 3)
        XCTAssertEqual(model.hidDiagnosticEvents.map(\.sequence), [1, 2, 3])

        model.restartThroughNostromo()
        model.launchChatGPT()
        await settle()
        XCTAssertEqual(fixture.launcher.launchCalls, 0)
        XCTAssertEqual(fixture.launcher.terminateCalls, 0)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: model.hidDiagnosticsData()) as? [String: Any]
        )
        XCTAssertEqual(object["hidOnlyMode"] as? Bool, true)
        XCTAssertEqual((object["vendorID"] as? NSNumber)?.intValue, 0x1532)
        XCTAssertEqual((object["productID"] as? NSNumber)?.intValue, 0x0111)
        XCTAssertEqual((object["formatVersion"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual(object["architecture"] as? String, "arm64")
        XCTAssertNotNil(object["operatingSystem"] as? String)
        XCTAssertNotNil(object["deviceState"] as? String)
        XCTAssertNotNil(object["inputProtection"] as? String)
        let identity = try XCTUnwrap(
            object["applicationIdentity"] as? [String: Any]
        )
        XCTAssertFalse(
            (identity["runningBundlePath"] as? String ?? "").isEmpty
        )
        let pipeline = try XCTUnwrap(
            object["pipeline"] as? [String: Any]
        )
        XCTAssertEqual(
            (pipeline["rawEventCount"] as? NSNumber)?.intValue,
            3
        )
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 3)
        XCTAssertNotNil(events[0]["receivedAtUptime"] as? NSNumber)
        XCTAssertNotNil(events[0]["callbackLatencyMilliseconds"] as? NSNumber)
        XCTAssertNotNil(model.hidCallbackLatencyP95Milliseconds)

        model.clearHIDDiagnostics()
        XCTAssertTrue(model.hidDiagnosticEvents.isEmpty)
    }

    func testRepeatedDPadReportsRescheduleMomentaryRelease() async {
        let fixture = makeFixture()
        let model = fixture.model
        let originalID = model.configuration.activeProfileID
        let target = ControllerProfile(name: "Held D-pad", bindings: [:])
        model.configuration.profiles.append(target)
        model.setBinding(
            .profileSwitch(profileID: target.id, behavior: .momentary),
            for: .dpadUp
        )

        let startedAt = ProcessInfo.processInfo.systemUptime
        let yAxis = HIDSignature(usagePage: 0x01, usage: 0x31, cookie: 103, kind: .axis)
        fixture.hid.emit(signature: yAxis, value: -1, timestamp: startedAt)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.configuration.activeProfileID, target.id)

        // Nostromo's relative axis repeats while the stick remains held.
        try? await Task.sleep(for: .milliseconds(60))
        fixture.hid.emit(signature: yAxis, value: -1, timestamp: startedAt + 0.09)
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(model.configuration.activeProfileID, target.id)

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.configuration.activeProfileID, originalID)
    }

    func testDuplicateButtonEdgesDoNotRepeatActionsOrBreakMomentaryReturn() async {
        let fixture = makeFixture()
        let model = fixture.model
        let plugin = PluginPrompt(uri: "plugin://calendar", displayName: "Calendar")
        model.setBinding(.pluginPrompt(plugin), for: .key01)

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(
            fixture.bridge.actions.filter { $0.name == "prepare-plugin-prompt" }.count,
            1
        )
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()

        let originalID = model.configuration.activeProfileID
        let target = ControllerProfile(name: "Momentary repeat", bindings: [:])
        model.configuration.profiles.append(target)
        model.setBinding(
            .profileSwitch(profileID: target.id, behavior: .momentary),
            for: .key02
        )
        fixture.hid.emitButton(.key02, pressed: true, configuration: model.configuration)
        fixture.hid.emitButton(.key02, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, target.id)
        fixture.hid.emitButton(.key02, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, originalID)
    }

    func testDuplicateWheelPressCannotUndoRotationClickSuppression() async throws {
        let fixture = makeFixture()
        let model = fixture.model
        let wheelPress = try XCTUnwrap(model.configuration.calibration.signatures[.wheelPress])
        let wheelAxis = HIDSignature(usagePage: 0x01, usage: 0x38, cookie: 101, kind: .axis)

        fixture.hid.emit(signature: wheelPress, value: 1, timestamp: 1)
        await settle()
        fixture.hid.emit(signature: wheelAxis, value: 1, timestamp: 1.1)
        await settle()
        fixture.hid.emit(signature: wheelPress, value: 1, timestamp: 1.2)
        await settle()
        fixture.hid.emit(signature: wheelPress, value: 0, timestamp: 1.3)
        await settle()

        fixture.hid.emit(signature: wheelAxis, value: 1, timestamp: 1.4)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "scroll-task")
    }

    func testDisconnectSuppressesCarriedDPadAndAcceptsFreshPostGateGesture() async {
        let fixture = makeFixture()
        let model = fixture.model
        let originalID = model.configuration.activeProfileID
        let target = ControllerProfile(name: "Reconnect", bindings: [:])
        model.configuration.profiles.append(target)
        model.setBinding(
            .profileSwitch(profileID: target.id, behavior: .momentary),
            for: .dpadUp
        )
        let yAxis = HIDSignature(usagePage: 0x01, usage: 0x31, cookie: 103, kind: .axis)
        let startedAt = ProcessInfo.processInfo.systemUptime

        fixture.hid.emit(signature: yAxis, value: -1, timestamp: startedAt)
        let activatedBeforeDisconnect = await waitUntil {
            model.configuration.activeProfileID == target.id
        }
        XCTAssertTrue(activatedBeforeDisconnect)

        fixture.hid.emit(state: .disconnected)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, originalID)
        fixture.hid.emit(
            state: .connected(interfaceCount: 2, captureMode: .shared)
        )
        await settle()

        fixture.hid.emit(
            signature: yAxis,
            value: -1,
            timestamp: ProcessInfo.processInfo.systemUptime,
            eligibleForAction: false
        )
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, originalID)

        fixture.hid.emit(
            signature: yAxis,
            value: -1,
            timestamp: ProcessInfo.processInfo.systemUptime,
            eligibleForAction: true
        )
        let activatedAfterReconnect = await waitUntil {
            model.configuration.activeProfileID == target.id
        }
        XCTAssertTrue(activatedAfterReconnect)
    }

    func testPermutedDPadCalibrationReleasesMappedControlOnTransition() async {
        let fixture = makeFixture()
        let model = fixture.model
        let originalID = model.configuration.activeProfileID
        let first = ControllerProfile(name: "Mapped up", bindings: [:])
        let second = ControllerProfile(name: "Mapped right", bindings: [:])
        model.configuration.profiles.append(contentsOf: [first, second])
        model.configuration.calibration.dpadDirections[.up] = .dpadRight
        model.configuration.calibration.dpadDirections[.right] = .dpadUp
        model.setBinding(
            .profileSwitch(profileID: first.id, behavior: .momentary),
            for: .dpadRight
        )
        model.setBinding(
            .profileSwitch(profileID: second.id, behavior: .momentary),
            for: .dpadUp
        )
        if let firstIndex = model.configuration.profiles.firstIndex(where: { $0.id == first.id }) {
            model.configuration.profiles[firstIndex].bindings[.dpadUp] =
                .profileSwitch(profileID: second.id, behavior: .momentary)
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        fixture.hid.emit(
            signature: HIDSignature(usagePage: 0x01, usage: 0x31, cookie: 103, kind: .axis),
            value: -1,
            timestamp: startedAt
        )
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.configuration.activeProfileID, first.id)

        fixture.hid.emit(
            signature: HIDSignature(usagePage: 0x01, usage: 0x30, cookie: 102, kind: .axis),
            value: 1,
            timestamp: startedAt + 0.03
        )
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.configuration.activeProfileID, first.id)

        try? await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(model.configuration.activeProfileID, originalID)

        fixture.hid.emit(
            signature: HIDSignature(usagePage: 0x01, usage: 0x30, cookie: 102, kind: .axis),
            value: 1,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.configuration.activeProfileID, second.id)
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

    func testCalibrationReleasesActiveInputAndDisconnectCancelsDraft() async {
        let fixture = makeFixture()
        let model = fixture.model
        model.setBinding(.codexAction("pushToTalk"), for: .key01)
        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "push-to-talk-start")

        model.beginCalibration()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "push-to-talk-stop")

        let first = HIDSignature(usagePage: 7, usage: 120, cookie: 60, kind: .button)
        let second = HIDSignature(usagePage: 7, usage: 121, cookie: 61, kind: .button)
        fixture.hid.emit(signature: first, value: 1)
        await settle()
        XCTAssertEqual(model.calibrationTarget, .key02)
        fixture.hid.emit(state: .disconnected)
        await settle()
        fixture.hid.emit(signature: second, value: 1)
        await settle()
        XCTAssertNil(model.calibrationTarget)
        XCTAssertNotEqual(
            model.configuration.calibration.signatures[.key02]?.portableKey,
            second.portableKey
        )
    }

    func testCancelCalibrationCancelsPendingDPadResolution() async {
        let fixture = makeFixture()
        let model = fixture.model
        let target = ControllerProfile(name: "Must not activate", bindings: [:])
        model.configuration.profiles.append(target)
        model.setBinding(
            .profileSwitch(profileID: target.id, behavior: .momentary),
            for: .dpadUp
        )
        model.beginCalibration()
        let actionCount = fixture.bridge.actions.count

        fixture.hid.emit(
            signature: HIDSignature(usagePage: 0x01, usage: 0x31, cookie: 103, kind: .axis),
            value: -1,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        try? await Task.sleep(for: .milliseconds(5))
        model.cancelCalibration()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertNotEqual(model.configuration.activeProfileID, target.id)
        XCTAssertEqual(fixture.bridge.actions.count, actionCount)
    }

    func testShutdownStopsServicesAndPushToTalkSynchronously() async {
        let fixture = makeFixture()
        let model = fixture.model
        model.setBinding(.codexAction("pushToTalk"), for: .key01)
        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()

        model.shutdown()

        XCTAssertEqual(fixture.bridge.actions.last?.name, "push-to-talk-stop")
        XCTAssertEqual(fixture.hid.stopCalls, 1)
        XCTAssertEqual(fixture.bridge.stopCalls, 1)
    }

    func testLightingSettingsPersistAndApplyImmediately() throws {
        let fixture = makeFixture()
        let model = fixture.model

        model.setMaximumLightingBrightness(0.5)
        model.setPressFeedbackStrength(0.4)
        model.setPressFeedbackEnabled(false)
        model.setKeypadLightingEnabled(false)

        XCTAssertFalse(model.configuration.lighting.keypadEnabled)
        XCTAssertEqual(model.configuration.lighting.maximumBrightness, 0.5)
        XCTAssertFalse(model.configuration.lighting.pressFeedbackEnabled)
        XCTAssertEqual(model.configuration.lighting.pressFeedbackStrength, 0.4)
        XCTAssertEqual(fixture.hid.lightingSummaries.last?.backlightBrightness, 0)

        let stored = try model.store.load()
        XCTAssertEqual(stored.lighting.maximumBrightness, 0.5)
        XCTAssertFalse(stored.lighting.keypadEnabled)
        XCTAssertFalse(stored.lighting.pressFeedbackEnabled)
        XCTAssertEqual(stored.lighting.pressFeedbackStrength, 0.4)
    }

    func testTaskIndicatorsStayDarkWhileIdle() {
        let fixture = makeFixture()
        let model = fixture.model

        XCTAssertFalse(model.lightingResolution.taskStatusOwnsIndicators)
        XCTAssertFalse(model.lightingResolution.summary.red)
        XCTAssertFalse(model.lightingResolution.summary.green)
        XCTAssertFalse(model.lightingResolution.summary.blue)
    }

    func testTaskIndicatorsFollowReadyRunningAttentionAndCompletionLifecycle() async {
        let fixture = makeFixture()

        fixture.bridge.onStatus?(.connected)
        fixture.bridge.onCapabilities?(completeTestCapabilities())
        await settle()
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.red ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.blue ?? false)

        func publish(_ status: CodexTaskStatus) {
            fixture.bridge.onTaskSlots?([
                CodexTaskSlot(
                    id: 0,
                    title: "Проверить индикаторы",
                    status: status,
                    selected: true
                ),
            ])
        }

        publish(.working)
        await settle()
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.red ?? true)
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.green ?? false)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.blue ?? true)

        publish(.awaitingApproval)
        await settle()
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.red ?? false)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.blue ?? true)

        publish(.awaitingResponse)
        await settle()
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.red ?? false)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.blue ?? true)

        publish(.working)
        await settle()
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.red ?? true)
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.green ?? false)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.blue ?? true)

        publish(.unread)
        await settle()
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.red ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.blue ?? false)

        publish(.idle)
        await settle()
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.red ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.blue ?? false)

        publish(.error)
        await settle()
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.red ?? false)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.blue ?? true)

        fixture.bridge.onStatus?(.listening)
        await settle()
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.red ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.blue ?? true)
    }

    func testTaskCompletionFlashesKeypadOnceOnTransitionToUnread() async {
        let fixture = makeFixture()

        func publish(_ status: CodexTaskStatus) {
            fixture.bridge.onTaskSlots?([
                CodexTaskSlot(
                    id: 0,
                    title: "Завершить задачу",
                    status: status,
                    selected: true
                ),
            ])
        }

        publish(.working)
        await settle()
        XCTAssertTrue(fixture.hid.backlightPulseStrengths.isEmpty)

        publish(.unread)
        await settle()
        XCTAssertEqual(fixture.hid.backlightPulseStrengths, [1])

        publish(.unread)
        await settle()
        XCTAssertEqual(fixture.hid.backlightPulseStrengths, [1])
    }

    func testInitialUnreadSnapshotDoesNotFlashStaleTaskCompletion() async {
        let fixture = makeFixture()

        fixture.bridge.onTaskSlots?([
            CodexTaskSlot(
                id: 0,
                title: "Уже завершено",
                status: .unread,
                selected: true
            ),
        ])
        await settle()

        XCTAssertTrue(fixture.hid.backlightPulseStrengths.isEmpty)
    }

    func testTaskCompletionFlashHonorsDisabledKeypadLighting() async {
        let fixture = makeFixture()
        fixture.model.setKeypadLightingEnabled(false)

        fixture.bridge.onTaskSlots?([
            CodexTaskSlot(
                id: 0,
                title: "Без вспышки",
                status: .working,
                selected: true
            ),
        ])
        await settle()
        fixture.bridge.onTaskSlots?([
            CodexTaskSlot(
                id: 0,
                title: "Без вспышки",
                status: .unread,
                selected: true
            ),
        ])
        await settle()

        XCTAssertTrue(fixture.hid.backlightPulseStrengths.isEmpty)
    }

    func testTaskIndicatorPriorityPrefersAttentionOverConcurrentWork() async {
        let fixture = makeFixture()
        fixture.bridge.onStatus?(.connected)
        fixture.bridge.onCapabilities?(completeTestCapabilities())
        fixture.bridge.onTaskSlots?([
            CodexTaskSlot(
                id: 0,
                title: "Выполняется",
                status: .working,
                selected: true
            ),
            CodexTaskSlot(
                id: 1,
                title: "Нужно подтверждение",
                status: .awaitingApproval,
                selected: false
            ),
        ])
        await settle()

        XCTAssertTrue(fixture.hid.lightingSummaries.last?.red ?? false)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.blue ?? true)
    }

    func testCodexMicroInactivityBlackoutCannotClearWorkingTaskIndicator() async throws {
        let fixture = makeFixture()
        fixture.bridge.onStatus?(.connected)
        fixture.bridge.onCapabilities?(completeTestCapabilities())
        fixture.bridge.onTaskSlots?([
            CodexTaskSlot(
                id: 0,
                title: "Длительная задача",
                status: .working,
                selected: true
            ),
        ])
        await settle()
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.green ?? false)

        let reports = try Project2077.encodeJSON([
            "method": "v.oai.thstatus",
            "params": (0 ..< 6).map { id in
                [
                    "id": id,
                    "c": 0,
                    "b": 0,
                    "e": 0,
                    "s": 0,
                ]
            },
        ])
        for report in reports {
            fixture.bridge.onHostReport?(report)
        }
        await settle()

        XCTAssertFalse(fixture.hid.lightingSummaries.last?.red ?? true)
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.green ?? false)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.blue ?? true)
        XCTAssertEqual(fixture.model.taskSlot(0)?.status, .working)
    }

    func testConnectedControllerSuppressesOnlyNostromoKeyboardUsagesAndRestoresOnStop() async {
        let fixture = makeFixture()

        fixture.hid.emit(
            state: .connected(interfaceCount: 2, captureMode: .shared)
        )
        let suppressionApplied = await waitUntil {
            fixture.keyboardSuppressor.suppressedUsages.count == 1
        }
        XCTAssertTrue(suppressionApplied)

        let usages = try? XCTUnwrap(fixture.keyboardSuppressor.suppressedUsages.last)
        let expectedUsages = Set(
            CalibrationMap.nostromoFactory.signatures.values
                .filter { $0.usagePage == 0x07 && $0.kind == .button }
                .map(\.usage)
        ).union([0x4F, 0x50, 0x51, 0x52])
        XCTAssertEqual(usages, expectedUsages)
        XCTAssertEqual(
            fixture.model.inputProtectionStatus,
            .active(serviceCount: 1, usageCount: usages?.count ?? 0)
        )

        fixture.model.setControllerEnabled(false)
        XCTAssertEqual(fixture.keyboardSuppressor.restoreCalls, 1)
        XCTAssertEqual(fixture.model.inputProtectionStatus, .inactive)
    }

    func testExclusiveCaptureDispatchesWithoutApplyingUserKeyMapping() async {
        let fixture = makeFixture()
        fixture.model.setBinding(
            .codexAction("toggleSidebar"),
            for: .key01
        )
        await settle()

        XCTAssertEqual(
            fixture.model.inputProtectionStatus,
            .exclusiveCapture
        )
        XCTAssertTrue(fixture.keyboardSuppressor.suppressedUsages.isEmpty)

        fixture.hid.emitButton(
            .key01,
            pressed: true,
            configuration: fixture.model.configuration
        )
        fixture.hid.emitButton(
            .key01,
            pressed: false,
            configuration: fixture.model.configuration
        )
        await settle()

        XCTAssertEqual(fixture.bridge.actions.last?.name, "run-command")
        XCTAssertEqual(
            fixture.bridge.actions.last?.payload["commandId"] as? String,
            "toggleSidebar"
        )
        XCTAssertEqual(
            fixture.model.hidPipelineDiagnostics.rawEventCount,
            2
        )
        XCTAssertEqual(
            fixture.model.hidPipelineDiagnostics.mappedControlCount,
            2
        )
        XCTAssertEqual(
            fixture.model.hidPipelineDiagnostics.bindingExecutionCount,
            1
        )
        XCTAssertEqual(
            fixture.model.hidPipelineDiagnostics.bridgeDispatchAttemptCount,
            1
        )
        XCTAssertEqual(
            fixture.model.hidPipelineDiagnostics.bridgeDispatchSuccessCount,
            1
        )
    }

    func testFailedSharedCaptureProtectionBlocksAssignments() async {
        let fixture = makeFixture()
        let failure = NostromoKeyboardSuppressionFailure(
            failures: [
                NostromoKeyboardServiceFailure(
                    registryID: 9_004,
                    stage: .verification,
                    setterReturned: true,
                    readBackMatched: false,
                    detail: "test rejection"
                ),
            ],
            recoveryPending: false
        )
        fixture.keyboardSuppressor.forcedStatus = .failed(failure)
        fixture.model.setBinding(
            .codexAction("toggleSidebar"),
            for: .key01
        )
        fixture.hid.emit(
            state: .connected(interfaceCount: 2, captureMode: .shared)
        )
        let failurePublished = await waitUntil {
            fixture.model.inputProtectionStatus == .failed(failure)
        }
        XCTAssertTrue(failurePublished)

        fixture.hid.emitButton(
            .key01,
            pressed: true,
            configuration: fixture.model.configuration
        )
        fixture.hid.emitButton(
            .key01,
            pressed: false,
            configuration: fixture.model.configuration
        )
        await settle()

        XCTAssertTrue(fixture.bridge.actions.isEmpty)
        XCTAssertTrue(
            fixture.model.lastError?.contains(
                "Назначения приостановлены"
            ) == true
        )
        XCTAssertEqual(
            fixture.model.hidPipelineDiagnostics.blockedActionCount,
            1
        )
    }

    func testPressFeedbackHonorsEnabledStateAndConfiguredStrength() {
        let fixture = makeFixture()
        let model = fixture.model
        model.setPressFeedbackStrength(0.35)

        model.testLightingFlash()
        XCTAssertEqual(fixture.hid.backlightPulseStrengths.last, 0.35)

        let callCount = fixture.hid.backlightPulseStrengths.count
        model.setPressFeedbackEnabled(false)
        model.testLightingFlash()
        XCTAssertEqual(fixture.hid.backlightPulseStrengths.count, callCount)
    }

    func testCorruptConfigurationIsBackedUpBeforeDefaultsAreSaved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nostromo-corrupt-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("profiles.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corruptData = Data("{truncated".utf8)
        try corruptData.write(to: fileURL)
        let store = ConfigurationStore(fileURL: fileURL)
        let bridge = FakeBridge()
        let hid = FakeHID()
        let launcher = FakeLauncher()
        let shortcutPoster = FakeShortcutPoster(access: true)
        let model = AppModel(
            store: store,
            launcher: launcher,
            hid: hid,
            bridge: bridge,
            shortcutPoster: shortcutPoster,
            keyboardSuppressor: FakeKeyboardSuppressor()
        )

        XCTAssertNotNil(model.lastError)
        model.renameActiveProfile("Recovered")
        model.renameActiveProfile("Recovered Again")

        let recovered = try store.load()
        XCTAssertEqual(recovered.profiles[0].name, "Recovered Again")
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("profiles.invalid-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first)), corruptData)
    }

    func testFailedProfileActivationNeverPublishesUnpersistedCandidate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nostromo-transaction-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("profiles.json")
        let store = ConfigurationStore(fileURL: fileURL)
        var stored = AppConfiguration.defaults()
        let second = ControllerProfile(name: "Second", bindings: [:])
        stored.profiles.append(second)
        try store.save(stored)

        let model = AppModel(
            store: store,
            launcher: FakeLauncher(),
            hid: FakeHID(),
            bridge: FakeBridge(),
            shortcutPoster: FakeShortcutPoster(access: true),
            keyboardSuppressor: FakeKeyboardSuppressor()
        )
        let originalID = model.configuration.activeProfileID

        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.removeItem(at: directory)
        try Data("not a directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        model.activateProfile(second.id)

        XCTAssertEqual(model.configuration.activeProfileID, originalID)
        XCTAssertEqual(model.persistedConfigurationSnapshot().activeProfileID, originalID)
        XCTAssertNotNil(model.lastError)
    }

    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }

    private func waitUntil(
        timeout: Duration = .milliseconds(500),
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func makeFixture(
        hidOnlyMode: Bool = false,
        shortcutAccess: Bool = true
    ) -> AppFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigurationStore(fileURL: root.appendingPathComponent("profiles.json"))
        let bridge = FakeBridge()
        let hid = FakeHID()
        let launcher = FakeLauncher()
        let shortcutPoster = FakeShortcutPoster(access: shortcutAccess)
        let keyboardSuppressor = FakeKeyboardSuppressor()
        let fallback = FakeFallbackController()
        let model = AppModel(
            store: store,
            launcher: launcher,
            hid: hid,
            bridge: bridge,
            shortcutPoster: shortcutPoster,
            keyboardSuppressor: keyboardSuppressor,
            fallbackController: fallback,
            hidOnlyMode: hidOnlyMode
        )
        if !hidOnlyMode {
            model.bridgeStatus = .connected
            bridge.onCapabilities?(completeTestCapabilities())
        }
        // Most AppModel tests exercise mapping/dispatch rather than connection
        // setup. Model that precondition explicitly: production HID events are
        // delivered only after the manager has opened the device.
        hid.emit(
            state: .connected(interfaceCount: 2, captureMode: .exclusive)
        )
        return AppFixture(
            model: model,
            bridge: bridge,
            hid: hid,
            launcher: launcher,
            shortcutPoster: shortcutPoster,
            keyboardSuppressor: keyboardSuppressor,
            fallback: fallback
        )
    }
}

@MainActor
private struct AppFixture {
    let model: AppModel
    let bridge: FakeBridge
    let hid: FakeHID
    let launcher: FakeLauncher
    let shortcutPoster: FakeShortcutPoster
    let keyboardSuppressor: FakeKeyboardSuppressor
    let fallback: FakeFallbackController
}

private func completeTestCapabilities() -> ChatGPTRuntimeCapabilities {
    ChatGPTRuntimeCapabilities(
        commandIDs: Set(CodexActionCatalog.verified.map(\.id)), commandRegistrySource: "test",
        requiredAPIs: ["browserWindow": true, "rendererMessaging": true, "rendererEvaluation": true, "scopedHidHook": true, "microServiceHook": true],
        unavailableFeatures: [], chatGPTVersion: "26.721.41059", chatGPTBuild: "5848", adapterID: "micro-v1"
    )
}

@MainActor
private final class FakeFallbackController: CodexFallbackControlling {
    var hasAccess = true
    var delay: Duration?
    var actions: [CodexFallbackAction] = []
    func perform(_ action: CodexFallbackAction) async throws {
        guard hasAccess else { throw CodexFallbackError.permission }
        if let delay { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        actions.append(action)
    }
}

private final class FakeBridge: BridgeServing, @unchecked Sendable {
    let socketPath = "/tmp/fake.sock"
    let token = "fake-token"
    let isAuthenticated = true
    var onStatus: UnixSocketBridge.StatusHandler?
    var onHostReport: UnixSocketBridge.HostReportHandler?
    var onCapabilities: UnixSocketBridge.CapabilitiesHandler?
    var onRuntimeState: UnixSocketBridge.RuntimeStateHandler?
    var onTaskSlots: UnixSocketBridge.TaskSlotsHandler?

    private let lock = NSLock()
    private var storage: [BridgeAppAction] = []
    private var startCountStorage = 0
    private var stopCountStorage = 0

    var startCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return startCountStorage
    }

    var stopCalls: Int {
        lock.withLock { stopCountStorage }
    }

    var actions: [BridgeAppAction] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func start() {
        lock.lock()
        startCountStorage += 1
        lock.unlock()
        onStatus?(.listening)
    }
    func stop() {
        lock.withLock { stopCountStorage += 1 }
        onStatus?(.stopped)
    }
    func sendDeviceReport(_: Data) {}

    func dispatch(
        _ action: BridgeAppAction,
        completion: (@Sendable (Result<Void, Error>) -> Void)?
    ) {
        lock.lock()
        storage.append(action)
        lock.unlock()
        completion?(.success(()))
    }
}

private final class FakeHID: HIDManaging, @unchecked Sendable {
    var onEvent: (@Sendable (NostromoHIDEvent) -> Void)?
    var onState: (@Sendable (NostromoDeviceState) -> Void)?
    var onDiagnostic: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var startCountStorage = 0
    private var startSeizeStorage: [Bool] = []
    private var stopCountStorage = 0
    private var lightingStorage: [NostromoLightingSummary] = []
    private var backlightPulseStrengthStorage: [Double] = []

    var startCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return startCountStorage
    }

    var stopCalls: Int {
        lock.withLock { stopCountStorage }
    }

    var startSeizeValues: [Bool] {
        lock.withLock { startSeizeStorage }
    }

    var lightingSummaries: [NostromoLightingSummary] {
        lock.withLock { lightingStorage }
    }

    var backlightPulseStrengths: [Double] {
        lock.withLock { backlightPulseStrengthStorage }
    }

    func start(seize: Bool) {
        lock.lock()
        startCountStorage += 1
        startSeizeStorage.append(seize)
        lock.unlock()
    }
    func stop() {
        lock.withLock { stopCountStorage += 1 }
    }
    func requestInputMonitoring() {}
    func applyLighting(_ summary: NostromoLightingSummary) {
        lock.withLock { lightingStorage.append(summary) }
    }
    func pulseBacklight(strength: Double) {
        lock.withLock { backlightPulseStrengthStorage.append(strength) }
    }

    func emitButton(
        _ control: ControlID,
        pressed: Bool,
        configuration: AppConfiguration,
        timestamp: TimeInterval = 1
    ) {
        guard let signature = configuration.calibration.signatures[control] else { return }
        emit(signature: signature, value: pressed ? 1 : 0, timestamp: timestamp)
    }

    func emit(
        signature: HIDSignature,
        value: Int,
        timestamp: TimeInterval = 1,
        eligibleForAction: Bool = true
    ) {
        onEvent?(
            NostromoHIDEvent(
                signature: signature,
                value: value,
                timestamp: timestamp,
                eligibleForAction: eligibleForAction
            )
        )
    }

    func emit(state: NostromoDeviceState) {
        onState?(state)
    }
}

private final class FakeLauncher: ChatGPTLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var activateCountStorage = 0
    private var activeStorage = false
    private var launchCountStorage = 0
    private var terminateCountStorage = 0
    private var compatibilityStorage = ChatGPTCompatibility(version: "26.721.41059", build: "5848", supported: true)

    func setCompatibility(_ value: ChatGPTCompatibility) { lock.withLock { compatibilityStorage = value } }
    func installationIdentifier() -> String { lock.withLock { compatibilityStorage.version + compatibilityStorage.build } }

    var launchCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return launchCountStorage
    }

    var activateCalls: Int {
        lock.withLock { activateCountStorage }
    }

    var terminateCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return terminateCountStorage
    }

    func compatibility() -> ChatGPTCompatibility {
        lock.withLock { compatibilityStorage }
    }

    func isRunning() -> Bool { true }

    func isActive() -> Bool {
        lock.withLock { activeStorage }
    }

    func activate() -> Bool {
        lock.withLock {
            activateCountStorage += 1
            activeStorage = true
        }
        return true
    }

    func launch(
        preloadURL _: URL,
        socketPath _: String,
        token _: String,
        forceUnsupported _: Bool
    ) async throws {
        lock.withLock {
            launchCountStorage += 1
        }
    }

    func terminateRunningApplications() async {
        lock.withLock {
            terminateCountStorage += 1
        }
    }
}

private final class FakeShortcutPoster: ShortcutPosting, @unchecked Sendable {
    struct Event {
        let shortcut: ShortcutBinding
        let keyDown: Bool
    }

    private let lock = NSLock()
    private var accessStorage: Bool
    private var eventStorage: [Event] = []

    init(access: Bool) {
        accessStorage = access
    }

    var access: Bool {
        get {
            lock.withLock { accessStorage }
        }
        set {
            lock.withLock { accessStorage = newValue }
        }
    }

    var events: [Event] {
        lock.withLock { eventStorage }
    }

    func hasPostEventAccess() -> Bool {
        access
    }

    func requestPostEventAccess() -> Bool {
        access
    }

    func post(_ shortcut: ShortcutBinding, keyDown: Bool) -> Bool {
        lock.withLock {
            eventStorage.append(Event(shortcut: shortcut, keyDown: keyDown))
        }
        return true
    }
}

@MainActor
private final class FakeKeyboardSuppressor: NostromoKeyboardSuppressing {
    private(set) var suppressedUsages: [Set<UInt32>] = []
    private(set) var recoverCalls = 0
    private(set) var restoreCalls = 0
    var forcedStatus: NostromoInputProtectionStatus?

    func recover() -> NostromoKeyboardRestorationResult {
        recoverCalls += 1
        return .nothingPending
    }

    func suppress(usages: Set<UInt32>) -> NostromoInputProtectionStatus {
        suppressedUsages.append(usages)
        if let forcedStatus { return forcedStatus }
        return .active(serviceCount: 1, usageCount: usages.count)
    }

    func restore() -> NostromoKeyboardRestorationResult {
        restoreCalls += 1
        return .nothingPending
    }
}
