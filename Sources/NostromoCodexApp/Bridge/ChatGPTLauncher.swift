import AppKit
import Foundation

struct ChatGPTCompatibility: Equatable {
    var version: String
    var build: String
    var supported: Bool
    var requiredModulesPresent: Bool = true
    var reason: String?
}

/// `applicationLock` owns the only mutable cross-task reference. All other
/// state is immutable filesystem/application metadata.
final class ChatGPTLauncher: @unchecked Sendable {
    static let bundleURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
    static let executableURL = bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT")
    static let bundleIdentifier = "com.openai.codex"
    static let supportedBuilds: Set<String> = ["5848", "5973"]

    private let applicationLock = NSLock()
    private var launchedApplication: NSRunningApplication?

    func compatibility() -> ChatGPTCompatibility {
        let plistURL = Self.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard
            let dictionary = NSDictionary(contentsOf: plistURL) as? [String: Any],
            let version = dictionary["CFBundleShortVersionString"] as? String,
            let build = dictionary["CFBundleVersion"] as? String
        else {
            return ChatGPTCompatibility(
                version: "Не установлен",
                build: "—",
                supported: false,
                requiredModulesPresent: false,
                reason: "ChatGPT не найден в папке /Applications."
            )
        }
        let requiredPaths = [
            Self.executableURL,
            Self.bundleURL.appendingPathComponent("Contents/Resources/app.asar"),
            Self.bundleURL.appendingPathComponent("Contents/Resources/native/hid-topology-watcher.node"),
            Self.bundleURL.appendingPathComponent(
                "Contents/Resources/app.asar.unpacked/node_modules/@worklouder/device-kit-oai"
            ),
        ]
        let missingModule = requiredPaths.first(where: {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        let appArchive = Self.bundleURL.appendingPathComponent("Contents/Resources/app.asar")
        let adapterShapeVerified = (try? Data(contentsOf: appArchive, options: [.mappedIfSafe]))
            .map(Self.validateAdapterShape(in:)) ?? false
        let supported = Self.supportedBuilds.contains(build)
            && missingModule == nil
            && adapterShapeVerified
        let reason: String?
        if let missingModule {
            reason = "Отсутствует необходимый модуль ChatGPT: \(missingModule.lastPathComponent)."
        } else if !adapterShapeVerified {
            reason = "Отсутствуют необходимые API интерфейса ChatGPT или Codex app-server."
        } else if !Self.supportedBuilds.contains(build) {
            reason = "Эта сборка ChatGPT не проверена для работы с приватным мостом."
        } else {
            reason = nil
        }
        return ChatGPTCompatibility(
            version: version,
            build: build,
            supported: supported,
            requiredModulesPresent: missingModule == nil && adapterShapeVerified,
            reason: reason
        )
    }

    static func validateAdapterShape(in archive: Data) -> Bool {
        let markers = [
            "codex_desktop:message-for-view",
            "codex-micro-service-",
            "composer.submit",
            "data-codex-composer-root",
            "M4.5 5.75C4.5 5.05964 5.05964 4.5",
            "size-token-button-composer",
            "skills/list",
        ]
        return markers.allSatisfy { marker in
            archive.range(of: Data(marker.utf8)) != nil
        }
    }

    func runningApplications() -> [NSRunningApplication] {
        var applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        )
        if let launchedApplication = applicationLock.withLock({ self.launchedApplication }),
           !launchedApplication.isTerminated,
           !applications.contains(where: { $0.processIdentifier == launchedApplication.processIdentifier })
        {
            applications.append(launchedApplication)
        }
        return applications
    }

    func isRunning() -> Bool {
        !runningApplications().isEmpty
    }

    func isActive() -> Bool {
        runningApplications().contains(where: \.isActive)
    }

    @discardableResult
    func activate() -> Bool {
        guard let application = runningApplications().first else { return false }
        application.unhide()
        return application.activate(options: [.activateAllWindows])
    }

    func launch(
        preloadURL: URL,
        socketPath: String,
        sessionDescriptorPath: String,
        token: String,
        forceUnsupported: Bool
    ) async throws {
        let compatibility = compatibility()
        try Self.validateCompatibility(compatibility, forceUnsupported: forceUnsupported)
        guard FileManager.default.isExecutableFile(atPath: Self.executableURL.path) else {
            throw LaunchError.executableMissing
        }
        guard FileManager.default.fileExists(atPath: preloadURL.path) else {
            throw LaunchError.preloadMissing
        }
        guard !isRunning() else {
            throw LaunchError.alreadyRunning
        }

        var environment = ProcessInfo.processInfo.environment
        environment["NOSTROMO_CODEX_DISCOVERY"] = sessionDescriptorPath
        environment["NOSTROMO_CODEX_SOCKET"] = socketPath
        environment["NOSTROMO_CODEX_TOKEN"] = token
        environment["NOSTROMO_CODEX_FORCE"] = forceUnsupported ? "1" : "0"
        environment["NOSTROMO_CODEX_CHATGPT_VERSION"] = compatibility.version
        environment["NODE_OPTIONS"] = "--require=\"\(preloadURL.path.replacingOccurrences(of: "\"", with: "\\\""))\""

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.environment = environment

        let application: NSRunningApplication = try await withCheckedThrowingContinuation {
            continuation in
            NSWorkspace.shared.openApplication(
                at: Self.bundleURL,
                configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(throwing: LaunchError.launchFailed)
                }
            }
        }
        applicationLock.withLock {
            launchedApplication = application
        }
    }

    static func validateCompatibility(
        _ compatibility: ChatGPTCompatibility,
        forceUnsupported: Bool
    ) throws {
        guard compatibility.requiredModulesPresent else {
            throw LaunchError.incompleteInstallation(
                compatibility.reason ?? "Отсутствуют необходимые модули ChatGPT."
            )
        }
        guard compatibility.supported || forceUnsupported else {
            throw LaunchError.unsupportedBuild(compatibility.version, compatibility.build)
        }
    }

    func terminateRunningApplications() async {
        let applications = runningApplications()
        applications.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, isRunning() {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

enum LaunchError: LocalizedError {
    case executableMissing
    case preloadMissing
    case alreadyRunning
    case launchFailed
    case incompleteInstallation(String)
    case unsupportedBuild(String, String)

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            "Исполняемый файл ChatGPT не найден в /Applications/ChatGPT.app."
        case .preloadMissing:
            "Отсутствует встроенный preload моста Nostromo."
        case .alreadyRunning:
            "ChatGPT уже запущен. Перезапустите его через Nostromo Codex."
        case .launchFailed:
            "macOS не вернула запущенный экземпляр ChatGPT."
        case let .incompleteInstallation(reason):
            "Установка ChatGPT неполна. \(reason)"
        case let .unsupportedBuild(version, build):
            "ChatGPT \(version) (\(build)) отсутствует в списке проверенных совместимых сборок."
        }
    }
}
