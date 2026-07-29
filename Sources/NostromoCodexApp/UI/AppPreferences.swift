import Combine
import Foundation

@MainActor
final class AppPreferences: ObservableObject {
    private enum Key {
        static let setupVersion = "ux.setupVersion"
        static let autoLaunchChatGPT = "ux.autoLaunchChatGPT"
        static let showRuntimeHUD = "ux.showRuntimeHUD"
        static let initialized = "ux.initialized"
    }

    private let defaults: UserDefaults
    let shouldAdoptStoredConfiguration: Bool

    @Published var setupCompleted: Bool {
        didSet {
            defaults.set(setupCompleted ? 1 : 0, forKey: Key.setupVersion)
        }
    }

    @Published var autoLaunchChatGPT: Bool {
        didSet {
            defaults.set(autoLaunchChatGPT, forKey: Key.autoLaunchChatGPT)
        }
    }

    @Published var showRuntimeHUD: Bool {
        didSet {
            defaults.set(showRuntimeHUD, forKey: Key.showRuntimeHUD)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shouldAdoptStoredConfiguration = !defaults.bool(forKey: Key.initialized)
        setupCompleted = defaults.integer(forKey: Key.setupVersion) >= 1
        autoLaunchChatGPT = defaults.object(forKey: Key.autoLaunchChatGPT) as? Bool ?? false
        showRuntimeHUD = defaults.object(forKey: Key.showRuntimeHUD) as? Bool ?? true
        defaults.set(true, forKey: Key.initialized)
    }

    static func ephemeral() -> AppPreferences {
        let suite = "io.nostromo-codex.ephemeral.\(UUID().uuidString)"
        return AppPreferences(defaults: UserDefaults(suiteName: suite)!)
    }

    func markSetupCompleted(autoLaunch: Bool) {
        autoLaunchChatGPT = autoLaunch
        setupCompleted = true
    }

    func resetSetup() {
        setupCompleted = false
    }
}
