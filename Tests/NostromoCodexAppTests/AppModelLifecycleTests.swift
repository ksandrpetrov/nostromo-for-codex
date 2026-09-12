import Foundation
@testable import NostromoCodexApp
import NostromoCodexCore
import SwiftUI
import XCTest

@MainActor
final class AppModelLifecycleTests: AppModelTestCase {
    func testQueuedServiceCallbacksCannotReviveShutdownModel() async {
        let fixture = makeFixture()
        await settle()
        let capabilities = fixture.bridge.onCapabilities
        let status = fixture.bridge.onStatus
        let hidState = fixture.hid.onState
        status?(.connected)
        capabilities?(completeTestCapabilities())
        hidState?(.connected(interfaceCount: 2, captureMode: .exclusive))
        fixture.model.shutdown()
        let dispatchCount = fixture.bridge.actions.count
        let lightingCount = fixture.hid.lightingSummaries.count
        await settle()
        XCTAssertEqual(fixture.bridge.actions.count, dispatchCount)
        XCTAssertEqual(fixture.hid.lightingSummaries.count, lightingCount)
        XCTAssertFalse(fixture.model.inputProtectionAllowsActions)
    }

    func testLaunchRequestedAfterShutdownDoesNotReachLauncher() async {
        let fixture = makeFixture()
        await settle()
        fixture.model.shutdown()
        fixture.model.launchChatGPT()
        fixture.model.restartThroughNostromo()
        await settle()
        XCTAssertEqual(fixture.launcher.launchCalls, 0)
        XCTAssertEqual(fixture.launcher.terminateCalls, 0)
    }

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

    func testUnsupportedRestartPreservesRunningApplication() async {
        let fixture = makeFixture()
        fixture.launcher.setCompatibility(ChatGPTCompatibility(version: "future", build: "9999", supported: false))
        fixture.model.restartThroughNostromo()
        await settle()
        XCTAssertEqual(fixture.launcher.terminateCalls, 0)
        XCTAssertEqual(fixture.launcher.launchCalls, 0)
        XCTAssertNotNil(fixture.model.lastError)
    }

    func testRestartWithUnavailableBridgePreservesRunningApplication() async {
        let fixture = makeFixture()
        fixture.bridge.onStatus?(.failed("Socket unavailable"))
        await settle()

        fixture.model.restartThroughNostromo()
        await settle()

        XCTAssertEqual(fixture.launcher.terminateCalls, 0)
        XCTAssertEqual(fixture.launcher.launchCalls, 0)
        XCTAssertTrue(fixture.launcher.isRunning())
        XCTAssertNotNil(fixture.model.lastError)
    }

    func testFailedBridgeRestartReopensCodexNormally() async {
        let fixture = makeFixture()
        await settle()
        fixture.launcher.failLaunch(with: .launchFailed)

        fixture.model.restartThroughNostromo()
        let reopened = await waitUntil { fixture.launcher.normalLaunchCalls == 1 }

        XCTAssertTrue(reopened)
        XCTAssertEqual(fixture.launcher.terminateCalls, 1)
        XCTAssertEqual(fixture.launcher.launchCalls, 1)
        XCTAssertTrue(fixture.launcher.isRunning())
        XCTAssertTrue(fixture.model.chatGPTNeedsRestart)
        XCTAssertNotNil(fixture.model.lastError)
    }

    func testShutdownDuringFailedRestartDoesNotReopenCodex() async {
        let fixture = makeFixture()
        await settle()
        fixture.launcher.failLaunch(with: .launchFailed, delay: .milliseconds(100))

        fixture.model.restartThroughNostromo()
        let launchStarted = await waitUntil { fixture.launcher.launchCalls == 1 }
        XCTAssertTrue(launchStarted)
        fixture.model.shutdown()
        try? await Task.sleep(for: .milliseconds(130))

        XCTAssertEqual(fixture.launcher.normalLaunchCalls, 0)
        XCTAssertFalse(fixture.launcher.isRunning())
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

    func testObsoleteRuntimeHUDPreferenceIsRemoved() throws {
        let suiteName = "io.nostromo-codex.tests.preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "ux.showRuntimeHUD")

        _ = AppPreferences(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "ux.showRuntimeHUD"))
        defaults.removePersistentDomain(forName: suiteName)
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

    func testBecomingActiveDoesNotRestartHIDOutsidePermissionFlow() {
        let fixture = makeFixture()

        fixture.model.refreshInputMonitoringAfterSettings()

        XCTAssertEqual(fixture.hid.startCalls, 0)
        XCTAssertTrue(fixture.hid.lightingSummaries.isEmpty)
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
}
