import Foundation

public final class ConfigurationStore {
    public let fileURL: URL
    private let fileManager: FileManager

    public var hasStoredConfiguration: Bool {
        fileManager.fileExists(atPath: fileURL.path)
    }

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base
                .appendingPathComponent("Nostromo Codex", isDirectory: true)
                .appendingPathComponent("profiles.json")
        }
    }

    public func load() throws -> AppConfiguration {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .defaults()
        }
        let data = try Data(contentsOf: fileURL)
        let configuration = try Self.decoder.decode(AppConfiguration.self, from: data)
        try Self.validate(configuration)
        return configuration
    }

    public func save(_ configuration: AppConfiguration) throws {
        try Self.validate(configuration)
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(configuration)
        try data.write(to: fileURL, options: [.atomic])
    }

    public func export(_ configuration: AppConfiguration, to destination: URL) throws {
        try Self.validate(configuration)
        try Self.encoder.encode(configuration).write(to: destination, options: [.atomic])
    }

    public func importConfiguration(from source: URL) throws -> AppConfiguration {
        let data = try Data(contentsOf: source)
        let configuration = try Self.decoder.decode(AppConfiguration.self, from: data)
        try Self.validate(configuration)
        return configuration
    }

    public func backup(_ configuration: AppConfiguration, label: String) throws -> URL {
        try Self.validate(configuration)
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = directory.appendingPathComponent(
            "profiles.\(label)-\(UUID().uuidString).json"
        )
        try Self.encoder.encode(configuration).write(to: backup, options: [.atomic])
        return backup
    }

    public func backupInvalidConfiguration() throws -> URL? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName).invalid-\(UUID().uuidString).json")
        try fileManager.copyItem(at: fileURL, to: backup)
        return backup
    }

    private static func validate(_ configuration: AppConfiguration) throws {
        let profileIDs = configuration.profiles.map(\.id)
        guard
            configuration.version == 1,
            !profileIDs.isEmpty,
            Set(profileIDs).count == profileIDs.count,
            profileIDs.contains(configuration.activeProfileID),
            configuration.lighting.maximumBrightness.isFinite,
            (0 ... 1).contains(configuration.lighting.maximumBrightness),
            configuration.lighting.pressFeedbackStrength.isFinite,
            (0 ... 1).contains(configuration.lighting.pressFeedbackStrength)
        else {
            throw ConfigurationError.unsupportedFormat
        }

        let allowedSignatureControls = Set(ControlID.keypad + [.wheelPress])
        guard
            Set(configuration.calibration.signatures.keys).isSubset(of: allowedSignatureControls),
            configuration.calibration.signatures.values.allSatisfy({ $0.kind == .button }),
            Set(configuration.calibration.signatures.values.map(\.portableKey)).count
                == configuration.calibration.signatures.count,
            Set(configuration.calibration.dpadDirections.keys) == Set(DPadDirection.allCases),
            Set(configuration.calibration.dpadDirections.values) == Set(ControlID.dpad)
        else {
            throw ConfigurationError.unsupportedFormat
        }

        for profile in configuration.profiles {
            for action in profile.bindings.values {
                switch action {
                case let .taskSlot(slot) where !(0 ... 5).contains(slot):
                    throw ConfigurationError.unsupportedFormat
                case let .shortcut(shortcut) where shortcut.keyCode > 127:
                    throw ConfigurationError.unsupportedFormat
                default:
                    break
                }
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

public enum ConfigurationError: LocalizedError {
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "Выбранный файл не является поддерживаемым профилем Nostromo Codex."
        }
    }
}
