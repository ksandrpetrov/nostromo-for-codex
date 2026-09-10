import Foundation
import NostromoCodexCore
import AppKit
@preconcurrency import IOKit.hid

protocol InputMonitoringPermissionControlling: Sendable {
    func checkAccess() -> IOHIDAccessType
    func requestAccess() -> Bool
    func openSettings()
}

struct MacOSInputMonitoringPermissionController:
    InputMonitoringPermissionControlling
{
    private static let inputMonitoringSettingsURL = URL(
        string:
            "x-apple.systempreferences:"
                + "com.apple.settings.PrivacySecurity.extension"
                + "?Privacy_ListenEvent"
    )!
    private static let privacySettingsURL = URL(
        string:
            "x-apple.systempreferences:"
                + "com.apple.settings.PrivacySecurity.extension"
    )!

    func checkAccess() -> IOHIDAccessType {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    }

    func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func openSettings() {
        DispatchQueue.main.async {
            if !NSWorkspace.shared.open(Self.inputMonitoringSettingsURL) {
                _ = NSWorkspace.shared.open(Self.privacySettingsURL)
            }
        }
    }
}

protocol BridgeServing: AnyObject, Sendable {
    var socketPath: String { get }
    var token: String { get }
    var isAuthenticated: Bool { get }
    var onStatus: UnixSocketBridge.StatusHandler? { get set }
    var onHostReport: UnixSocketBridge.HostReportHandler? { get set }
    var onCapabilities: UnixSocketBridge.CapabilitiesHandler? { get set }
    var onRuntimeState: UnixSocketBridge.RuntimeStateHandler? { get set }
    var onTaskSlots: UnixSocketBridge.TaskSlotsHandler? { get set }

    func start()
    func stop()
    func sendDeviceReport(_ report: Data)
    func dispatch(
        _ action: BridgeAppAction,
        completion: (@Sendable (Result<Void, Error>) -> Void)?
    )
}

protocol HIDManaging: AnyObject, Sendable {
    var onEvent: (@Sendable (NostromoHIDEvent) -> Void)? { get set }
    var onState: (@Sendable (NostromoDeviceState) -> Void)? { get set }
    var onDiagnostic: (@Sendable (String) -> Void)? { get set }

    func start(seize: Bool)
    func stop()
    func requestInputMonitoring()
    func applyLighting(_ summary: NostromoLightingSummary)
    func pulseBacklight(strength: Double)
}

enum HIDCaptureMode: String, Codable, Equatable, Sendable {
    case exclusive
    case shared
}

enum NostromoKeyboardFailureStage: String, Codable, Equatable, Sendable {
    case recoveryStore
    case snapshot
    case persistence
    case apply
    case verification
    case rollback
    case recovery
}

struct NostromoKeyboardServiceFailure: Codable, Equatable, Sendable {
    let registryID: UInt64?
    let stage: NostromoKeyboardFailureStage
    let setterReturned: Bool?
    let readBackMatched: Bool?
    let detail: String

    var serviceLabel: String {
        guard let registryID else { return "recovery store" }
        return String(
            format: "0x%llX (%llu)",
            registryID,
            registryID
        )
    }

    var diagnosticDescription: String {
        var parts = [
            "\(stage.rawValue): \(serviceLabel)",
            detail,
        ]
        if let setterReturned {
            parts.append("setter=\(setterReturned)")
        }
        if let readBackMatched {
            parts.append("readBack=\(readBackMatched)")
        }
        return parts.joined(separator: " · ")
    }
}

struct NostromoKeyboardSuppressionFailure: Equatable, Sendable {
    let failures: [NostromoKeyboardServiceFailure]
    let recoveryPending: Bool

    var summary: String {
        let details = failures
            .map(\.diagnosticDescription)
            .joined(separator: "; ")
        if recoveryPending {
            if details.isEmpty {
                return "Восстановление UserKeyMapping осталось незавершённым."
            }
            return details + " · восстановление осталось незавершённым"
        }
        return details.isEmpty
            ? "macOS не подтвердила защиту клавиатурного ввода."
            : details
    }
}

struct NostromoKeyboardRestorationResult: Equatable, Sendable {
    let restoredServiceCount: Int
    let pendingServiceCount: Int
    let failures: [NostromoKeyboardServiceFailure]

    static let nothingPending = NostromoKeyboardRestorationResult(
        restoredServiceCount: 0,
        pendingServiceCount: 0,
        failures: []
    )

    var isComplete: Bool {
        pendingServiceCount == 0 && failures.isEmpty
    }
}

enum NostromoInputProtectionStatus: Equatable, Sendable {
    case inactive
    case pending
    case exclusiveCapture
    case active(serviceCount: Int, usageCount: Int)
    case deviceUnavailable
    case failed(NostromoKeyboardSuppressionFailure)

    var allowsActionDispatch: Bool {
        switch self {
        case .exclusiveCapture, .active:
            true
        case .inactive, .pending, .deviceUnavailable, .failed:
            false
        }
    }
}

@MainActor
protocol NostromoKeyboardSuppressing: AnyObject {
    func recover() -> NostromoKeyboardRestorationResult
    func suppress(usages: Set<UInt32>) -> NostromoInputProtectionStatus
    func restore() -> NostromoKeyboardRestorationResult
}

protocol ChatGPTLaunching: AnyObject, Sendable {
    func compatibility() -> ChatGPTCompatibility
    func installationIdentifier() -> String
    func launchNormally() async throws
    func isRunning() -> Bool
    func isActive() -> Bool
    @discardableResult
    func activate() -> Bool
    func launch(
        preloadURL: URL,
        socketPath: String,
        token: String,
        forceUnsupported: Bool
    ) async throws
    func terminateRunningApplications() async
}

extension ChatGPTLaunching {
    func installationIdentifier() -> String { "injected-launcher" }
    func launchNormally() async throws { throw LaunchError.launchFailed }
}

protocol ShortcutPosting: Sendable {
    func hasPostEventAccess() -> Bool
    func requestPostEventAccess() -> Bool
    func post(_ shortcut: ShortcutBinding, keyDown: Bool) -> Bool
}

@MainActor
protocol RuntimeHUDPresenting: AnyObject {
    func present(_ feedback: RuntimeFeedback)
    func dismiss()
}

@MainActor
final class NoopRuntimeHUDPresenter: RuntimeHUDPresenting {
    func present(_: RuntimeFeedback) {}
    func dismiss() {}
}

struct MacOSShortcutPoster: ShortcutPosting {
    func hasPostEventAccess() -> Bool {
        CGPreflightPostEventAccess()
    }

    func requestPostEventAccess() -> Bool {
        CGRequestPostEventAccess()
    }

    func post(_ shortcut: ShortcutBinding, keyDown: Bool) -> Bool {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(shortcut.keyCode),
            keyDown: keyDown
        ) else {
            return false
        }
        var flags: CGEventFlags = []
        if shortcut.command { flags.insert(.maskCommand) }
        if shortcut.option { flags.insert(.maskAlternate) }
        if shortcut.control { flags.insert(.maskControl) }
        if shortcut.shift { flags.insert(.maskShift) }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        return true
    }
}

extension BridgeServing {
    func dispatch(_ action: BridgeAppAction) {
        dispatch(action, completion: nil)
    }
}

private struct UnavailableBridgeError: LocalizedError {
    let reason: String

    var errorDescription: String? {
        "Приватное подключение к Codex недоступно: \(reason)"
    }
}

/// Immutable failure metadata is Sendable; `handlerLock` owns the replaceable
/// callbacks required by the common bridge service interface.
final class UnavailableBridge: BridgeServing, @unchecked Sendable {
    let socketPath = ""
    let token = ""
    let isAuthenticated = false

    private let reason: String
    private let handlerLock = NSLock()
    private var statusHandler: UnixSocketBridge.StatusHandler?
    private var hostReportHandler: UnixSocketBridge.HostReportHandler?
    private var capabilitiesHandler: UnixSocketBridge.CapabilitiesHandler?
    private var runtimeStateHandler: UnixSocketBridge.RuntimeStateHandler?
    private var taskSlotsHandler: UnixSocketBridge.TaskSlotsHandler?

    init(reason: String) {
        self.reason = reason
    }

    var onStatus: UnixSocketBridge.StatusHandler? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return statusHandler
        }
        set {
            handlerLock.lock()
            statusHandler = newValue
            handlerLock.unlock()
        }
    }

    var onHostReport: UnixSocketBridge.HostReportHandler? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return hostReportHandler
        }
        set {
            handlerLock.lock()
            hostReportHandler = newValue
            handlerLock.unlock()
        }
    }

    var onCapabilities: UnixSocketBridge.CapabilitiesHandler? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return capabilitiesHandler
        }
        set {
            handlerLock.lock()
            capabilitiesHandler = newValue
            handlerLock.unlock()
        }
    }

    var onRuntimeState: UnixSocketBridge.RuntimeStateHandler? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return runtimeStateHandler
        }
        set {
            handlerLock.lock()
            runtimeStateHandler = newValue
            handlerLock.unlock()
        }
    }

    var onTaskSlots: UnixSocketBridge.TaskSlotsHandler? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return taskSlotsHandler
        }
        set {
            handlerLock.lock()
            taskSlotsHandler = newValue
            handlerLock.unlock()
        }
    }

    func start() {
        onStatus?(.failed("Не удалось запустить приватное подключение к Codex: \(reason)"))
    }

    func stop() {}
    func sendDeviceReport(_: Data) {}

    func dispatch(
        _: BridgeAppAction,
        completion: (@Sendable (Result<Void, Error>) -> Void)?
    ) {
        completion?(.failure(UnavailableBridgeError(reason: reason)))
    }
}

extension UnixSocketBridge: BridgeServing {}
extension NostromoHIDManager: HIDManaging {}
extension ChatGPTLauncher: ChatGPTLaunching {}
