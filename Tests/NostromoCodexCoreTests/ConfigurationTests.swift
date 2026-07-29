import Foundation
@testable import NostromoCodexCore
import XCTest

final class ConfigurationTests: XCTestCase {
    func testEveryBindingTypeRoundTrips() throws {
        let profileID = UUID()
        let profile = ControllerProfile(id: profileID, name: "All", bindings: [
            .key01: .taskSlot(2),
            .key02: .codexAction("newTask"),
            .key03: .skill(SkillReference(name: "brief", displayName: "Brief", path: "/tmp/SKILL.md")),
            .key04: .pluginPrompt(PluginPrompt(uri: "plugin://example", displayName: "Example", template: "prepare")),
            .key05: .shortcut(ShortcutBinding(keyCode: 1, command: true, shift: true)),
            .key06: .profileSwitch(profileID: profileID, behavior: .momentary),
            .key07: .none,
        ])
        let configuration = AppConfiguration(activeProfileID: profileID, profiles: [profile])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigurationStore(fileURL: directory.appendingPathComponent("profiles.json"))

        try store.save(configuration)
        let decoded = try store.load()
        XCTAssertEqual(decoded.profiles[0], profile)
        try? FileManager.default.removeItem(at: directory)
    }

    func testPluginPromptDoesNotSubmit() {
        let prompt = PluginPrompt(
            uri: "plugin://calendar",
            displayName: "Calendar",
            template: "Найди свободное окно"
        )
        XCTAssertEqual(prompt.composerText, "[@Calendar](plugin://calendar) Найди свободное окно")
        XCTAssertFalse(prompt.composerText.contains("\n"))
    }

    func testSkillScannerReadsFrontMatterAndFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first", isDirectory: true)
        let fallback = root.appendingPathComponent("fallback-name", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        try Data("---\nname: meeting-assistant\ndescription: test\n---\n".utf8)
            .write(to: first.appendingPathComponent("SKILL.md"))
        try Data("# No front matter\n".utf8)
            .write(to: fallback.appendingPathComponent("SKILL.md"))

        let skills = SkillScanner(roots: [root]).scan()
        XCTAssertTrue(skills.contains(where: { $0.name == "meeting-assistant" }))
        XCTAssertTrue(skills.contains(where: { $0.name == "fallback-name" }))
        try? FileManager.default.removeItem(at: root)
    }

    func testLegacyCalibrationGetsDefaultEightDirectionMap() throws {
        let json = """
        {
          "signatures": []
        }
        """
        let decoded = try JSONDecoder().decode(CalibrationMap.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.dpadDirections.count, 8)
        XCTAssertEqual(decoded.control(for: .upLeft), .dpadUpLeft)
    }

    func testNextProfileBindingRoundTrips() throws {
        let action = BindingAction.profileSwitch(profileID: nil, behavior: .toggle)
        let encoded = try JSONEncoder().encode(action)
        XCTAssertEqual(try JSONDecoder().decode(BindingAction.self, from: encoded), action)
        XCTAssertEqual(BindingSummary.text(for: action), "Следующий профиль")
        XCTAssertEqual(BindingSummary.compactText(for: action), "След.пр.")
    }

    func testEveryVerifiedCodexActionHasAReadableCompactLabel() {
        let labels = CodexActionCatalog.verified.map {
            BindingSummary.compactText(for: .codexAction($0.id))
        }

        XCTAssertFalse(labels.contains("Команда"))
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty && $0.count <= 8 })
        XCTAssertEqual(Set(labels).count, labels.count)
    }

    func testCompactLabelsCoverEveryBindingKindAndBoundLongReferences() {
        let longSkill = SkillReference(
            name: "release-readiness",
            displayName: "Очень длинное имя навыка",
            path: "/tmp/SKILL.md"
        )
        let longPlugin = PluginPrompt(
            uri: "plugin://release",
            displayName: "Очень длинное имя плагина"
        )
        let actions: [BindingAction] = [
            .taskSlot(5),
            .codexAction("composer.togglePlanMode"),
            .skill(longSkill),
            .pluginPrompt(longPlugin),
            .shortcut(ShortcutBinding(keyCode: 1, command: true, shift: true)),
            .profileSwitch(profileID: UUID(), behavior: .momentary),
            .none,
        ]

        let labels = actions.map(BindingSummary.compactText(for:))

        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty && $0.count <= 8 })
        XCTAssertEqual(labels[2], "$Очень")
        XCTAssertEqual(labels[3], "@Очень")
        XCTAssertEqual(labels[6], "—")
    }

    func testPreImportBackupPreservesCurrentConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigurationStore(fileURL: root.appendingPathComponent("profiles.json"))
        var configuration = AppConfiguration.defaults()
        configuration.profiles[0].name = "Before import"

        let backup = try store.backup(configuration, label: "before-import")
        let recovered = try store.importConfiguration(from: backup)

        XCTAssertEqual(recovered.profiles[0].name, "Before import")
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("profiles.before-import-"))
        try? FileManager.default.removeItem(at: root)
    }
}
