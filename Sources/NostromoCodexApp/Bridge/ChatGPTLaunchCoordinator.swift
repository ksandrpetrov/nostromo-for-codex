import Foundation

/// Owns a single launch/restart operation. Validation happens before this owner
/// is allowed to terminate the existing application. Shutdown is terminal.
@MainActor
final class ChatGPTLaunchCoordinator {
    struct BridgeRequest {
        let preloadURL: URL
        let socketPath: String
        let sessionDescriptorPath: String
        let token: String
        let forceUnsupported: Bool
    }

    enum Request {
        case normal
        case bridge(BridgeRequest)
        case restart(BridgeRequest)
    }

    struct Outcome {
        let needsRestart: Bool?
        let errorMessage: String?
    }

    private let launcher: any ChatGPTLaunching
    private var task: Task<Void, Never>?
    private var stopped = false
    var inProgress: Bool { task != nil }
    var onOutcome: (Outcome) -> Void = { _ in }

    init(launcher: any ChatGPTLaunching) { self.launcher = launcher }

    deinit { task?.cancel() }

    func start(_ request: Request) {
        guard !stopped, task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            guard !self.stopped, !Task.isCancelled else { return }
            let outcome = await self.perform(request)
            guard !self.stopped, !Task.isCancelled else { return }
            self.onOutcome(outcome)
        }
    }

    func stop() {
        stopped = true
        task?.cancel()
    }

    private func launchBridge(_ request: BridgeRequest) async throws {
        try await launcher.launch(
            preloadURL: request.preloadURL,
            socketPath: request.socketPath,
            sessionDescriptorPath: request.sessionDescriptorPath,
            token: request.token,
            forceUnsupported: request.forceUnsupported
        )
    }

    private func perform(_ request: Request) async -> Outcome {
        do {
            switch request {
            case .normal:
                try await launcher.launchNormally()
                return Outcome(needsRestart: true, errorMessage: nil)
            case let .bridge(request):
                try await launchBridge(request)
            case let .restart(request):
                await launcher.terminateRunningApplications()
                try Task.checkCancellation()
                guard !stopped else { throw CancellationError() }
                do {
                    try await launchBridge(request)
                } catch {
                    try Task.checkCancellation()
                    guard !stopped, !launcher.isRunning() else { throw error }
                    let bridgeError = error.localizedDescription
                    do {
                        try await launcher.launchNormally()
                        return Outcome(
                            needsRestart: true,
                            errorMessage: "ChatGPT открыт в обычном режиме. Подключение Nostromo "
                                + "не удалось: \(bridgeError)"
                        )
                    } catch {
                        return Outcome(
                            needsRestart: nil,
                            errorMessage: "Не удалось открыть ChatGPT после перезапуска: "
                                + "\(error.localizedDescription) Подключение Nostromo: \(bridgeError)"
                        )
                    }
                }
            }
            return Outcome(needsRestart: false, errorMessage: nil)
        } catch {
            return Outcome(needsRestart: nil, errorMessage: error.localizedDescription)
        }
    }
}
