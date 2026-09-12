import AppKit
import Combine
import Foundation
import IOKit.hid
import NostromoCodexCore
import Security

struct HIDDiagnosticEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let sequence: Int
    let recordedAt: Date
    let uptime: TimeInterval
    let receivedAtUptime: TimeInterval
    let callbackLatencyMilliseconds: Double
    let usagePage: UInt32
    let usage: UInt32
    let cookie: UInt64
    let kind: HIDEventKind
    let value: Int
    let eligibleForAction: Bool

    init(
        sequence: Int,
        event: NostromoHIDEvent,
        receivedAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        id = UUID()
        self.sequence = sequence
        recordedAt = Date()
        uptime = event.timestamp
        self.receivedAtUptime = receivedAtUptime
        callbackLatencyMilliseconds = max(0, receivedAtUptime - event.timestamp) * 1_000
        usagePage = event.signature.usagePage
        usage = event.signature.usage
        cookie = event.signature.cookie
        kind = event.signature.kind
        value = event.value
        eligibleForAction = event.eligibleForAction
    }

    var summary: String {
        String(
            format: "#%04d · %04X:%04X · %@ · %d · %.2f мс",
            sequence,
            usagePage,
            usage,
            kind.rawValue,
            value,
            callbackLatencyMilliseconds
        )
    }
}

struct HIDPipelineDiagnostics: Codable, Equatable, Sendable {
    var rawEventCount = 0
    var eligibleEventCount = 0
    var mappedControlCount = 0
    var blockedActionCount = 0
    var bindingExecutionCount = 0
    var bridgeDispatchAttemptCount = 0
    var bridgeDispatchSuccessCount = 0
    var bridgeDispatchFailureCount = 0
    var lastMappedControl: String?
    var lastBinding: String?
    var lastBridgeAction: String?
    var lastDispatchOutcome: String?
}

struct ApplicationIdentityDiagnostics: Codable, Equatable, Sendable {
    let bundleIdentifier: String?
    let runningBundlePath: String
    let registeredBundlePath: String?
    let codeIdentifier: String?
    let teamIdentifier: String?
    let cdHash: String?
    let signatureValidationStatus: Int32?
}

private struct HIDDiagnosticExport: Codable {
    let formatVersion: Int
    let generatedAt: Date
    let vendorID: Int
    let productID: Int
    let hidOnlyMode: Bool
    let applicationVersion: String
    let applicationBuild: String
    let applicationBundlePath: String
    let executablePath: String?
    let operatingSystem: String
    let architecture: String
    let applicationIdentity: ApplicationIdentityDiagnostics
    let chatGPTVersion: String
    let chatGPTBuild: String
    let deviceState: String
    let inputProtection: String
    let bridgeStatus: String
    let pipeline: HIDPipelineDiagnostics
    let diagnosticMessages: [String]
    let events: [HIDDiagnosticEntry]
}

@MainActor
final class AppModel: ObservableObject {
    // MARK: Published UI state

    @Published var configuration: AppConfiguration
    @Published var selectedControl: ControlID = .key01
    @Published var deviceState: NostromoDeviceState = .stopped
    @Published var bridgeStatus: BridgeStatus = .stopped
    @Published var skills: [SkillReference] = []
    @Published private(set) var runtimeCapabilities: ChatGPTRuntimeCapabilities?
    @Published private(set) var reasoningEffort: String?
    @Published private(set) var taskSlots: [CodexTaskSlot] = []
    @Published private(set) var hidDiagnosticMessages: [String] = []
    @Published var lighting = CodexLightingState()
    @Published var lastHIDEvent = "Событий пока нет"
    @Published var lastError: String?
    @Published var hudMessage: String?
    @Published var runtimeFeedback: RuntimeFeedback?
    @Published private var calibration = CalibrationSession()
    var calibrationTarget: ControlID? { calibration.target }
    @Published var chatGPTNeedsRestart = false
    @Published var compatibility: ChatGPTCompatibility
    @Published var shortcutPermissionGranted: Bool
    @Published var dashboardSection: DashboardSection = .mappings
    @Published var setupPhase: SetupPhase = .welcome
    @Published var selectedStarterKeymap: StarterKeymap = .codexEssentials
    @Published var inputTestMode = false
    @Published var pendingImportedConfiguration: AppConfiguration?
    @Published var pendingImportName: String?
    @Published private(set) var activeControls: Set<ControlID> = []
    @Published private(set) var wheelMode: WheelMode = .scroll
    @Published private(set) var voiceFeedbackActive = false
    @Published private(set) var hidDiagnosticEvents: [HIDDiagnosticEntry] = []
    @Published private(set) var hidPipelineDiagnostics =
        HIDPipelineDiagnostics()
    @Published private(set) var inputProtectionStatus:
        NostromoInputProtectionStatus = .inactive

    // MARK: Service dependencies

    let preferences: AppPreferences
    let store: ConfigurationStore
    let launcher: any ChatGPTLaunching
    let hid: any HIDManaging
    let bridge: any BridgeServing
    let shortcutPoster: any ShortcutPosting
    let keyboardSuppressor: any NostromoKeyboardSuppressing
    let engine: Project2077Engine
    let hidOnlyMode: Bool
    private let fallbackController: any CodexFallbackControlling

    // MARK: Runtime coordination state

    private let gestures: InputGestureCoordinator
    private let scheduler: RuntimeScheduler
    private var pushToTalk = PushToTalkGestureMachine()
    private var pushToTalkActive = false
    private var activeDPadControl: ControlID?
    private var keyboardSuppressionTask: Task<Void, Never>?
    private var connectionMonitorTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var fallbackGeneration = 0
    private var installationIdentifier: String?
    private var profileRuntime: ProfileRuntimeState
    private var pressedActions: [ControlID: BindingAction] = [:]
    private var connectionHeldControls: Set<ControlID> = []
    private var started = false
    private var attemptedAutoLaunch = false
    private var launchInProgress = false
    private var shuttingDown = false
    private var nextHIDDiagnosticSequence = 1
    private var configurationLoadError: Error?
    private var invalidConfigurationBackupURL: URL?
    private var preferencesCancellable: AnyCancellable?

    // MARK: Initialization

    init(
        store: ConfigurationStore = ConfigurationStore(),
        launcher: any ChatGPTLaunching = ChatGPTLauncher(),
        hid: any HIDManaging = NostromoHIDManager(),
        bridge injectedBridge: (any BridgeServing)? = nil,
        shortcutPoster: any ShortcutPosting = MacOSShortcutPoster(),
        keyboardSuppressor: any NostromoKeyboardSuppressing =
            NostromoKeyboardSuppressor(),
        preferences: AppPreferences = .ephemeral(),
        fallbackController: any CodexFallbackControlling = CodexFallbackController(),
        clock: any RuntimeClock = SystemRuntimeClock(),
        hidOnlyMode: Bool = ProcessInfo.processInfo.environment["NOSTROMO_CODEX_HID_ONLY"] == "1"
    ) {
        let scheduler = RuntimeScheduler(clock: clock)
        self.scheduler = scheduler
        gestures = InputGestureCoordinator(scheduler: scheduler)
        self.preferences = preferences
        self.store = store
        self.launcher = launcher
        self.hid = hid
        self.shortcutPoster = shortcutPoster
        self.keyboardSuppressor = keyboardSuppressor
        self.fallbackController = fallbackController
        self.hidOnlyMode = hidOnlyMode
        let loadedConfiguration: AppConfiguration
        do {
            loadedConfiguration = try store.load()
        } catch {
            loadedConfiguration = .defaults()
            configurationLoadError = error
        }
        configuration = loadedConfiguration
        profileRuntime = ProfileRuntimeState(
            persistentProfileID: loadedConfiguration.activeProfileID
        )
        compatibility = launcher.compatibility()
        shortcutPermissionGranted = shortcutPoster.hasPostEventAccess()

        if let injectedBridge {
            bridge = injectedBridge
        } else {
            do {
                bridge = try UnixSocketBridge()
            } catch {
                bridge = UnavailableBridge(reason: error.localizedDescription)
            }
        }

        let localBridge = bridge
        engine = Project2077Engine(
            sendReport: { report in localBridge.sendDeviceReport(report) },
            onLighting: { _ in }
        )

        gestures.onDirection = { [weak self] direction, time in
            self?.applyDPadDirection(direction, at: time)
        }
        gestures.onDirectionReleased = { [weak self] time in
            guard let self, let active = self.activeDPadControl else { return }
            self.execute(control: active, pressed: false, at: time)
            self.activeDPadControl = nil
        }
        gestures.onWheelOutputs = { [weak self] outputs in
            self?.handleWheelOutputs(outputs)
        }

        let localEngine = engine
        bridge.onStatus = { [weak self] status in
            if status == .connected {
                // Project2077 is a byte stream. A partial frame belongs to
                // exactly one authenticated socket and must never leak into
                // the next client generation.
                localEngine.resetTransport()
            }
            Task { @MainActor in self?.handleBridgeStatus(status) }
        }
        bridge.onHostReport = { [weak self] report in
            guard let self else { return }
            do {
                try self.engine.receiveHostReport(report)
                let state = self.engine.currentLighting()
                Task { @MainActor in
                    guard !self.shuttingDown else { return }
                    self.lighting = state
                    self.hid.applyLighting(self.effectiveLightingSummary())
                }
            } catch {
                Task { @MainActor in
                    guard !self.shuttingDown else { return }
                    self.report(error)
                }
            }
        }
        bridge.onCapabilities = { [weak self] capabilities in
            Task { @MainActor in
                guard let self, !self.shuttingDown else { return }
                let wasReady = self.fullBridgeReady
                self.runtimeCapabilities = capabilities
                if wasReady != self.fullBridgeReady { self.resetInputForConnectionChange() }
                if !self.fullBridgeReady {
                    self.taskSlots = []
                    self.reasoningEffort = nil
                }
                self.chatGPTNeedsRestart = !self.fullBridgeReady && self.launcher.isRunning()
                self.hid.applyLighting(self.effectiveLightingSummary())
            }
        }
        bridge.onRuntimeState = { [weak self] state in
            Task { @MainActor in
                guard self?.shuttingDown == false, self?.fullBridgeReady == true else { return }
                self?.reasoningEffort = state.reasoningEffort
            }
        }
        bridge.onTaskSlots = { [weak self] slots in
            Task { @MainActor in
                guard let self, !self.shuttingDown else { return }
                guard self.fullBridgeReady else { return }
                let previousStatuses = Dictionary(
                    uniqueKeysWithValues: self.taskSlots.map { ($0.id, $0.status) }
                )
                let hasNewCompletion = slots.contains { slot in
                    slot.status == .unread
                        && previousStatuses[slot.id] != nil
                        && previousStatuses[slot.id] != .unread
                }
                self.taskSlots = slots
                self.hid.applyLighting(self.effectiveLightingSummary())
                if hasNewCompletion {
                    self.flashTaskCompletion()
                }
            }
        }
        hid.onState = { [weak self] state in
            Task { @MainActor in self?.handleDeviceState(state) }
        }
        hid.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleHIDEvent(event) }
        }
        hid.onDiagnostic = { [weak self] message in
            Task { @MainActor in
                guard let self, !self.shuttingDown else { return }
                self.hidDiagnosticMessages.append(message)
                if self.hidDiagnosticMessages.count > 200 {
                    self.hidDiagnosticMessages.removeFirst(25)
                }
            }
        }
        if let configurationLoadError {
            lastError = "Файл profiles.json повреждён или несовместим: \(configurationLoadError.localizedDescription) Перед первой записью исходный файл будет сохранён в резервную копию."
        }

        if store.hasStoredConfiguration,
           preferences.shouldAdoptStoredConfiguration,
           !preferences.setupCompleted
        {
            preferences.markSetupCompleted(autoLaunch: true)
        }
        preferencesCancellable = preferences.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        if loadedConfiguration.profiles.first?.bindings.values.allSatisfy({ $0 == .none }) == true {
            selectedStarterKeymap = .blank
        }
    }

    deinit {
        keyboardSuppressionTask?.cancel()
        connectionMonitorTask?.cancel()
        fallbackTask?.cancel()
        // App lifecycle calls `shutdown()` while the MainActor owner is still
        // valid; actor-isolated recovery cannot safely run from `deinit`.
        hid.stop()
        bridge.stop()
    }

    // MARK: Derived presentation state

    var activeProfile: ControllerProfile {
        configuration.profiles.first(where: { $0.id == configuration.activeProfileID })
            ?? configuration.profiles[0]
    }

    var lightingResolution: NostromoLightingResolution {
        return NostromoLightingResolution.resolve(
            from: lighting,
            indicatorState: codexIndicatorState,
            settings: configuration.lighting
        )
    }

    private var codexIndicatorState: NostromoCodexIndicatorState {
        guard fullBridgeReady else { return .unavailable }

        if taskSlots.contains(where: {
            switch $0.status {
            case .awaitingApproval, .error:
                true
            case .off, .working, .unread, .idle, .awaitingResponse:
                false
            }
        }) {
            return .needsAttention
        }
        if taskSlots.contains(where: { $0.status == .working }) {
            return .running
        }
        return .ready
    }

    var actionCatalog: [CodexActionDescriptor] {
        guard fullBridgeReady else { return CodexActionCatalog.fallbackCatalog }
        return CodexActionCatalog.runtimeCatalog(
            commandIDs: runtimeCapabilities?.commandIDs
        )
    }

    var fullBridgeReady: Bool {
        bridgeStatus == .connected && bridge.isAuthenticated
            && compatibility.requiredModulesPresent
            && (compatibility.supported || configuration.forceUnsupportedChatGPT)
            && runtimeCapabilities?.matches(compatibility) == true
    }

    var fallbackNeedsPermission: Bool { !fallbackController.hasAccess }

    var selectedBinding: BindingAction {
        activeProfile.bindings[selectedControl] ?? .none
    }

    var hidCallbackLatencyP95Milliseconds: Double? {
        guard !hidDiagnosticEvents.isEmpty else { return nil }
        let sorted = hidDiagnosticEvents
            .map(\.callbackLatencyMilliseconds)
            .sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        )
        return sorted[index]
    }

    var controllerEnabled: Bool {
        if case .stopped = deviceState { return false }
        return true
    }

    var inputProtectionAllowsActions: Bool {
        inputProtectionStatus.allowsActionDispatch
    }

    var applicationIdentityWarning: String? {
        let identity = applicationIdentityDiagnostics
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return nil
        }
        if let registered = identity.registeredBundlePath,
           URL(fileURLWithPath: registered).standardizedFileURL
            != Bundle.main.bundleURL.standardizedFileURL
        {
            return "Запущена копия \(identity.runningBundlePath), "
                + "но macOS зарегистрировала \(registered). Разрешения "
                + "Input Monitoring могут относиться к другой копии."
        }
        let expected = URL(
            fileURLWithPath: "/Applications/Nostromo Codex.app",
            isDirectory: true
        ).standardizedFileURL
        if Bundle.main.bundleURL.standardizedFileURL != expected {
            return "Приложение запущено из \(identity.runningBundlePath). "
                + "Для стабильных privacy-разрешений установите его в "
                + "/Applications/Nostromo Codex.app."
        }
        return nil
    }

    var applicationIdentity: ApplicationIdentityDiagnostics {
        applicationIdentityDiagnostics
    }

    var readiness: ReadinessState {
        guard preferences.setupCompleted || hidOnlyMode else { return .setupRequired }
        switch deviceState {
        case .stopped:
            return .controllerOff
        case .waitingForPermission:
            return .permissionRequired
        case .disconnected:
            return .deviceDisconnected
        case .error:
            return .bridgeUnavailable
        case .connected:
            break
        }
        guard compatibility.appInstalled else { return .unsupportedChatGPT }
        return fullBridgeReady ? .ready : .fallback
    }

    // MARK: Application and connection lifecycle

    func refreshChatGPTConnection() {
        guard !shuttingDown else { return }
        let identity = launcher.installationIdentifier()
        if identity != installationIdentifier {
            let changed = installationIdentifier != nil
            installationIdentifier = identity
            if changed {
                resetInputForConnectionChange()
                runtimeCapabilities = nil
                taskSlots = []
                reasoningEffort = nil
            }
            compatibility = launcher.compatibility()
            // An updater can replace the bundle while the old process keeps
            // its socket open, so no bridge-status callback may follow.
            hid.applyLighting(effectiveLightingSummary())
        }
        chatGPTNeedsRestart = launcher.isRunning() && !fullBridgeReady
    }

    func start() {
        guard !shuttingDown else { return }
        guard !started else { return }
        started = true
        compatibility = launcher.compatibility()
        installationIdentifier = launcher.installationIdentifier()
        shortcutPermissionGranted = shortcutPoster.hasPostEventAccess()
        recoverKeyboardMappingBeforeHIDOpen()
        if hidOnlyMode {
            hid.start(seize: true)
            hid.applyLighting(effectiveLightingSummary())
            chatGPTNeedsRestart = false
            showFeedback(
                RuntimeFeedback(
                    message: "Только HID · ChatGPT отключён",
                    symbol: "checkmark.shield",
                    kind: .mode,
                    persistent: false
                )
            )
            return
        }
        bridge.start()
        connectionMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, !self.shuttingDown else { return }
                self.refreshChatGPTConnection()
            }
        }
        refreshSkills()
        chatGPTNeedsRestart = launcher.isRunning()
        if preferences.setupCompleted {
            hid.start(seize: true)
            hid.applyLighting(effectiveLightingSummary())
        }
    }

    func setControllerEnabled(_ enabled: Bool) {
        if enabled {
            recoverKeyboardMappingBeforeHIDOpen()
            hid.start(seize: true)
        } else {
            hid.stop()
            disableKeyboardSuppression()
        }
    }

    func requestInputMonitoring() {
        hid.requestInputMonitoring()
        recoverKeyboardMappingBeforeHIDOpen()
        hid.start(seize: true)
        hid.applyLighting(effectiveLightingSummary())
    }

    func refreshInputMonitoringAfterSettings() {
        guard case .waitingForPermission = deviceState else { return }
        recoverKeyboardMappingBeforeHIDOpen()
        hid.start(seize: true)
        hid.applyLighting(effectiveLightingSummary())
    }

    func connectController() {
        recoverKeyboardMappingBeforeHIDOpen()
        hid.start(seize: true)
        hid.applyLighting(effectiveLightingSummary())
    }

    func completeSetup(autoLaunch: Bool) {
        inputTestMode = false
        preferences.markSetupCompleted(autoLaunch: autoLaunch)
        connectController()
        if autoLaunch, !launcher.isRunning() {
            launchChatGPT()
        } else {
            chatGPTNeedsRestart = launcher.isRunning() && bridgeStatus != .connected
        }
        showFeedback(
            RuntimeFeedback(
                message: "Nostromo готов",
                symbol: "checkmark.circle.fill",
                kind: .action,
                persistent: false
            )
        )
    }

    func restartSetup() {
        inputTestMode = false
        setupPhase = .welcome
        preferences.resetSetup()
    }

    func setInputTestMode(_ enabled: Bool) {
        resetActiveInputState()
        inputTestMode = enabled
        activeControls.removeAll()
    }

    func applyStarterKeymap(_ starter: StarterKeymap) {
        guard let index = activeProfileIndex else { return }
        var candidate = configuration
        switch starter {
        case .codexEssentials:
            let defaults = AppConfiguration.defaults().profiles[0].bindings
            candidate.profiles[index].bindings = defaults
        case .blank:
            candidate.profiles[index].bindings = Dictionary(
                uniqueKeysWithValues: ControlID.allCases.map { ($0, .none) }
            )
        }
        if commitConfiguration(candidate) {
            selectedStarterKeymap = starter
        }
    }

    func requestShortcutPermission() {
        shortcutPermissionGranted = shortcutPoster.requestPostEventAccess()
        if !shortcutPermissionGranted {
            reportMessage("macOS не разрешила отправку сочетания клавиш. Предоставьте Nostromo Codex универсальный доступ.")
        }
    }

    func restartThroughNostromo() {
        guard !shuttingDown else { return }
        guard !hidOnlyMode else {
            reportMessage("В режиме «Только HID» нельзя запускать или перезапускать ChatGPT.")
            return
        }
        guard !launchInProgress else { return }
        // Validate before closing the user's existing application.
        compatibility = launcher.compatibility()
        do {
            try ChatGPTLauncher.validateCompatibility(compatibility, forceUnsupported: configuration.forceUnsupportedChatGPT)
        } catch {
            report(error)
            return
        }
        guard bridgeStatus == .listening || bridgeStatus == .connected else {
            reportMessage("Приватное подключение ещё не готово. Повторите попытку через несколько секунд.")
            return
        }
        guard let preload = preloadURL() else {
            reportMessage("Встроенный адаптер ChatGPT отсутствует.")
            return
        }
        let forceUnsupported = configuration.forceUnsupportedChatGPT
        launchInProgress = true
        Task {
            defer { launchInProgress = false }
            await launcher.terminateRunningApplications()
            guard !shuttingDown else { return }
            do {
                try await launcher.launch(
                    preloadURL: preload,
                    socketPath: bridge.socketPath,
                    sessionDescriptorPath: bridge.sessionDescriptorPath,
                    token: bridge.token,
                    forceUnsupported: forceUnsupported
                )
                chatGPTNeedsRestart = false
            } catch {
                guard !shuttingDown else { return }
                let bridgeError = error.localizedDescription
                guard !launcher.isRunning() else {
                    report(error)
                    return
                }
                do {
                    try await launcher.launchNormally()
                    chatGPTNeedsRestart = true
                    reportMessage(
                        "ChatGPT открыт в обычном режиме. Подключение Nostromo "
                            + "не удалось: \(bridgeError)"
                    )
                } catch {
                    reportMessage(
                        "Не удалось открыть ChatGPT после перезапуска: "
                            + "\(error.localizedDescription) Подключение Nostromo: \(bridgeError)"
                    )
                }
            }
        }
    }

    func launchChatGPT() {
        Task {
            await launchChatGPTNow()
        }
    }

    private func launchChatGPTNow() async {
        guard !shuttingDown else { return }
        guard !hidOnlyMode else {
            reportMessage("В режиме «Только HID» мост и запуск ChatGPT отключены.")
            return
        }
        guard !launchInProgress else { return }
        refreshChatGPTConnection()
        if !(compatibility.supported || configuration.forceUnsupportedChatGPT)
            || !compatibility.requiredModulesPresent {
            launchInProgress = true
            defer { launchInProgress = false }
            do {
                try await launcher.launchNormally()
                chatGPTNeedsRestart = true
            } catch { report(error) }
            return
        }
        guard bridgeStatus == .listening || bridgeStatus == .connected else {
            reportMessage("Приватное подключение ещё не готово. Повторите попытку через несколько секунд.")
            return
        }
        guard let preload = preloadURL() else {
            reportMessage("Встроенный адаптер ChatGPT отсутствует.")
            return
        }
        guard !launchInProgress else { return }
        refreshChatGPTConnection()
        launchInProgress = true
        defer { launchInProgress = false }
        do {
            try await launcher.launch(
                preloadURL: preload,
                socketPath: bridge.socketPath,
                sessionDescriptorPath: bridge.sessionDescriptorPath,
                token: bridge.token,
                forceUnsupported: configuration.forceUnsupportedChatGPT
            )
            chatGPTNeedsRestart = false
        } catch {
            report(error)
        }
    }

    // MARK: Profiles and persistent configuration

    func activateProfile(_ id: UUID) {
        guard configuration.profiles.contains(where: { $0.id == id }) else { return }
        var candidate = configuration
        candidate.activeProfileID = id
        var candidateRuntime = profileRuntime
        candidateRuntime.selectPersistent(id)
        if commitConfiguration(candidate, runtime: candidateRuntime) {
            presentActiveProfile()
        }
    }

    private func applyRuntimeProfile(_ id: UUID) {
        guard configuration.profiles.contains(where: { $0.id == id }) else { return }
        configuration.activeProfileID = id
        presentActiveProfile()
    }

    private func presentActiveProfile() {
        hid.applyLighting(effectiveLightingSummary())
        showHUD(activeProfile.name)
    }

    func addProfile() {
        let profile = ControllerProfile(name: "Новый профиль", bindings: [:])
        var candidate = configuration
        candidate.profiles.append(profile)
        candidate.activeProfileID = profile.id
        var candidateRuntime = profileRuntime
        candidateRuntime.selectPersistent(profile.id)
        if commitConfiguration(candidate, runtime: candidateRuntime) {
            presentActiveProfile()
        }
    }

    func duplicateActiveProfile() {
        let copy = ControllerProfile(
            name: "\(activeProfile.name) — копия",
            bindings: activeProfile.bindings
        )
        var candidate = configuration
        candidate.profiles.append(copy)
        candidate.activeProfileID = copy.id
        var candidateRuntime = profileRuntime
        candidateRuntime.selectPersistent(copy.id)
        if commitConfiguration(candidate, runtime: candidateRuntime) {
            presentActiveProfile()
        }
    }

    func restoreProfile(_ profile: ControllerProfile) {
        guard !configuration.profiles.contains(where: { $0.id == profile.id }) else { return }
        var candidate = configuration
        candidate.profiles.append(profile)
        candidate.activeProfileID = profile.id
        var candidateRuntime = profileRuntime
        candidateRuntime.selectPersistent(profile.id)
        if commitConfiguration(candidate, runtime: candidateRuntime) {
            presentActiveProfile()
        }
    }

    func deleteActiveProfile() {
        guard configuration.profiles.count > 1 else {
            reportMessage("Нельзя удалить единственный профиль.")
            return
        }
        let visibleProfileID = configuration.activeProfileID
        var candidate = configuration
        candidate.profiles.removeAll(where: { $0.id == visibleProfileID })
        var candidateRuntime = profileRuntime
        candidateRuntime.restorePersistent()
        if candidateRuntime.persistentProfileID == visibleProfileID
            || !candidate.profiles.contains(where: {
                $0.id == candidateRuntime.persistentProfileID
            })
        {
            candidateRuntime.selectPersistent(candidate.profiles[0].id)
        } else {
            candidateRuntime.selectPersistent(candidateRuntime.persistentProfileID)
        }
        candidate.activeProfileID = candidateRuntime.persistentProfileID
        if commitConfiguration(candidate, runtime: candidateRuntime) {
            presentActiveProfile()
        }
    }

    func renameActiveProfile(_ name: String) {
        guard let index = activeProfileIndex else { return }
        var candidate = configuration
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.profiles[index].name = trimmed.isEmpty ? "Без названия" : trimmed
        commitConfiguration(candidate)
    }

    func setBinding(_ action: BindingAction, for control: ControlID? = nil) {
        guard let index = activeProfileIndex else { return }
        var candidate = configuration
        candidate.profiles[index].bindings[control ?? selectedControl] = action
        if commitConfiguration(candidate) {
            objectWillChange.send()
        }
    }

    func clearActiveProfileBindings() {
        guard let index = activeProfileIndex else { return }
        var candidate = configuration
        candidate.profiles[index].bindings = Dictionary(
            uniqueKeysWithValues: ControlID.allCases.map { ($0, .none) }
        )
        if commitConfiguration(candidate) {
            resetActiveInputState()
            objectWillChange.send()
        }
    }

    func setForceUnsupported(_ enabled: Bool) {
        let wasReady = fullBridgeReady
        var candidate = configuration
        candidate.forceUnsupportedChatGPT = enabled
        if commitConfiguration(candidate), wasReady != fullBridgeReady {
            resetInputForConnectionChange()
            if !fullBridgeReady {
                taskSlots = []
                reasoningEffort = nil
            }
            hid.applyLighting(effectiveLightingSummary())
        }
    }

    func setAutoLaunchChatGPT(_ enabled: Bool) {
        preferences.autoLaunchChatGPT = enabled
    }

    // MARK: Presentation and lighting

    func synchronizeApplicationPresentation() {
        // Nostromo Codex is a menu-bar utility. Keep it out of the Dock even
        // when a dashboard window is open.
        _ = NSApplication.shared.setActivationPolicy(.accessory)
    }

    func setKeypadLightingEnabled(_ enabled: Bool) {
        updateLightingSettings {
            $0.keypadEnabled = enabled
        }
    }

    func setMaximumLightingBrightness(_ brightness: Double) {
        updateLightingSettings {
            $0.maximumBrightness = min(1, max(0, brightness))
        }
    }

    func setPressFeedbackEnabled(_ enabled: Bool) {
        updateLightingSettings {
            $0.pressFeedbackEnabled = enabled
        }
    }

    func setPressFeedbackStrength(_ strength: Double) {
        updateLightingSettings {
            $0.pressFeedbackStrength = min(1, max(0, strength))
        }
    }

    func testLightingFlash() {
        guard
            configuration.lighting.keypadEnabled,
            configuration.lighting.pressFeedbackEnabled
        else {
            return
        }
        hid.pulseBacklight(strength: configuration.lighting.pressFeedbackStrength)
    }

    private func flashTaskCompletion() {
        guard configuration.lighting.keypadEnabled else { return }
        hid.pulseBacklight(strength: 1)
    }

    func refreshSkills() {
        let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        Task {
            let scanned = await Task.detached {
                do {
                    return try CodexSkillCatalog(workspace: workspace).load()
                } catch {
                    return SkillScanner.standard(workspace: workspace).scan()
                }
            }.value
            guard !shuttingDown else { return }
            skills = scanned
        }
    }

    // MARK: Calibration, shutdown, import, and diagnostics

    func beginCalibration() {
        resetActiveInputState()
        calibration.begin(from: configuration.calibration)
        reportMessage(nil)
    }

    func cancelCalibration() {
        calibration.cancel()
        gestures.resetDPad()
        activeDPadControl = nil
    }

    func shutdown() {
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
        guard !shuttingDown else { return }
        shuttingDown = true
        scheduler.cancelAll()
        resetActiveInputState()
        hid.onEvent = nil
        hid.onState = nil
        hid.onDiagnostic = nil
        bridge.onHostReport = nil
        bridge.onStatus = nil
        bridge.onCapabilities = nil
        bridge.onRuntimeState = nil
        bridge.onTaskSlots = nil
        hid.stop()
        disableKeyboardSuppression()
        bridge.stop()
    }

    func exportProfiles() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "nostromo-codex-profiles.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(persistedConfigurationSnapshot(), to: url)
        } catch {
            report(error)
        }
    }

    func importProfiles() {
        chooseProfilesForImport()
    }

    func chooseProfilesForImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pendingImportedConfiguration = try store.importConfiguration(from: url)
            pendingImportName = url.lastPathComponent
        } catch {
            report(error)
        }
    }

    func confirmProfilesImport() {
        guard let imported = pendingImportedConfiguration else { return }
        do {
            _ = try store.backup(persistedConfigurationSnapshot(), label: "before-import")
            var candidateRuntime = profileRuntime
            candidateRuntime.selectPersistent(imported.activeProfileID)
            guard commitConfiguration(imported, runtime: candidateRuntime) else { return }
            presentActiveProfile()
            pendingImportedConfiguration = nil
            pendingImportName = nil
            showHUD("Профили импортированы")
        } catch {
            report(error)
        }
    }

    func cancelProfilesImport() {
        pendingImportedConfiguration = nil
        pendingImportName = nil
    }

    func clearHIDDiagnostics() {
        hidDiagnosticEvents.removeAll(keepingCapacity: true)
        hidPipelineDiagnostics = HIDPipelineDiagnostics()
        nextHIDDiagnosticSequence = 1
    }

    func clearError() {
        reportMessage(nil)
        hid.applyLighting(effectiveLightingSummary())
    }

    func hidDiagnosticsData() throws -> Data {
        let snapshot = HIDDiagnosticExport(
            formatVersion: 3,
            generatedAt: Date(),
            vendorID: NostromoHIDManager.vendorID,
            productID: NostromoHIDManager.productID,
            hidOnlyMode: hidOnlyMode,
            applicationVersion:
                Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "unknown",
            applicationBuild:
                Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String ?? "unknown",
            applicationBundlePath: Bundle.main.bundleURL.path,
            executablePath: Bundle.main.executableURL?.path,
            operatingSystem:
                ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.runtimeArchitecture,
            applicationIdentity: applicationIdentityDiagnostics,
            chatGPTVersion: compatibility.version,
            chatGPTBuild: compatibility.build,
            deviceState: diagnosticDeviceState,
            inputProtection: diagnosticInputProtection,
            bridgeStatus: diagnosticBridgeStatus,
            pipeline: hidPipelineDiagnostics,
            diagnosticMessages: hidDiagnosticMessages,
            events: hidDiagnosticEvents
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }

    func exportHIDDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "nostromo-hid-events.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try hidDiagnosticsData().write(to: url, options: [.atomic])
        } catch {
            report(error)
        }
    }

    func bindingSummary(for control: ControlID) -> String {
        let action = activeProfile.bindings[control] ?? .none
        guard
            case let .taskSlot(slot) = action,
            let task = taskSlot(slot),
            let title = task.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        else {
            return BindingSummary.text(for: action)
        }
        return "Задача \(slot + 1) · \(title)"
    }

    func compactBindingSummary(for control: ControlID) -> String {
        let action = activeProfile.bindings[control] ?? .none
        guard
            case let .taskSlot(slot) = action,
            let title = taskSlot(slot)?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        else {
            return BindingSummary.compactText(for: action)
        }
        return title
    }

    func taskSlot(_ id: Int) -> CodexTaskSlot? {
        taskSlots.first { $0.id == id }
    }

    private var activeProfileIndex: Int? {
        configuration.profiles.firstIndex(where: { $0.id == configuration.activeProfileID })
    }

    // MARK: Service callbacks and recovery

    private func handleBridgeStatus(_ status: BridgeStatus) {
        guard !shuttingDown else { return }
        let lostAuthenticatedClient = bridgeStatus == .connected && status != .connected
        bridgeStatus = status
        if lostAuthenticatedClient {
            resetInputForConnectionChange()
            taskSlots = []
        }
        switch status {
        case .connected:
            chatGPTNeedsRestart = false
            runtimeCapabilities = nil
            reasoningEffort = nil
            bridge.dispatch(.queryRuntimeState)
        case .listening:
            runtimeCapabilities = nil
            reasoningEffort = nil
            chatGPTNeedsRestart = launcher.isRunning()
            if preferences.setupCompleted,
               preferences.autoLaunchChatGPT,
               !launcher.isRunning(),
               !attemptedAutoLaunch
            {
                attemptedAutoLaunch = true
                launchChatGPT()
            }
        case let .failed(message):
            runtimeCapabilities = nil
            reasoningEffort = nil
            reportMessage(message)
        case .stopped:
            runtimeCapabilities = nil
            reasoningEffort = nil
            break
        }
        hid.applyLighting(effectiveLightingSummary())
    }

    private func handleDeviceState(_ state: NostromoDeviceState) {
        guard !shuttingDown else { return }
        deviceState = state
        switch state {
        case .stopped, .disconnected, .error:
            disableKeyboardSuppression()
            if calibrationTarget != nil {
                cancelCalibration()
            } else {
                calibration.clearReleaseGate()
            }
            resetActiveInputState()
        case .waitingForPermission:
            disableKeyboardSuppression()
            break
        case let .connected(_, captureMode):
            switch captureMode {
            case .exclusive:
                keyboardSuppressionTask?.cancel()
                keyboardSuppressionTask = nil
                updateInputProtectionStatus(.exclusiveCapture)
            case .shared:
                scheduleKeyboardSuppression()
            }
        }
    }

    private func resetActiveInputState() {
        fallbackGeneration += 1
        fallbackTask?.cancel()
        fallbackTask = nil
        let controls = Array(pressedActions.keys)
        let now = ProcessInfo.processInfo.systemUptime
        for control in controls {
            execute(control: control, pressed: false, at: now)
        }
        if pushToTalkActive, !hidOnlyMode {
            bridge.dispatch(.pushToTalkStop)
        }
        pushToTalkActive = false
        voiceFeedbackActive = false
        pushToTalk = PushToTalkGestureMachine()
        gestures.reset()
        activeDPadControl = nil
        activeControls.removeAll()
        if runtimeFeedback?.kind == .voice {
            runtimeFeedback = nil
            hudMessage = nil
        }
    }

    private func resetInputForConnectionChange() {
        let held = Set(pressedActions.keys)
        resetActiveInputState()
        connectionHeldControls.formUnion(held)
    }

    private var keyboardUsagesToSuppress: Set<UInt32> {
        let keyboardPage = UInt32(kHIDPage_KeyboardOrKeypad)
        let factory = CalibrationMap.nostromoFactory.signatures.values
            .filter { $0.usagePage == keyboardPage && $0.kind == .button }
            .map(\.usage)
        let calibrated = configuration.calibration.signatures.values
            .filter { $0.usagePage == keyboardPage && $0.kind == .button }
            .map(\.usage)
        // The physical D-pad is a second path through the same keyboard HID
        // service and reports USB keyboard arrow usages.
        return Set(factory + calibrated + [0x4F, 0x50, 0x51, 0x52])
    }

    private func scheduleKeyboardSuppression() {
        keyboardSuppressionTask?.cancel()
        updateInputProtectionStatus(.pending)
        let usages = keyboardUsagesToSuppress
        keyboardSuppressionTask = Task { [weak self] in
            guard let self else { return }
            let retryDelays: [Duration] = [
                .zero,
                .milliseconds(250),
                .seconds(1),
            ]
            var finalStatus: NostromoInputProtectionStatus = .deviceUnavailable
            for delay in retryDelays {
                if delay != .zero {
                    try? await Task.sleep(for: delay)
                }
                guard !Task.isCancelled else { return }
                guard case let .connected(_, captureMode) = self.deviceState,
                      captureMode == .shared
                else {
                    return
                }
                finalStatus = self.keyboardSuppressor.suppress(usages: usages)
                self.updateInputProtectionStatus(finalStatus)
                if case .active = finalStatus {
                    return
                }
            }
            let message = switch finalStatus {
            case .deviceUnavailable:
                "Nostromo подключён, но его клавиатурный HID-сервис не найден. Защита от печати не включена."
            case let .failed(failure):
                "Не удалось безопасно изолировать ввод Nostromo: \(failure.summary)"
            default:
                "Не удалось включить защиту от клавиатурного ввода Nostromo."
            }
            self.hidDiagnosticMessages.append(message)
            self.reportMessage(message)
        }
    }

    private func disableKeyboardSuppression() {
        keyboardSuppressionTask?.cancel()
        keyboardSuppressionTask = nil
        let result = keyboardSuppressor.restore()
        if !result.isComplete {
            hidDiagnosticMessages.append(
                "Восстановление UserKeyMapping не завершено: "
                    + restorationFailureSummary(result)
            )
        }
        updateInputProtectionStatus(.inactive)
    }

    private func recoverKeyboardMappingBeforeHIDOpen() {
        let result = keyboardSuppressor.recover()
        guard !result.isComplete else { return }
        hidDiagnosticMessages.append(
            "Ожидает восстановления UserKeyMapping: "
                + restorationFailureSummary(result)
        )
    }

    private func restorationFailureSummary(
        _ result: NostromoKeyboardRestorationResult
    ) -> String {
        let details = result.failures
            .map(\.diagnosticDescription)
            .joined(separator: "; ")
        if !details.isEmpty { return details }
        return "ожидающих HID-сервисов: \(result.pendingServiceCount)"
    }

    private func updateInputProtectionStatus(
        _ status: NostromoInputProtectionStatus
    ) {
        if inputProtectionStatus.allowsActionDispatch,
           !status.allowsActionDispatch
        {
            resetActiveInputState()
        }
        inputProtectionStatus = status
    }

    private func reportUnsafeInputProtection() {
        hidPipelineDiagnostics.blockedActionCount += 1
        hidPipelineDiagnostics.lastDispatchOutcome =
            "blocked: input protection is not verified"
        reportMessage(
            "Назначения приостановлены: macOS не подтвердила безопасную "
                + "изоляцию клавиатурного ввода Nostromo. Проверка ввода "
                + "и калибровка остаются доступны."
        )
    }

    private func handleHIDEvent(_ event: NostromoHIDEvent) {
        guard !shuttingDown else { return }
        lastHIDEvent = "\(event.signature.description) = \(event.value)"
        hidPipelineDiagnostics.rawEventCount += 1
        hidDiagnosticEvents.append(
            HIDDiagnosticEntry(
                sequence: nextHIDDiagnosticSequence,
                event: event
            )
        )
        nextHIDDiagnosticSequence += 1
        let eventLimit = hidOnlyMode ? 2_000 : 256
        if hidDiagnosticEvents.count > eventLimit {
            hidDiagnosticEvents.removeFirst(
                hidDiagnosticEvents.count - eventLimit
            )
        }
        guard event.eligibleForAction else {
            lastHIDEvent += " · подавлено после переподключения"
            return
        }
        hidPipelineDiagnostics.eligibleEventCount += 1

        if calibration.consumesReleaseGate(signature: event.signature, value: event.value) {
            return
        }

        if event.signature.usagePage == UInt32(kHIDPage_KeyboardOrKeypad),
           let button = DPadButton(keyboardUsage: event.signature.usage)
        {
            gestures.ingest(button: button, pressed: event.value != 0, at: event.timestamp)
            return
        }

        if calibrationTarget != nil, event.signature.kind == .button {
            if let message = calibration.recordButton(event.signature, value: event.value) {
                reportMessage(message)
            }
            if calibrationTarget == nil { finishCalibration() }
            return
        }

        if event.signature.usagePage == UInt32(kHIDPage_GenericDesktop) {
            switch event.signature.usage {
            case UInt32(kHIDUsage_GD_Wheel):
                guard calibrationTarget == nil else { return }
                handleWheelRotation(event.value, at: event.timestamp)
                return
            case UInt32(kHIDUsage_GD_X):
                gestures.ingest(axis: .x, value: event.value, at: event.timestamp)
                return
            case UInt32(kHIDUsage_GD_Y):
                gestures.ingest(axis: .y, value: event.value, at: event.timestamp)
                return
            default:
                break
            }
        }

        guard let control = configuration.calibration.control(for: event.signature) else { return }
        recordMappedControl(control)
        if control == .wheelPress {
            handleWheelPress(pressed: event.value != 0, at: event.timestamp)
        } else {
            execute(control: control, pressed: event.value != 0, at: event.timestamp)
        }
    }

    // MARK: HID gesture routing

    private func applyDPadDirection(_ direction: DPadDirection, at time: TimeInterval) {
        if calibrationTarget != nil {
            if let message = calibration.recordDirection(direction) {
                reportMessage(message)
            }
            if calibrationTarget == nil { finishCalibration() }
            return
        }
        guard let mappedControl = configuration.calibration.control(for: direction) else { return }
        recordMappedControl(mappedControl)
        if let activeDPadControl, activeDPadControl != mappedControl {
            execute(control: activeDPadControl, pressed: false, at: time)
        }
        activeDPadControl = mappedControl
        execute(control: mappedControl, pressed: true, at: time)
    }

    private func handleWheelPress(pressed: Bool, at time: TimeInterval) {
        if inputTestMode {
            if pressed {
                guard !activeControls.contains(.wheelPress) else { return }
                activeControls.insert(.wheelPress)
                showFeedback(
                    RuntimeFeedback(
                        message: "Ввод · Нажатие колеса",
                        symbol: "hand.tap",
                        kind: .action,
                        persistent: false
                    )
                )
            } else {
                activeControls.remove(.wheelPress)
            }
            return
        }

        if pressed {
            guard inputProtectionAllowsActions else {
                reportUnsafeInputProtection()
                return
            }
            guard !gestures.wheelPressed else { return }
            activeControls.insert(.wheelPress)
            confirmPhysicalPress()
            gestures.pressWheel(at: time)
        } else {
            guard gestures.wheelPressed else { return }
            activeControls.remove(.wheelPress)
            gestures.releaseWheel(at: time)
        }
    }

    private func handleWheelRotation(_ delta: Int, at time: TimeInterval) {
        if inputTestMode {
            guard delta != 0 else { return }
            showFeedback(
                RuntimeFeedback(
                    message: delta > 0 ? "Ввод · Колесо по часовой стрелке" : "Ввод · Колесо против часовой стрелки",
                    symbol: "scroll",
                    kind: .action,
                    persistent: false
                )
            )
            return
        }
        guard inputProtectionAllowsActions else {
            reportUnsafeInputProtection()
            return
        }
        confirmPhysicalPress()
        gestures.rotateWheel(delta, at: time)
    }

    private func handleWheelOutputs(_ outputs: [WheelOutput]) {
        for output in outputs {
            switch output {
            case let .scroll(delta):
                if hidOnlyMode {
                    showHUD("HID · Прокрутка \(delta)")
                } else {
                    dispatchBridgeAction(
                        .scrollTask(deltaY: delta * 52)
                    )
                }
            case let .reasoning(delta):
                if hidOnlyMode {
                    showHUD("HID · Рассуждение \(delta > 0 ? "+" : "−")")
                } else {
                    guard fullBridgeReady else {
                        reportMessage("Изменение глубины рассуждения требует полного подключения к Codex.")
                        return
                    }
                    let id = delta > 0 ? "composer.increaseReasoningEffort" : "composer.decreaseReasoningEffort"
                    for _ in 0 ..< abs(delta) { dispatchCommand(id) }
                    showHUD(delta > 0 ? "Рассуждение +" : "Рассуждение −")
                }
            case let .modeChanged(mode):
                wheelMode = mode
                showFeedback(
                    RuntimeFeedback(
                        message: mode == .scroll ? "Колесо · Прокрутка" : "Колесо · Рассуждение",
                        symbol: mode == .scroll ? "scroll" : "brain",
                        kind: .mode,
                        persistent: false
                    )
                )
            case .openSettings:
                dashboardSection = .connection
                NostromoApplicationDelegate.requestDashboardOpen(.connection)
            }
        }
    }

    // MARK: Binding execution

    private func execute(
        control: ControlID,
        pressed: Bool,
        at time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        if connectionHeldControls.contains(control) {
            if !pressed { connectionHeldControls.remove(control) }
            return
        }
        if pressed {
            activeControls.insert(control)
        } else {
            activeControls.remove(control)
        }
        if inputTestMode {
            if pressed {
                showFeedback(
                    RuntimeFeedback(
                        message: "Ввод · \(control.title)",
                        symbol: "hand.tap",
                        kind: .action,
                        persistent: false
                    )
                )
            }
            return
        }

        if pressed, !inputProtectionAllowsActions {
            reportUnsafeInputProtection()
            return
        }

        let action: BindingAction
        if pressed {
            guard pressedActions[control] == nil else { return }
            action = activeProfile.bindings[control] ?? .none
            pressedActions[control] = action
            hidPipelineDiagnostics.bindingExecutionCount += 1
            hidPipelineDiagnostics.lastBinding =
                BindingSummary.text(for: action)
            confirmPhysicalPress()
        } else {
            guard let pressedAction = pressedActions.removeValue(forKey: control) else { return }
            action = pressedAction
        }
        if hidOnlyMode {
            if pressed {
                showHUD("HID · \(control.title) · \(BindingSummary.text(for: action))")
            }
            return
        }
        switch action {
        case let .taskSlot(slot):
            guard pressed ? fullBridgeReady : bridge.isAuthenticated else {
                if pressed { reportBridgeDisconnected() }
                return
            }
            tryEngine { try engine.emitKey(String(format: "AG%02d", slot), pressed: pressed, agent: slot) }
        case let .codexAction(id):
            let execution = CodexActionCatalog.descriptor(for: id)?.execution
                ?? .runtimeCommand
            if execution == .pushToTalk {
                handlePushToTalk(pressed: pressed, at: time)
                return
            }
            guard pressed else { return }
            switch execution {
            case .runtimeCommand:
                dispatchCommand(id)
            case .focusChatGPT:
                toggleChatGPTVisibility()
            case .pushToTalk:
                break
            case .stopActive:
                dispatchBridgeAction(.stopActive)
            case .submitActiveComposer:
                dispatchSubmit()
            case .toggleChatWorkMode:
                dispatchBridgeAction(
                    .toggleChatWorkMode,
                    successHUD: "Режим Chat / Work переключён"
                )
            case let .insertComposerText(text):
                dispatchBridgeAction(
                    .insertComposerText(text: text),
                    successHUD: "Список навыков открыт"
                )
            case .clearComposerProject:
                dispatchBridgeAction(
                    .clearComposerProject,
                    successHUD: "Проект убран"
                )
            }
        case let .skill(skill):
            guard pressed else { return }
            guard skills.contains(where: { $0.id == skill.id && $0.enabled }) else {
                reportMessage("Навык \(skill.displayName) больше недоступен.")
                return
            }
            dispatchBridgeAction(
                .insertSkillMention(
                    name: skill.name,
                    displayName: skill.displayName,
                    path: skill.path
                ),
                successHUD: "Навык вставлен"
            )
        case let .pluginPrompt(plugin):
            guard pressed else { return }
            guard plugin.isConfigured else {
                reportMessage("Перед использованием действия укажите название плагина и полный URI вида plugin://.")
                return
            }
            dispatchBridgeAction(
                .preparePluginPrompt(text: plugin.composerText),
                successHUD: "Запрос подготовлен"
            )
        case let .shortcut(shortcut):
            guard pressed else { return }
            if postShortcut(shortcut, keyDown: true) {
                _ = postShortcut(shortcut, keyDown: false)
            }
        case let .profileSwitch(profileID, behavior):
            guard let targetProfileID = profileID ?? nextProfileID() else { return }
            switch behavior {
            case .toggle where pressed:
                activateProfile(targetProfileID)
            case .momentary where pressed:
                let target = profileRuntime.beginMomentary(
                    control: control,
                    target: targetProfileID
                )
                applyRuntimeProfile(target)
            case .momentary where !pressed:
                releaseMomentaryProfile(control: control)
            default:
                break
            }
        case .none:
            break
        }
    }

    private func nextProfileID() -> UUID? {
        guard
            !configuration.profiles.isEmpty,
            let current = configuration.profiles.firstIndex(where: { $0.id == configuration.activeProfileID })
        else { return configuration.profiles.first?.id }
        return configuration.profiles[(current + 1) % configuration.profiles.count].id
    }

    private func releaseMomentaryProfile(control: ControlID) {
        guard let target = profileRuntime.releaseMomentary(control: control) else { return }
        applyRuntimeProfile(target)
    }

    private func toggleChatGPTVisibility() {
        guard fullBridgeReady else {
            reportMessage("Переключение окна требует полного подключения. Базовые команды сами активируют Codex.")
            return
        }
        let minimizeIfVisible = launcher.isActive()
        let action = BridgeAppAction.toggleChatGPT(
            minimizeIfVisible: minimizeIfVisible
        )
        recordBridgeDispatchAttempt(action)
        bridge.dispatch(action) { [weak self] result in
            Task { @MainActor in
                guard let self, !self.shuttingDown else { return }
                switch result {
                case .success:
                    self.recordBridgeDispatchSuccess()
                    // Electron must restore the window before macOS activation.
                    // Do not activate after the minimize branch: doing so can
                    // immediately undo the second press.
                    if !minimizeIfVisible, !self.launcher.activate() {
                        self.reportMessage("ChatGPT запущен, но macOS не разрешила вывести его окно на передний план.")
                    }
                case let .failure(error):
                    self.recordBridgeDispatchFailure(error)
                    self.report(error)
                }
            }
        }
    }

    private func handlePushToTalk(pressed: Bool, at time: TimeInterval) {
        guard !pressed || fullBridgeReady else {
            reportBridgeDisconnected()
            return
        }
        let outputs = pressed ? pushToTalk.press(at: time) : pushToTalk.release(at: time)
        for output in outputs {
            switch output {
            case .start:
                pushToTalkActive = true
                dispatchBridgeAction(.pushToTalkStart)
            case .stop:
                pushToTalkActive = false
                dispatchBridgeAction(.pushToTalkStop)
            case .latched:
                voiceFeedbackActive = true
                showFeedback(
                    RuntimeFeedback(
                        message: "Микрофон остаётся включённым",
                        symbol: "mic.fill",
                        kind: .voice,
                        persistent: true
                    )
                )
            case .unlatched:
                voiceFeedbackActive = false
                showFeedback(
                    RuntimeFeedback(
                        message: "Микрофон выключен",
                        symbol: "mic.slash.fill",
                        kind: .voice,
                        persistent: false
                    )
                )
            }
        }
    }

    private func dispatchCommand(_ id: String) {
        if !fullBridgeReady {
            guard let descriptor = CodexActionCatalog.descriptor(for: id),
                  !descriptor.consequential, let fallback = descriptor.fallback else {
                reportMessage("Этой команде требуется полное подключение к Codex.")
                return
            }
            // Pick exactly one transport. Never replay an uncertain bridge
            // result as a menu action, and never queue a burst across activation.
            guard fallbackTask == nil else { return }
            fallbackGeneration += 1
            let generation = fallbackGeneration
            fallbackTask = Task { [weak self] in
                guard let self, !self.shuttingDown else { return }
                defer { if self.fallbackGeneration == generation { self.fallbackTask = nil } }
                do {
                    try await self.fallbackController.perform(fallback)
                } catch is CancellationError {
                } catch {
                    self.report(error)
                }
            }
            return
        }
        if let descriptor = actionCatalog.first(where: { $0.id == id }), !descriptor.available {
            reportMessage("Действие «\(descriptor.title)» недоступно: \(descriptor.detail)")
            return
        }
        let action = BridgeAppAction.runCommand(id: id)
        recordBridgeDispatchAttempt(action)
        bridge.dispatch(action) { [weak self] result in
            Task { @MainActor in
                guard let self, !self.shuttingDown else { return }
                switch result {
                case .success:
                    self.recordBridgeDispatchSuccess()
                    if id.localizedCaseInsensitiveContains("reasoning") {
                        self.bridge.dispatch(.queryRuntimeState)
                    }
                case let .failure(error):
                    self.recordBridgeDispatchFailure(error)
                    self.report(error)
                }
            }
        }
    }

    private func dispatchSubmit() {
        if let descriptor = actionCatalog.first(where: { $0.id == "composer.submit" }),
           !descriptor.available
        {
            reportMessage("Действие «\(descriptor.title)» недоступно: \(descriptor.detail)")
            return
        }
        dispatchBridgeAction(.submitActiveComposer)
    }

    private func dispatchBridgeAction(
        _ action: BridgeAppAction,
        successHUD: String? = nil
    ) {
        guard fullBridgeReady || action == .pushToTalkStop else {
            reportMessage("Этому действию требуется полное подключение к Codex.")
            return
        }
        recordBridgeDispatchAttempt(action)
        bridge.dispatch(action) { [weak self] result in
            Task { @MainActor in
                guard let self, !self.shuttingDown else { return }
                switch result {
                case .success:
                    self.recordBridgeDispatchSuccess()
                    if let successHUD {
                        self.showHUD(successHUD)
                    }
                case let .failure(error):
                    self.recordBridgeDispatchFailure(error)
                    self.report(error)
                }
            }
        }
    }

    private func reportBridgeDisconnected() {
        reportMessage(
            "ChatGPT не подключён к Nostromo. Запустите или перезапустите ChatGPT через раздел «Подключение»."
        )
    }

    @discardableResult
    private func postShortcut(_ shortcut: ShortcutBinding, keyDown: Bool) -> Bool {
        guard shortcut.isConfigured else {
            if keyDown { reportMessage("Запишите сочетание клавиш перед использованием этого назначения.") }
            return false
        }
        guard shortcutPoster.hasPostEventAccess() else {
            shortcutPermissionGranted = false
            if keyDown {
                reportMessage("Для сочетаний клавиш macOS нужен доступ: Конфиденциальность и безопасность → Универсальный доступ.")
            }
            return false
        }
        shortcutPermissionGranted = true
        guard shortcutPoster.post(shortcut, keyDown: keyDown) else {
            if keyDown { reportMessage("Не удалось создать системное событие клавиатуры.") }
            return false
        }
        return true
    }

    private func tryEngine(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            report(error)
        }
    }

    private func confirmPhysicalPress() {
        guard
            configuration.lighting.keypadEnabled,
            configuration.lighting.pressFeedbackEnabled
        else {
            return
        }
        hid.pulseBacklight(strength: configuration.lighting.pressFeedbackStrength)
    }

    // MARK: Persistence and feedback

    private func finishCalibration() {
        guard let draft = calibration.draft else { return }
        var candidate = configuration
        candidate.calibration = draft
        if commitConfiguration(candidate) {
            calibration.finish()
            if case let .connected(_, captureMode) = deviceState,
               captureMode == .shared
            {
                scheduleKeyboardSuppression()
            }
            showHUD("Калибровка завершена")
        } else {
            cancelCalibration()
        }
    }

    @discardableResult
    private func commitConfiguration(
        _ candidate: AppConfiguration,
        runtime candidateRuntime: ProfileRuntimeState? = nil
    ) -> Bool {
        let runtime = candidateRuntime ?? profileRuntime
        do {
            if configurationLoadError != nil, invalidConfigurationBackupURL == nil {
                invalidConfigurationBackupURL = try store.backupInvalidConfiguration()
            }
            try store.save(runtime.persistedSnapshot(of: candidate))
            configuration = candidate
            profileRuntime = runtime
            configurationLoadError = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func updateLightingSettings(_ update: (inout LightingSettings) -> Void) {
        var candidate = configuration
        update(&candidate.lighting)
        guard commitConfiguration(candidate) else { return }
        hid.applyLighting(effectiveLightingSummary())
    }

    func persistedConfigurationSnapshot() -> AppConfiguration {
        profileRuntime.persistedSnapshot(of: configuration)
    }

    private func effectiveLightingSummary() -> NostromoLightingSummary {
        lightingResolution.summary
    }

    private func showHUD(_ message: String) {
        showFeedback(
            RuntimeFeedback(
                message: message,
                symbol: "command",
                kind: .action,
                persistent: false
            )
        )
    }

    private func showFeedback(_ feedback: RuntimeFeedback) {
        scheduler.cancel(.feedback)
        hudMessage = feedback.message
        runtimeFeedback = feedback
        guard !feedback.persistent else { return }
        scheduler.schedule(.feedback, after: 1.450) { [weak self] in
            guard let self else { return }
            self.hudMessage = nil
            self.runtimeFeedback = nil
        }
    }

    private func report(_ error: Error) {
        reportMessage(error.localizedDescription)
    }

    private func reportMessage(_ message: String?) {
        lastError = message
        if let message {
            showFeedback(
                RuntimeFeedback(
                    message: message,
                    symbol: "exclamationmark.triangle.fill",
                    kind: .error,
                    persistent: true
                )
            )
        } else {
            if runtimeFeedback?.kind == .error {
                runtimeFeedback = nil
            }
        }
    }

    private func recordMappedControl(_ control: ControlID) {
        hidPipelineDiagnostics.mappedControlCount += 1
        hidPipelineDiagnostics.lastMappedControl = control.title
    }

    private func recordBridgeDispatchAttempt(_ action: BridgeAppAction) {
        hidPipelineDiagnostics.bridgeDispatchAttemptCount += 1
        hidPipelineDiagnostics.lastBridgeAction = action.name
        hidPipelineDiagnostics.lastDispatchOutcome = "pending"
    }

    private func recordBridgeDispatchSuccess() {
        hidPipelineDiagnostics.bridgeDispatchSuccessCount += 1
        hidPipelineDiagnostics.lastDispatchOutcome = "success"
    }

    private func recordBridgeDispatchFailure(_ error: Error) {
        hidPipelineDiagnostics.bridgeDispatchFailureCount += 1
        hidPipelineDiagnostics.lastDispatchOutcome =
            "failure: \(error.localizedDescription)"
    }

    private var diagnosticDeviceState: String {
        switch deviceState {
        case .stopped:
            "stopped"
        case .waitingForPermission:
            "waiting-for-input-monitoring-permission"
        case .disconnected:
            "disconnected"
        case let .connected(interfaceCount, captureMode):
            "connected; interfaces=\(interfaceCount); capture=\(captureMode.rawValue)"
        case let .error(message):
            "error: \(message)"
        }
    }

    private var diagnosticInputProtection: String {
        switch inputProtectionStatus {
        case .inactive:
            "inactive"
        case .pending:
            "pending"
        case .exclusiveCapture:
            "exclusive-capture"
        case let .active(serviceCount, usageCount):
            "user-key-mapping; services=\(serviceCount); usages=\(usageCount)"
        case .deviceUnavailable:
            "device-unavailable"
        case let .failed(failure):
            "failed: \(failure.summary)"
        }
    }

    private var diagnosticBridgeStatus: String {
        switch bridgeStatus {
        case .stopped:
            "stopped"
        case .listening:
            "listening"
        case .connected:
            "connected"
        case let .failed(message):
            "failed: \(message)"
        }
    }

    private nonisolated static var runtimeArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private var applicationIdentityDiagnostics:
        ApplicationIdentityDiagnostics
    {
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let registeredURL = bundleIdentifier.flatMap {
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: $0
            )
        }
        var dynamicCode: SecCode?
        var staticCode: SecStaticCode?
        var signingInfo: CFDictionary?
        var validationStatus: OSStatus?
        if SecCodeCopySelf([], &dynamicCode) == errSecSuccess,
           let dynamicCode,
           SecCodeCopyStaticCode(dynamicCode, [], &staticCode)
            == errSecSuccess,
           let staticCode
        {
            validationStatus = SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                nil
            )
            _ = SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &signingInfo
            )
        }
        let dictionary = signingInfo as? [String: Any]
        let unique = dictionary?[
            kSecCodeInfoUnique as String
        ] as? Data
        return ApplicationIdentityDiagnostics(
            bundleIdentifier: bundleIdentifier,
            runningBundlePath: Bundle.main.bundleURL.path,
            registeredBundlePath: registeredURL?.path,
            codeIdentifier:
                dictionary?[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier:
                dictionary?[kSecCodeInfoTeamIdentifier as String] as? String,
            cdHash: unique?.map {
                String(format: "%02x", $0)
            }.joined(),
            signatureValidationStatus: validationStatus
        )
    }

    private func preloadURL() -> URL? {
        let bundleIdentifier = Bundle.main.bundleIdentifier
            ?? "dev.aleksandr.nostromo-codex"
        let registeredApplication = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        )
        return AppResourceLocator.preloadURL(
            packagedURL: Bundle.main.url(
                forResource: "chatgpt-preload",
                withExtension: "cjs"
            ),
            applicationURLs: [
                registeredApplication,
                URL(
                    fileURLWithPath: "/Applications/Nostromo Codex.app",
                    isDirectory: true
                ),
            ].compactMap { $0 },
            currentDirectoryURL: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
        )
    }
}

// MARK: Resource discovery

enum AppResourceLocator {
    private static let packagedPreloadPath =
        "Contents/Resources/chatgpt-preload.cjs"
    private static let developmentPreloadPath =
        "Sources/NostromoCodexApp/Resources/chatgpt-preload.cjs"

    static func preloadURL(
        packagedURL: URL?,
        applicationURLs: [URL],
        currentDirectoryURL: URL
    ) -> URL? {
        var candidates: [URL] = []
        if let packagedURL {
            candidates.append(packagedURL)
        }
        candidates.append(
            contentsOf: applicationURLs.map {
                $0.appendingPathComponent(packagedPreloadPath)
            }
        )
        candidates.append(
            currentDirectoryURL.appendingPathComponent(developmentPreloadPath)
        )

        return candidates.first {
            FileManager.default.isReadableFile(atPath: $0.path)
        }
    }
}
