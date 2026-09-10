import Foundation
@testable import NostromoCodexApp
import NostromoCodexCore
import XCTest

@MainActor
final class LiveChatGPTE2ETests: XCTestCase {
    func testRealChatGPTPreloadHandshakeCapabilitiesAndSafeActionRoundTrip() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOSTROMO_LIVE_E2E"] == "1",
            "Live ChatGPT restart is opt-in."
        )

        let workspace = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let preload = workspace
            .appendingPathComponent("Sources/NostromoCodexApp/Resources/chatgpt-preload.cjs")
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nostromo-live-e2e-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "io.nostromo-codex.live-e2e.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = AppPreferences(defaults: defaults)
        preferences.markSetupCompleted(autoLaunch: false)

        let launcher = ChatGPTLauncher()
        let realBridge = try UnixSocketBridge()
        let bridge = ObservingBridge(underlying: realBridge)
        let hid = LiveFakeHID()
        let model = AppModel(
            store: ConfigurationStore(fileURL: testRoot.appendingPathComponent("profiles.json")),
            launcher: launcher,
            hid: hid,
            bridge: bridge,
            shortcutPoster: LiveNoopShortcutPoster(),
            keyboardSuppressor: LiveNoopKeyboardSuppressor(),
            preferences: preferences
        )

        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: testRoot)
        }

        let compatibility = launcher.compatibility()
        let manifest = try XCTUnwrap(CodexCompatibilityManifest.load())
        let adapter = try XCTUnwrap(manifest.entry(version: compatibility.version, build: compatibility.build))
        try XCTSkipUnless(compatibility.requiredModulesPresent, "Installed bundle does not match the adapter contract.")
        // The explicit live opt-in may validate a prepared candidate, but it
        // never changes the production allowlist or the user's configuration.
        model.setForceUnsupported(!adapter.verified)

        await launcher.terminateRunningApplications()
        try XCTSkipIf(
            launcher.isRunning(),
            "ChatGPT did not terminate gracefully; refusing to create a competing instance."
        )

        model.start()
        let bridgeStarted = await waitUntil { model.bridgeStatus == .listening }
        XCTAssertTrue(bridgeStarted)

        try await launcher.launch(
            preloadURL: preload,
            socketPath: bridge.socketPath,
            sessionDescriptorPath: bridge.sessionDescriptorPath,
            token: bridge.token,
            forceUnsupported: !adapter.verified
        )

        let runtimeReady = await waitUntil(timeout: 20) {
            model.fullBridgeReady
        }
        XCTAssertTrue(
            runtimeReady,
            "Real ChatGPT preload did not authenticate and publish capabilities."
        )

        let capabilities = try XCTUnwrap(model.runtimeCapabilities)
        XCTAssertEqual(capabilities.commandRegistrySource, "runtime-app-asar")
        XCTAssertTrue(capabilities.requiredAPIs.values.allSatisfy { $0 })
        XCTAssertTrue(capabilities.commandIDs.contains("toggleSidebar"))
        XCTAssertEqual(
            Set(capabilities.unavailableFeatures),
            [
                "Окно разрешений не зарегистрировано в проверенной сборке ChatGPT.",
                "Команда Compact не зарегистрирована как команда приложения в проверенной сборке ChatGPT.",
                "Команда Status не зарегистрирована как команда приложения в проверенной сборке ChatGPT.",
            ]
        )

        let appServerSkills = try CodexSkillCatalog(
            workspace: workspace,
            responseTimeout: 5
        ).load()
        XCTAssertFalse(appServerSkills.isEmpty)
        XCTAssertEqual(Set(appServerSkills.map(\.id)).count, appServerSkills.count)
        let modelSkillsLoaded = await waitUntil {
            !model.skills.isEmpty
        }
        XCTAssertTrue(modelSkillsLoaded)
        XCTAssertEqual(Set(model.skills.map(\.id)), Set(appServerSkills.map(\.id)))

        hid.emit(
            state: .connected(interfaceCount: 2, captureMode: .shared)
        )
        func trigger(_ action: BindingAction, on control: ControlID = .key02) {
            model.setBinding(action, for: control)
            hid.emitButton(control, pressed: true, calibration: model.configuration.calibration)
            hid.emitButton(control, pressed: false, calibration: model.configuration.calibration)
        }

        let initialDeviceReportCount = bridge.deviceReportCount
        trigger(.taskSlot(0))
        let taskNavigationReported = await waitUntil {
            bridge.deviceReportCount >= initialDeviceReportCount + 2
        }
        XCTAssertTrue(taskNavigationReported)

        model.setBinding(.codexAction("toggleSidebar"), for: .key01)
        let initialToggleCount = bridge.successCount(
            action: "run-command",
            payloadKey: "commandId",
            payloadValue: "toggleSidebar"
        )

        hid.emitButton(.key01, pressed: true, calibration: model.configuration.calibration)
        hid.emitButton(.key01, pressed: false, calibration: model.configuration.calibration)
        let firstToggleCompleted = await waitUntil {
            bridge.successCount(
                action: "run-command",
                payloadKey: "commandId",
                payloadValue: "toggleSidebar"
            ) == initialToggleCount + 1
        }
        XCTAssertTrue(firstToggleCompleted)

        hid.emitButton(.key01, pressed: true, calibration: model.configuration.calibration)
        hid.emitButton(.key01, pressed: false, calibration: model.configuration.calibration)
        let secondToggleCompleted = await waitUntil {
            bridge.successCount(
                action: "run-command",
                payloadKey: "commandId",
                payloadValue: "toggleSidebar"
            ) == initialToggleCount + 2
        }
        XCTAssertTrue(secondToggleCompleted)

        for commandID in [
            "nextThread",
            "previousThread",
            "composer.togglePlanMode",
            "composer.togglePlanMode",
            "composer.toggleFastMode",
            "composer.toggleFastMode",
        ] {
            let initialCount = bridge.successCount(
                action: "run-command",
                payloadKey: "commandId",
                payloadValue: commandID
            )
            trigger(.codexAction(commandID))
            let commandCompleted = await waitUntil {
                bridge.successCount(
                    action: "run-command",
                    payloadKey: "commandId",
                    payloadValue: commandID
                ) == initialCount + 1
            }
            XCTAssertTrue(commandCompleted, "Command did not complete: \(commandID)")
        }

        let enabledSkill = try XCTUnwrap(model.skills.first(where: \.enabled))
        let initialSkillCount = bridge.successCount(
            action: "insert-skill-mention",
            payloadKey: "path",
            payloadValue: enabledSkill.path
        )
        trigger(.skill(enabledSkill))
        let skillMentionCompleted = await waitUntil {
            bridge.successCount(
                action: "insert-skill-mention",
                payloadKey: "path",
                payloadValue: enabledSkill.path
            ) == initialSkillCount + 1
        }
        XCTAssertTrue(skillMentionCompleted)

        let plugin = PluginPrompt(
            uri: "plugin://nostromo-release-test",
            displayName: "Nostromo Release Test",
            template: "Черновик без отправки"
        )
        let initialPluginCount = bridge.successCount(
            action: "prepare-plugin-prompt",
            payloadKey: "text",
            payloadValue: plugin.composerText
        )
        trigger(.pluginPrompt(plugin))
        let pluginPromptCompleted = await waitUntil {
            bridge.successCount(
                action: "prepare-plugin-prompt",
                payloadKey: "text",
                payloadValue: plugin.composerText
            ) == initialPluginCount + 1
        }
        XCTAssertTrue(pluginPromptCompleted)

        model.setBinding(.codexAction("pushToTalk"), for: .key02)
        let initialPushToTalkStartCount = bridge.successCount(action: "push-to-talk-start")
        hid.emitButton(.key02, pressed: true, calibration: model.configuration.calibration)
        let pushToTalkStarted = await waitUntil {
            bridge.successCount(action: "push-to-talk-start") == initialPushToTalkStartCount + 1
        }
        XCTAssertTrue(pushToTalkStarted)
        let initialPushToTalkStopCount = bridge.successCount(action: "push-to-talk-stop")
        hid.emitButton(.key02, pressed: false, calibration: model.configuration.calibration)
        let pushToTalkStopped = await waitUntil {
            bridge.successCount(action: "push-to-talk-stop") == initialPushToTalkStopCount + 1
        }
        XCTAssertTrue(pushToTalkStopped)

        let initialStopCount = bridge.successCount(action: "stop-active")
        trigger(.codexAction("composer.stop"))
        let stopCompleted = await waitUntil {
            bridge.successCount(action: "stop-active") == initialStopCount + 1
        }
        XCTAssertTrue(stopCompleted)

        for delta in [52, -52] {
            let scroll = LiveResultBox()
            bridge.dispatch(.scrollTask(deltaY: delta)) {
                scroll.set($0)
            }
            let scrollCompleted = await waitUntil { scroll.isSuccess }
            XCTAssertTrue(scrollCompleted)
        }

        let rejectedUnknownCommand = LiveResultBox()
        bridge.dispatch(
            .runCommand(id: "nostromo.release-test.unknown")
        ) {
            rejectedUnknownCommand.set($0)
        }
        let unknownCommandRejected = await waitUntil { rejectedUnknownCommand.isFailure }
        XCTAssertTrue(unknownCommandRejected)

        model.shutdown()
        await launcher.terminateRunningApplications()
        XCTAssertFalse(launcher.isRunning())
    }

    private func waitUntil(
        timeout: TimeInterval = 8,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}

private final class ObservingBridge: BridgeServing, @unchecked Sendable {
    private struct Completion {
        let action: BridgeAppAction
        let succeeded: Bool
    }

    private let underlying: UnixSocketBridge
    private let lock = NSLock()
    private var completions: [Completion] = []
    private var sentDeviceReportCount = 0

    init(underlying: UnixSocketBridge) {
        self.underlying = underlying
    }

    var socketPath: String { underlying.socketPath }
    var sessionDescriptorPath: String { underlying.sessionDescriptorPath }
    var token: String { underlying.token }
    var isAuthenticated: Bool { underlying.isAuthenticated }

    var onStatus: UnixSocketBridge.StatusHandler? {
        get { underlying.onStatus }
        set { underlying.onStatus = newValue }
    }

    var onHostReport: UnixSocketBridge.HostReportHandler? {
        get { underlying.onHostReport }
        set { underlying.onHostReport = newValue }
    }

    var onCapabilities: UnixSocketBridge.CapabilitiesHandler? {
        get { underlying.onCapabilities }
        set { underlying.onCapabilities = newValue }
    }

    var onRuntimeState: UnixSocketBridge.RuntimeStateHandler? {
        get { underlying.onRuntimeState }
        set { underlying.onRuntimeState = newValue }
    }

    var onTaskSlots: UnixSocketBridge.TaskSlotsHandler? {
        get { underlying.onTaskSlots }
        set { underlying.onTaskSlots = newValue }
    }

    func start() {
        underlying.start()
    }

    func stop() {
        underlying.stop()
    }

    var deviceReportCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sentDeviceReportCount
    }

    func sendDeviceReport(_ report: Data) {
        lock.lock()
        sentDeviceReportCount += 1
        lock.unlock()
        underlying.sendDeviceReport(report)
    }

    func dispatch(
        _ action: BridgeAppAction,
        completion: (@Sendable (Result<Void, Error>) -> Void)?
    ) {
        underlying.dispatch(action) { [weak self] result in
            guard let self else {
                completion?(result)
                return
            }
            self.lock.lock()
            self.completions.append(
                Completion(
                    action: action,
                    succeeded: {
                        if case .success = result { return true }
                        return false
                    }()
                )
            )
            self.lock.unlock()
            completion?(result)
        }
    }

    func successCount(
        action: String,
        payloadKey: String,
        payloadValue: String
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return completions.count {
            $0.succeeded
                && $0.action.name == action
                && $0.action.payload[payloadKey] == payloadValue
        }
    }

    func successCount(action: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return completions.count {
            $0.succeeded && $0.action.name == action
        }
    }
}

private final class LiveFakeHID: HIDManaging, @unchecked Sendable {
    var onEvent: (@Sendable (NostromoHIDEvent) -> Void)?
    var onState: (@Sendable (NostromoDeviceState) -> Void)?
    var onDiagnostic: (@Sendable (String) -> Void)?

    func start(seize _: Bool) {
        emit(state: .disconnected)
    }

    func stop() {}
    func requestInputMonitoring() {}
    func applyLighting(_: NostromoLightingSummary) {}
    func pulseBacklight(strength _: Double) {}

    func emit(state: NostromoDeviceState) {
        onState?(state)
    }

    func emitButton(
        _ control: ControlID,
        pressed: Bool,
        calibration: CalibrationMap
    ) {
        guard let signature = calibration.signatures[control] else { return }
        onEvent?(
            NostromoHIDEvent(
                signature: signature,
                value: pressed ? 1 : 0,
                timestamp: ProcessInfo.processInfo.systemUptime,
                eligibleForAction: true
            )
        )
    }
}

private final class LiveNoopShortcutPoster: ShortcutPosting, @unchecked Sendable {
    func hasPostEventAccess() -> Bool { true }
    func requestPostEventAccess() -> Bool { true }
    func post(_: ShortcutBinding, keyDown _: Bool) -> Bool { true }
}

@MainActor
private final class LiveNoopKeyboardSuppressor:
    NostromoKeyboardSuppressing
{
    func recover() -> NostromoKeyboardRestorationResult {
        .nothingPending
    }

    func suppress(usages: Set<UInt32>) -> NostromoInputProtectionStatus {
        usages.isEmpty
            ? .inactive
            : .active(serviceCount: 1, usageCount: usages.count)
    }

    func restore() -> NostromoKeyboardRestorationResult {
        .nothingPending
    }
}

private final class LiveResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?

    var isSuccess: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .success = result { return true }
        return false
    }

    var isFailure: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .failure = result { return true }
        return false
    }

    func set(_ result: Result<Void, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }
}
