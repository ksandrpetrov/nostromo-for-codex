import Foundation
@testable import NostromoCodexApp
import NostromoCodexCore
import SwiftUI
import XCTest

@MainActor
class AppModelTestCase: XCTestCase {
    func advance(_ clock: ManualRuntimeClock, by interval: TimeInterval) async {
        await drainTasks()
        clock.advance(by: interval)
        await drainTasks()
    }

    func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }

    func waitUntil(
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

    func makeFixture(
        hidOnlyMode: Bool = false,
        shortcutAccess: Bool = true,
        clock: any RuntimeClock = SystemRuntimeClock()
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
            clock: clock,
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
        let manual = clock as? ManualRuntimeClock
        addTeardownBlock {
            await MainActor.run {
                model.shutdown()
                manual?.advance(by: 1_000_000)
            }
            try? FileManager.default.removeItem(at: root)
        }
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
struct AppFixture {
    let model: AppModel
    let bridge: FakeBridge
    let hid: FakeHID
    let launcher: FakeLauncher
    let shortcutPoster: FakeShortcutPoster
    let keyboardSuppressor: FakeKeyboardSuppressor
    let fallback: FakeFallbackController
}

func completeTestCapabilities() -> ChatGPTRuntimeCapabilities {
    ChatGPTRuntimeCapabilities(
        commandIDs: Set(CodexActionCatalog.verified.map(\.id)), commandRegistrySource: "test",
        requiredAPIs: ["browserWindow": true, "rendererMessaging": true, "rendererEvaluation": true, "scopedHidHook": true, "microServiceHook": true],
        unavailableFeatures: [], chatGPTVersion: "26.721.41059", chatGPTBuild: "5848", adapterID: "micro-v1"
    )
}

@MainActor
final class FakeFallbackController: CodexFallbackControlling {
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

final class FakeBridge: BridgeServing, @unchecked Sendable {
    let socketPath = "/tmp/fake.sock"
    let sessionDescriptorPath = "/tmp/fake-session.json"
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

final class FakeHID: HIDManaging, @unchecked Sendable {
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

final class FakeLauncher: ChatGPTLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var activateCountStorage = 0
    private var activeStorage = false
    private var launchCountStorage = 0
    private var terminateCountStorage = 0
    private var normalLaunchCountStorage = 0
    private var runningStorage = true
    private var launchFailure: LaunchError?
    private var launchDelay: Duration?
    private var compatibilityStorage = ChatGPTCompatibility(version: "26.721.41059", build: "5848", supported: true)

    func setCompatibility(_ value: ChatGPTCompatibility) { lock.withLock { compatibilityStorage = value } }
    func installationIdentifier() -> String { lock.withLock { compatibilityStorage.version + compatibilityStorage.build } }

    func failLaunch(with error: LaunchError, delay: Duration? = nil) {
        lock.withLock {
            launchFailure = error
            launchDelay = delay
        }
    }
    var normalLaunchCalls: Int { lock.withLock { normalLaunchCountStorage } }

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

    func isRunning() -> Bool { lock.withLock { runningStorage } }

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
        sessionDescriptorPath _: String,
        token _: String,
        forceUnsupported _: Bool
    ) async throws {
        let delay = lock.withLock {
            launchCountStorage += 1
            return launchDelay
        }
        if let delay { try await Task.sleep(for: delay) }
        try lock.withLock {
            if let launchFailure { throw launchFailure }
            runningStorage = true
        }
    }

    func launchNormally() async throws {
        lock.withLock {
            normalLaunchCountStorage += 1
            runningStorage = true
        }
    }

    func terminateRunningApplications() async {
        lock.withLock {
            terminateCountStorage += 1
            runningStorage = false
        }
    }
}

final class FakeShortcutPoster: ShortcutPosting, @unchecked Sendable {
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
final class FakeKeyboardSuppressor: NostromoKeyboardSuppressing {
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
