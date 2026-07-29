import Foundation
@testable import NostromoCodexCore
import XCTest

final class ConfigurationRobustnessTests: XCTestCase {
    func testMissingConfigurationReturnsCompleteDefaults() throws {
        let fixture = try TemporaryConfigurationFixture()
        let configuration = try fixture.store.load()

        XCTAssertEqual(configuration.version, 1)
        XCTAssertEqual(configuration.profiles.count, 1)
        XCTAssertEqual(configuration.activeProfileID, configuration.profiles[0].id)
        XCTAssertFalse(configuration.forceUnsupportedChatGPT)
        XCTAssertEqual(configuration.calibration.dpadDirections.count, DPadDirection.allCases.count)

        let expectedBindings: [ControlID: BindingAction] = [
            .key01: .taskSlot(3),
            .key02: .taskSlot(2),
            .key03: .taskSlot(1),
            .key04: .taskSlot(0),
            .key05: .codexAction("newTask"),
            .key06: .taskSlot(4),
            .key07: .taskSlot(5),
            .key08: .codexAction("previousThread"),
            .key09: .codexAction("nextThread"),
            .key10: .codexAction("composer.toggleChatWorkMode"),
            .key11: .codexAction("composer.togglePlanMode"),
            .key12: .codexAction("composer.stop"),
            .key13: .codexAction("approval.approve"),
            .key14: .codexAction("composer.submit"),
            .key15: .codexAction("pushToTalk"),
            .key16: .codexAction("focusChatGPT"),
            .dpadUp: .none,
            .dpadUpRight: .none,
            .dpadRight: .none,
            .dpadDownRight: .none,
            .dpadDown: .none,
            .dpadDownLeft: .none,
            .dpadLeft: .none,
            .dpadUpLeft: .none,
            .wheelPress: .none,
        ]
        XCTAssertEqual(configuration.profiles[0].bindings, expectedBindings)
    }

    func testFactoryCalibrationCoversEveryPhysicalControlExactlyOnce() {
        let calibration = CalibrationMap.nostromoFactory
        let expectedButtonControls = Set(ControlID.keypad + [.wheelPress])
        let portableSignatures = calibration.signatures.values.map(\.portableKey)

        XCTAssertEqual(Set(calibration.signatures.keys), expectedButtonControls)
        XCTAssertEqual(Set(portableSignatures).count, portableSignatures.count)
        XCTAssertEqual(Set(calibration.dpadDirections.keys), Set(DPadDirection.allCases))
        XCTAssertEqual(Set(calibration.dpadDirections.values), Set(ControlID.dpad))
        XCTAssertEqual(
            expectedButtonControls.union(calibration.dpadDirections.values),
            Set(ControlID.allCases)
        )
    }

    func testAllBindingVariantsRoundTripIndividually() throws {
        let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let actions: [BindingAction] = [
            .taskSlot(0),
            .taskSlot(5),
            .taskSlot(Int.max),
            .codexAction("composer.togglePlanMode"),
            .codexAction("vendor.future.action"),
            .skill(
                SkillReference(
                    name: "meeting-notes",
                    displayName: "Meeting notes",
                    path: "/Users/test/.codex/skills/meeting/SKILL.md",
                    enabled: true
                )
            ),
            .skill(
                SkillReference(
                    name: "disabled",
                    displayName: "Disabled",
                    path: "/tmp/disabled/SKILL.md",
                    enabled: false
                )
            ),
            .pluginPrompt(
                PluginPrompt(
                    uri: "plugin://calendar/id?scope=read",
                    displayName: "Calendar",
                    template: "Найди свободное окно"
                )
            ),
            .shortcut(
                ShortcutBinding(
                    keyCode: UInt16.max,
                    command: true,
                    option: true,
                    control: true,
                    shift: true
                )
            ),
            .profileSwitch(profileID: profileID, behavior: .toggle),
            .profileSwitch(profileID: profileID, behavior: .momentary),
            .profileSwitch(profileID: nil, behavior: .toggle),
            .profileSwitch(profileID: nil, behavior: .momentary),
            .none,
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for action in actions {
            let decoded = try decoder.decode(BindingAction.self, from: encoder.encode(action))
            XCTAssertEqual(decoded, action)
            XCTAssertEqual(decoded.kind, action.kind)
        }
        XCTAssertEqual(Set(actions.map(\.kind)), Set(BindingKind.allCases))
    }

    func testSaveOverwriteExportAndImportRoundTrip() throws {
        let fixture = try TemporaryConfigurationFixture()
        let first = AppConfiguration.defaults()
        try fixture.store.save(first)

        var second = first
        second.forceUnsupportedChatGPT = true
        second.profiles[0].name = "Plugins"
        second.profiles[0].bindings[.wheelPress] = .profileSwitch(profileID: nil, behavior: .toggle)
        try fixture.store.save(second)

        let loaded = try fixture.store.load()
        XCTAssertTrue(loaded.forceUnsupportedChatGPT)
        XCTAssertEqual(loaded.profiles[0].name, "Plugins")
        XCTAssertEqual(
            loaded.profiles[0].bindings[.wheelPress],
            .profileSwitch(profileID: nil, behavior: .toggle)
        )

        let exported = fixture.directory.appendingPathComponent("exported.json")
        try fixture.store.export(loaded, to: exported)
        let imported = try fixture.store.importConfiguration(from: exported)
        XCTAssertEqual(imported.activeProfileID, loaded.activeProfileID)
        XCTAssertEqual(imported.profiles, loaded.profiles)
        XCTAssertEqual(imported.calibration, loaded.calibration)
        XCTAssertEqual(imported.forceUnsupportedChatGPT, loaded.forceUnsupportedChatGPT)
    }

    func testMalformedAndTruncatedConfigurationFilesThrow() throws {
        let malformedDocuments: [Data] = [
            Data(),
            Data("{".utf8),
            Data("null".utf8),
            Data("[]".utf8),
            Data("{}".utf8),
            Data(#"{"version":"one"}"#.utf8),
            Data(#"{"version":1,"activeProfileID":"not-a-uuid","profiles":[]}"#.utf8),
            Data([0xFF, 0xFE, 0xFD]),
        ]

        for (index, document) in malformedDocuments.enumerated() {
            let fixture = try TemporaryConfigurationFixture()
            try FileManager.default.createDirectory(
                at: fixture.store.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try document.write(to: fixture.store.fileURL)
            XCTAssertThrowsError(try fixture.store.load(), "document \(index)")
        }
    }

    func testImportRejectsUnsupportedVersionAndEmptyProfiles() throws {
        let unsupported = try TemporaryConfigurationFixture()
        var versionTwo = AppConfiguration.defaults()
        versionTwo.version = 2
        try writeUnvalidated(versionTwo, to: unsupported.store.fileURL)
        XCTAssertThrowsError(try unsupported.store.importConfiguration(from: unsupported.store.fileURL)) {
            XCTAssertTrue($0 is ConfigurationError)
        }

        let empty = try TemporaryConfigurationFixture()
        let defaults = AppConfiguration.defaults()
        let emptyProfiles = AppConfiguration(
            activeProfileID: defaults.activeProfileID,
            profiles: []
        )
        try writeUnvalidated(emptyProfiles, to: empty.store.fileURL)
        XCTAssertThrowsError(try empty.store.importConfiguration(from: empty.store.fileURL)) {
            XCTAssertTrue($0 is ConfigurationError)
        }
    }

    func testLoadAndImportRejectInvalidActiveOrDuplicateProfileIDs() throws {
        let defaults = AppConfiguration.defaults()

        let invalidActive = try TemporaryConfigurationFixture()
        var mismatched = defaults
        mismatched.activeProfileID = UUID()
        try writeUnvalidated(mismatched, to: invalidActive.store.fileURL)
        XCTAssertThrowsError(try invalidActive.store.load()) {
            XCTAssertTrue($0 is ConfigurationError)
        }
        XCTAssertThrowsError(try invalidActive.store.importConfiguration(from: invalidActive.store.fileURL)) {
            XCTAssertTrue($0 is ConfigurationError)
        }

        let duplicateIDs = try TemporaryConfigurationFixture()
        var duplicated = defaults
        duplicated.profiles.append(
            ControllerProfile(
                id: duplicated.profiles[0].id,
                name: "Duplicate",
                bindings: [:]
            )
        )
        try writeUnvalidated(duplicated, to: duplicateIDs.store.fileURL)
        XCTAssertThrowsError(try duplicateIDs.store.load()) {
            XCTAssertTrue($0 is ConfigurationError)
        }
    }

    func testStoreRejectsAmbiguousOrDangerousInputMappingsAndBindingRanges() throws {
        let fixture = try TemporaryConfigurationFixture()
        let defaults = AppConfiguration.defaults()

        var keypadMappedAsDPad = defaults
        keypadMappedAsDPad.calibration.dpadDirections[.up] = .key10
        XCTAssertThrowsError(try fixture.store.save(keypadMappedAsDPad))

        var duplicateSignature = defaults
        duplicateSignature.calibration.signatures[.key02] =
            duplicateSignature.calibration.signatures[.key01]
        XCTAssertThrowsError(try fixture.store.save(duplicateSignature))

        var axisSignature = defaults
        axisSignature.calibration.signatures[.key01] = HIDSignature(
            usagePage: 1,
            usage: 48,
            cookie: 1,
            kind: .axis
        )
        XCTAssertThrowsError(try fixture.store.save(axisSignature))

        var invalidSlot = defaults
        invalidSlot.profiles[0].bindings[.key01] = .taskSlot(Int.max)
        XCTAssertThrowsError(try fixture.store.save(invalidSlot))

        var invalidShortcut = defaults
        invalidShortcut.profiles[0].bindings[.key01] =
            .shortcut(ShortcutBinding(keyCode: 128))
        XCTAssertThrowsError(try fixture.store.save(invalidShortcut))

        var invalidMaximumBrightness = defaults
        invalidMaximumBrightness.lighting.maximumBrightness = 1.01
        XCTAssertThrowsError(try fixture.store.save(invalidMaximumBrightness))

        var invalidPressStrength = defaults
        invalidPressStrength.lighting.pressFeedbackStrength = -0.01
        XCTAssertThrowsError(try fixture.store.save(invalidPressStrength))
    }

    func testLegacyConfigurationWithoutDPadDirectionsMigratesOnLoad() throws {
        let fixture = try TemporaryConfigurationFixture()
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(AppConfiguration.defaults()))
                as? [String: Any]
        )
        var calibration = try XCTUnwrap(object["calibration"] as? [String: Any])
        calibration.removeValue(forKey: "dpadDirections")
        object["calibration"] = calibration
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        try FileManager.default.createDirectory(
            at: fixture.store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try legacyData.write(to: fixture.store.fileURL)

        let migrated = try fixture.store.load()
        XCTAssertEqual(migrated.calibration.dpadDirections.count, 8)
        for direction in DPadDirection.allCases {
            XCTAssertEqual(migrated.calibration.control(for: direction), direction.controlID)
        }
    }

    func testLegacyConfigurationWithoutAdditiveExpertFlagUsesSafeDefault() throws {
        let fixture = try TemporaryConfigurationFixture()
        let original = AppConfiguration.defaults()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
                as? [String: Any]
        )
        object.removeValue(forKey: "forceUnsupportedChatGPT")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        try FileManager.default.createDirectory(
            at: fixture.store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try legacyData.write(to: fixture.store.fileURL)

        let migrated = try fixture.store.load()
        XCTAssertFalse(migrated.forceUnsupportedChatGPT)
        XCTAssertEqual(migrated.version, 1)
        XCTAssertEqual(migrated.profiles, original.profiles)
    }

    func testDecoderIgnoresUnknownForwardCompatibleFields() throws {
        let fixture = try TemporaryConfigurationFixture()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfiguration.defaults()))
                as? [String: Any]
        )
        object["futureRootField"] = ["feature": true]
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        profiles[0]["futureProfileField"] = 2077
        object["profiles"] = profiles
        let data = try JSONSerialization.data(withJSONObject: object)
        try FileManager.default.createDirectory(
            at: fixture.store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fixture.store.fileURL)

        let loaded = try fixture.store.load()
        XCTAssertEqual(loaded.version, 1)
        XCTAssertEqual(loaded.profiles.count, 1)
    }

    func testCalibrationMatchesPortableFieldsAndIgnoresCookie() {
        let stored = HIDSignature(usagePage: 7, usage: 44, cookie: 10, kind: .button)
        let calibration = CalibrationMap(signatures: [.key15: stored])

        XCTAssertEqual(
            calibration.control(
                for: HIDSignature(usagePage: 7, usage: 44, cookie: 9_999, kind: .button)
            ),
            .key15
        )
        XCTAssertNil(
            calibration.control(
                for: HIDSignature(usagePage: 7, usage: 44, cookie: 10, kind: .axis)
            )
        )
        XCTAssertNil(
            calibration.control(
                for: HIDSignature(usagePage: 9, usage: 44, cookie: 10, kind: .button)
            )
        )
        XCTAssertEqual(stored.portableKey, "7:44:button")
    }

    func testPluginPromptTrimsTemplateEdgesWithoutImplicitSubmit() {
        let emptyTemplates = ["", " ", "\n\t"]
        for template in emptyTemplates {
            let prompt = PluginPrompt(uri: "plugin://example", displayName: "Example", template: template)
            XCTAssertEqual(prompt.composerText, "[@Example](plugin://example) ")
            XCTAssertFalse(prompt.composerText.contains("\n"))
        }

        let prompt = PluginPrompt(
            uri: "plugin://example",
            displayName: "Example",
            template: "\n  Подготовь отчёт  \t"
        )
        XCTAssertEqual(prompt.composerText, "[@Example](plugin://example) Подготовь отчёт")
        XCTAssertFalse(prompt.composerText.hasSuffix("\n"))
    }

    private func writeUnvalidated(_ configuration: AppConfiguration, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(configuration).write(to: url)
    }
}

private final class TemporaryConfigurationFixture {
    let directory: URL
    let store: ConfigurationStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nostromo-config-tests-\(UUID().uuidString)", isDirectory: true)
        store = ConfigurationStore(fileURL: directory.appendingPathComponent("nested/profiles.json"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
