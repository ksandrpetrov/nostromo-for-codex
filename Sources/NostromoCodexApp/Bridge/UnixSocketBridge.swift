import Darwin
import Foundation
import NostromoCodexCore
import Security

enum BridgeStatus: Equatable {
    case stopped
    case listening
    case connected
    case failed(String)
}

struct ChatGPTRuntimeCapabilities: Equatable, Sendable {
    var commandIDs: Set<String>
    var commandRegistrySource: String
    var requiredAPIs: [String: Bool]
    var unavailableFeatures: [String]
    var chatGPTVersion: String? = nil
    var chatGPTBuild: String? = nil
    var adapterID: String? = nil

    func matches(_ compatibility: ChatGPTCompatibility) -> Bool {
        chatGPTVersion == compatibility.version && chatGPTBuild == compatibility.build
            && adapterID == "micro-v1"
            && ["browserWindow", "rendererMessaging", "rendererEvaluation", "scopedHidHook", "microServiceHook"]
                .allSatisfy { requiredAPIs[$0] == true }
    }
}

struct ChatGPTRuntimeState: Equatable, Sendable {
    var reasoningEffort: String?
}

enum CodexTaskStatus: String, Equatable, Sendable {
    case off
    case working
    case unread
    case idle
    case awaitingApproval = "awaiting-approval"
    case awaitingResponse = "awaiting-response"
    case error

    var rgbValue: Int? {
        switch self {
        case .off: nil
        case .working: 0x304FFE
        case .unread: 0x00FF4C
        case .idle: 0xFFFFFF
        case .awaitingApproval, .awaitingResponse: 0xFF6D00
        case .error: 0xFF0033
        }
    }

    var title: String {
        switch self {
        case .off: "Нет задачи"
        case .working: "Выполняется"
        case .unread: "Есть новое"
        case .idle: "Ожидает"
        case .awaitingApproval: "Нужно подтверждение"
        case .awaitingResponse: "Нужен ответ"
        case .error: "Ошибка"
        }
    }
}

struct CodexTaskSlot: Equatable, Sendable {
    var id: Int
    var title: String?
    var status: CodexTaskStatus
    var selected: Bool
}

/// Concurrency ownership for this POSIX adapter is explicit: `queue` owns the
/// accept/read loop, `stateLock` owns lifecycle and descriptor identity,
/// `writeLock` plus `writerQueue` serialize socket writes, and the remaining
/// locks protect pending actions and replaceable handlers.
final class UnixSocketBridge: @unchecked Sendable {
    typealias StatusHandler = @Sendable (BridgeStatus) -> Void
    typealias HostReportHandler = @Sendable (Data) -> Void
    typealias CapabilitiesHandler = @Sendable (ChatGPTRuntimeCapabilities) -> Void
    typealias RuntimeStateHandler = @Sendable (ChatGPTRuntimeState) -> Void
    typealias TaskSlotsHandler = @Sendable ([CodexTaskSlot]) -> Void
    typealias ProcessLivenessChecker = BridgeRuntimeDirectory.ProcessLivenessChecker
    typealias OwnerProcessLiveness = BridgeRuntimeDirectory.OwnerProcessLiveness

    private enum Lifecycle {
        case initialized
        case active(UInt64)
        case stopped(UInt64)
    }

    static let runtimeDirectoryPrefix = BridgeRuntimeDirectory.directoryPrefix
    static let ownerMarkerFileName = BridgeRuntimeDirectory.ownerMarkerFileName
    static let discoveryDirectoryPrefix =
        BridgeRuntimeDirectory.discoveryDirectoryPrefix
    static let sessionDescriptorFileName =
        BridgeRuntimeDirectory.sessionDescriptorFileName

    let runtimeDirectory: URL
    let socketPath: String
    let sessionDescriptorPath: String
    let token: String

    var isAuthenticated: Bool {
        authenticatedGeneration() != nil
    }

    private let runtimeDirectoryOwner: BridgeRuntimeDirectory
    private let queue = DispatchQueue(label: "io.nostromo-codex.bridge")
    private let writerQueue = DispatchQueue(label: "io.nostromo-codex.bridge.writer")
    private let statusQueue = DispatchQueue(label: "io.nostromo-codex.bridge.status")
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private let actionLock = NSLock()
    private let handlerLock = NSLock()
    private var listenerFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var clientAuthenticated = false
    private var clientGeneration: UInt64 = 0
    private var lifecycle: Lifecycle = .initialized
    private var lifecycleGeneration: UInt64 = 0
    private var nextActionID = 1
    private var pendingActions: [Int: @Sendable (Result<Void, Error>) -> Void] = [:]

    private var statusHandler: StatusHandler?
    private var hostReportHandler: HostReportHandler?
    private var capabilitiesHandler: CapabilitiesHandler?
    private var runtimeStateHandler: RuntimeStateHandler?
    private var taskSlotsHandler: TaskSlotsHandler?

    var onStatus: StatusHandler? {
        get { handlerLock.withLock { statusHandler } }
        set { handlerLock.withLock { statusHandler = newValue } }
    }

    var onHostReport: HostReportHandler? {
        get { handlerLock.withLock { hostReportHandler } }
        set { handlerLock.withLock { hostReportHandler = newValue } }
    }

    var onCapabilities: CapabilitiesHandler? {
        get { handlerLock.withLock { capabilitiesHandler } }
        set { handlerLock.withLock { capabilitiesHandler = newValue } }
    }

    var onRuntimeState: RuntimeStateHandler? {
        get { handlerLock.withLock { runtimeStateHandler } }
        set { handlerLock.withLock { runtimeStateHandler = newValue } }
    }

    var onTaskSlots: TaskSlotsHandler? {
        get { handlerLock.withLock { taskSlotsHandler } }
        set { handlerLock.withLock { taskSlotsHandler = newValue } }
    }

    init(
        fileManager: FileManager = .default,
        runtimeRoot: URL = URL(fileURLWithPath: "/tmp", isDirectory: true),
        currentPID: Int32 = Darwin.getpid(),
        processLiveness: ProcessLivenessChecker =
            BridgeRuntimeDirectory.defaultProcessLiveness
    ) throws {
        let runtimeDirectoryOwner = try BridgeRuntimeDirectory(
            fileManager: fileManager,
            runtimeRoot: runtimeRoot,
            currentPID: currentPID,
            processLiveness: processLiveness
        )

        self.runtimeDirectoryOwner = runtimeDirectoryOwner
        runtimeDirectory = runtimeDirectoryOwner.url
        socketPath = runtimeDirectoryOwner.socketPath
        sessionDescriptorPath = runtimeDirectoryOwner.sessionDescriptorPath
        token = Self.randomToken()
    }

    deinit {
        stop()
    }

    func start() {
        stateLock.lock()
        guard case .initialized = lifecycle else {
            stateLock.unlock()
            return
        }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        lifecycle = .active(generation)
        stateLock.unlock()

        queue.async { [weak self] in
            self?.startOnQueue(generation: generation)
        }
    }

    func stop() {
        stateLock.lock()
        let shouldNotify: Bool
        let terminalGeneration: UInt64
        if case .stopped = lifecycle {
            shouldNotify = false
            terminalGeneration = lifecycleGeneration
        } else {
            lifecycleGeneration &+= 1
            terminalGeneration = lifecycleGeneration
            lifecycle = .stopped(terminalGeneration)
            shouldNotify = true
        }
        let activeListener = listenerFD
        listenerFD = -1
        stateLock.unlock()

        writeLock.lock()
        let activeClient = clientFD
        clientFD = -1
        clientAuthenticated = false
        clientGeneration &+= 1
        writeLock.unlock()
        if activeClient >= 0 {
            Darwin.shutdown(activeClient, SHUT_RDWR)
            Darwin.close(activeClient)
        }
        if activeListener >= 0 {
            Darwin.shutdown(activeListener, SHUT_RDWR)
            Darwin.close(activeListener)
        }
        failPendingActions(with: BridgeError.disconnected)
        runtimeDirectoryOwner.remove()
        if shouldNotify {
            notifyTerminal(.stopped, generation: terminalGeneration)
        }
    }

    func sendDeviceReport(_ report: Data) {
        guard report.count == Project2077.reportLength else { return }
        guard let generation = authenticatedGeneration() else { return }
        enqueueJSON([
            "v": 2,
            "type": "device-report",
            "data": report.base64EncodedString(),
        ], generation: generation, requiresAuthentication: true)
    }

    func dispatch(
        _ action: BridgeAppAction,
        completion: (@Sendable (Result<Void, Error>) -> Void)? = nil
    ) {
        writeLock.lock()
        guard clientFD >= 0, clientAuthenticated else {
            writeLock.unlock()
            completion?(.failure(BridgeError.disconnected))
            return
        }
        let generation = clientGeneration
        actionLock.lock()
        let id = nextActionID
        nextActionID += 1
        if let completion { pendingActions[id] = completion }
        actionLock.unlock()
        writeLock.unlock()

        enqueueJSON(
            action.jsonObject(id: id),
            generation: generation,
            requiresAuthentication: true
        )

        guard completion != nil else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.actionLock.lock()
            let expired = self.pendingActions.removeValue(forKey: id)
            self.actionLock.unlock()
            expired?(.failure(BridgeError.actionTimedOut))
        }
    }

    private func startOnQueue(generation: UInt64) {
        guard isLifecycleActive(generation) else { return }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            fail(
                "Не удалось создать сокет: \(Self.posixMessage())",
                activeGeneration: generation
            )
            return
        }
        stateLock.lock()
        guard
            case let .active(activeGeneration) = lifecycle,
            activeGeneration == generation
        else {
            stateLock.unlock()
            Darwin.close(fd)
            return
        }
        listenerFD = fd
        stateLock.unlock()

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            fail("Путь к Unix-сокету слишком длинный.", activeGeneration: generation)
            return
        }

        let addressLength = MemoryLayout.size(ofValue: address.sun_len)
            + MemoryLayout.size(ofValue: address.sun_family)
            + pathBytes.count
            + 1
        address.sun_len = UInt8(addressLength)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                destination[index] = byte
            }
        }

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(addressLength))
            }
        }
        guard bindResult == 0 else {
            fail(
                "Не удалось привязать сокет: \(Self.posixMessage())",
                activeGeneration: generation
            )
            return
        }
        guard chmod(socketPath, 0o600) == 0 else {
            fail(
                "Не удалось защитить сокет: \(Self.posixMessage())",
                activeGeneration: generation
            )
            return
        }
        guard Darwin.listen(fd, 1) == 0 else {
            fail(
                "Не удалось начать прослушивание сокета: \(Self.posixMessage())",
                activeGeneration: generation
            )
            return
        }
        do {
            try runtimeDirectoryOwner.publishSession(token: token)
        } catch {
            fail(
                "Не удалось опубликовать защищённый сеанс моста.",
                activeGeneration: generation
            )
            return
        }
        notifyActive(.listening)

        while isLifecycleActive(generation) {
            let accepted = Darwin.accept(fd, nil, nil)
            if accepted < 0 {
                if isLifecycleActive(generation) {
                    fail(
                        "Не удалось принять подключение: \(Self.posixMessage())",
                        activeGeneration: generation
                    )
                }
                return
            }
            handleClient(accepted)
        }
    }

    private func handleClient(_ fd: Int32) {
        var suppressSIGPIPE: Int32 = 1
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &suppressSIGPIPE,
            socklen_t(MemoryLayout<Int32>.size)
        )

        writeLock.lock()
        let previousClient = clientFD
        clientGeneration &+= 1
        let generation = clientGeneration
        clientFD = fd
        clientAuthenticated = false
        writeLock.unlock()
        if previousClient >= 0 {
            Darwin.shutdown(previousClient, SHUT_RDWR)
            Darwin.close(previousClient)
        }

        var receiveBuffer = Data()
        var authenticated = false
        var terminateConnection = false
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)

        while !isStopped, !terminateConnection {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count <= 0 { break }
            receiveBuffer.append(bytes, count: count)
            if receiveBuffer.count > BridgeWireCodec.maximumReceiveBufferBytes {
                _ = sendJSONSynchronously(
                    ["v": 2, "type": "error", "message": "Буфер приёма моста превысил 1 МиБ."],
                    generation: generation,
                    requiresAuthentication: authenticated
                )
                break
            }

            while let newline = receiveBuffer.firstIndex(of: 0x0A) {
                let line = Data(receiveBuffer[..<newline])
                receiveBuffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let envelope = BridgeWireCodec.decodeEnvelope(line) else {
                    _ = sendJSONSynchronously(
                        ["v": 2, "type": "error", "message": "Некорректное сообщение моста."],
                        generation: generation,
                        requiresAuthentication: authenticated
                    )
                    if !authenticated {
                        terminateConnection = true
                        break
                    }
                    continue
                }
                let object = envelope.object
                let type = envelope.type

                if !authenticated {
                    guard
                        type == "hello",
                        object["role"] as? String == "node-hid-shim",
                        object["token"] as? String == token
                    else {
                        _ = sendJSONSynchronously(
                            ["v": 2, "type": "error", "message": "Не удалось пройти аутентификацию моста."],
                            generation: generation,
                            requiresAuthentication: false
                        )
                        terminateConnection = true
                        break
                    }
                    guard sendJSONSynchronously([
                        "v": 2,
                        "type": "hello-ack",
                        "token": token,
                        "capabilities": [
                            "project2077",
                            "app-actions",
                            "skills",
                            "plugin-prompts",
                            "task-slot-metadata",
                        ],
                    ], generation: generation, requiresAuthentication: false) else {
                        terminateConnection = true
                        break
                    }
                    writeLock.lock()
                    let stillCurrent = clientFD == fd && clientGeneration == generation
                    if stillCurrent { clientAuthenticated = true }
                    writeLock.unlock()
                    guard stillCurrent else {
                        terminateConnection = true
                        break
                    }
                    authenticated = true
                    notifyActive(.connected)
                    continue
                }

                handleAuthenticatedMessage(type: type, object: object, generation: generation)
            }
        }

        writeLock.lock()
        let stillOwnsDescriptor = clientFD == fd && clientGeneration == generation
        if stillOwnsDescriptor {
            clientFD = -1
            clientAuthenticated = false
            clientGeneration &+= 1
        }
        writeLock.unlock()
        if stillOwnsDescriptor {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            failPendingActions(with: BridgeError.disconnected)
            notifyActive(.listening)
        }
    }

    private func handleAuthenticatedMessage(
        type: String,
        object: [String: Any],
        generation: UInt64
    ) {
        switch type {
        case "host-report":
            guard let report = BridgeWireCodec.hostReport(from: object) else {
                enqueueJSON(
                    ["v": 2, "type": "error", "message": "Некорректный отчёт хоста Project2077."],
                    generation: generation,
                    requiresAuthentication: true
                )
                return
            }
            let handler = onHostReport
            handler?(report)
        case "app-action-result":
            guard let id = (object["id"] as? NSNumber)?.intValue else { return }
            actionLock.lock()
            let completion = pendingActions.removeValue(forKey: id)
            actionLock.unlock()
            if object["ok"] as? Bool == true {
                completion?(.success(()))
            } else {
                let message = object["error"] as? String ?? "ChatGPT отклонил действие."
                completion?(.failure(BridgeError.actionFailed(message)))
            }
        case "capabilities":
            guard let capabilities = BridgeWireCodec.capabilities(from: object) else {
                enqueueJSON(
                    ["v": 2, "type": "error", "message": "Некорректный манифест возможностей."],
                    generation: generation,
                    requiresAuthentication: true
                )
                return
            }
            onCapabilities?(capabilities)
        case "runtime-state":
            guard let state = BridgeWireCodec.runtimeState(from: object) else { return }
            onRuntimeState?(state)
        case "task-slots":
            guard let slots = BridgeWireCodec.taskSlots(from: object) else {
                enqueueJSON(
                    ["v": 2, "type": "error", "message": "Некорректное состояние задач Codex."],
                    generation: generation,
                    requiresAuthentication: true
                )
                return
            }
            onTaskSlots?(slots)
        default:
            enqueueJSON(
                ["v": 2, "type": "error", "message": "Неожиданное сообщение моста: \(type)"],
                generation: generation,
                requiresAuthentication: true
            )
        }
    }

    private func enqueueJSON(
        _ object: [String: Any],
        generation: UInt64,
        requiresAuthentication: Bool
    ) {
        guard let data = BridgeWireCodec.serialize(object) else { return }
        writerQueue.async { [weak self] in
            guard let self else { return }
            guard let descriptor = self.duplicateClientDescriptor(
                generation: generation,
                requiresAuthentication: requiresAuthentication
            ) else { return }
            defer { Darwin.close(descriptor) }
            guard Self.write(data, to: descriptor, timeoutMilliseconds: 250) else {
                self.disconnectClient(afterWriteFailureFor: generation)
                return
            }
        }
    }

    @discardableResult
    private func sendJSONSynchronously(
        _ object: [String: Any],
        generation: UInt64,
        requiresAuthentication: Bool
    ) -> Bool {
        guard let data = BridgeWireCodec.serialize(object) else { return false }
        guard let descriptor = duplicateClientDescriptor(
            generation: generation,
            requiresAuthentication: requiresAuthentication
        ) else { return false }
        defer { Darwin.close(descriptor) }
        return Self.write(data, to: descriptor, timeoutMilliseconds: 250)
    }

    private func duplicateClientDescriptor(
        generation: UInt64,
        requiresAuthentication: Bool
    ) -> Int32? {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard
            clientFD >= 0,
            clientGeneration == generation,
            !requiresAuthentication || clientAuthenticated
        else { return nil }
        let descriptor = Darwin.dup(clientFD)
        return descriptor >= 0 ? descriptor : nil
    }

    private static func write(
        _ data: Data,
        to descriptor: Int32,
        timeoutMilliseconds: UInt64
    ) -> Bool {
        let timeoutNanoseconds = timeoutMilliseconds * 1_000_000
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = now.addingReportingOverflow(timeoutNanoseconds)
        guard !deadline.overflow else { return false }

        return data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return true }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let current = DispatchTime.now().uptimeNanoseconds
                guard current < deadline.partialValue else { return false }
                let remainingNanoseconds = deadline.partialValue - current
                let remainingMilliseconds = max(
                    UInt64(1),
                    (remainingNanoseconds + 999_999) / 1_000_000
                )
                var writable = pollfd(
                    fd: descriptor,
                    events: Int16(POLLOUT),
                    revents: 0
                )
                let pollResult = Darwin.poll(
                    &writable,
                    1,
                    Int32(min(remainingMilliseconds, UInt64(Int32.max)))
                )
                if pollResult < 0, errno == EINTR { continue }
                guard pollResult > 0 else { return false }

                let written = Darwin.send(descriptor, pointer, remaining, MSG_DONTWAIT)
                if written < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                guard written > 0 else { return false }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
            return true
        }
    }

    private func disconnectClient(afterWriteFailureFor generation: UInt64) {
        writeLock.lock()
        guard clientFD >= 0, clientGeneration == generation else {
            writeLock.unlock()
            return
        }
        let descriptor = clientFD
        clientFD = -1
        clientAuthenticated = false
        clientGeneration &+= 1
        writeLock.unlock()

        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        failPendingActions(with: BridgeError.disconnected)
        notifyActive(.listening)
    }

    private func fail(_ message: String, activeGeneration: UInt64) {
        stateLock.lock()
        guard
            case let .active(currentGeneration) = lifecycle,
            currentGeneration == activeGeneration
        else {
            stateLock.unlock()
            return
        }
        lifecycleGeneration &+= 1
        let terminalGeneration = lifecycleGeneration
        lifecycle = .stopped(terminalGeneration)
        let activeListener = listenerFD
        listenerFD = -1
        stateLock.unlock()

        writeLock.lock()
        let activeClient = clientFD
        clientFD = -1
        clientAuthenticated = false
        clientGeneration &+= 1
        writeLock.unlock()
        if activeClient >= 0 {
            Darwin.shutdown(activeClient, SHUT_RDWR)
            Darwin.close(activeClient)
        }
        if activeListener >= 0 {
            Darwin.shutdown(activeListener, SHUT_RDWR)
            Darwin.close(activeListener)
        }
        failPendingActions(with: BridgeError.disconnected)
        runtimeDirectoryOwner.remove()
        notifyTerminal(.failed(message), generation: terminalGeneration)
    }

    private func notifyActive(_ status: BridgeStatus) {
        guard let generation = activeLifecycleGeneration else { return }
        statusQueue.async { [weak self] in
            guard let self, self.isLifecycleActive(generation) else { return }
            self.onStatus?(status)
        }
    }

    private func notifyTerminal(_ status: BridgeStatus, generation: UInt64) {
        statusQueue.async { [weak self] in
            guard let self, self.isLifecycleStopped(generation) else { return }
            self.onStatus?(status)
        }
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private var activeLifecycleGeneration: UInt64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard case let .active(generation) = lifecycle else { return nil }
        return generation
    }

    private var isStopped: Bool {
        activeLifecycleGeneration == nil
    }

    private func isLifecycleActive(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard case let .active(current) = lifecycle else { return false }
        return current == generation
    }

    private func isLifecycleStopped(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard case let .stopped(current) = lifecycle else { return false }
        return current == generation
    }

    private func authenticatedGeneration() -> UInt64? {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard clientFD >= 0, clientAuthenticated else { return nil }
        return clientGeneration
    }

    private func failPendingActions(with error: Error) {
        actionLock.lock()
        let callbacks = Array(pendingActions.values)
        pendingActions.removeAll()
        actionLock.unlock()
        callbacks.forEach { $0(.failure(error)) }
    }

    private static func posixMessage() -> String {
        String(cString: strerror(errno))
    }
}

enum BridgeError: LocalizedError {
    case disconnected
    case actionTimedOut
    case actionFailed(String)

    var errorDescription: String? {
        switch self {
        case .disconnected: "Мост ChatGPT отключён."
        case .actionTimedOut: "ChatGPT не подтвердил действие в течение 5 секунд."
        case let .actionFailed(message): message
        }
    }
}
