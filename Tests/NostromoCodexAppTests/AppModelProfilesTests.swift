import Foundation
@testable import NostromoCodexApp
import NostromoCodexCore
import SwiftUI
import XCTest

@MainActor
final class AppModelProfilesTests: AppModelTestCase {
    func testClearingActiveProfileRemovesEveryAssignmentAndPersistsBlankLayout() throws {
        let fixture = makeFixture()
        let model = fixture.model
        let untouchedProfile = ControllerProfile(
            name: "Отдельный профиль",
            bindings: [.key01: .codexAction("composer.submit")]
        )
        model.configuration.profiles.append(untouchedProfile)

        model.clearActiveProfileBindings()

        XCTAssertEqual(Set(model.activeProfile.bindings.keys), Set(ControlID.allCases))
        XCTAssertTrue(model.activeProfile.bindings.values.allSatisfy { $0 == .none })
        XCTAssertEqual(
            model.configuration.profiles.first(where: { $0.id == untouchedProfile.id })?.bindings[.key01],
            .codexAction("composer.submit")
        )

        let persisted = try fixture.model.store.load()
        let persistedActiveProfile = try XCTUnwrap(
            persisted.profiles.first(where: { $0.id == persisted.activeProfileID })
        )
        XCTAssertEqual(Set(persistedActiveProfile.bindings.keys), Set(ControlID.allCases))
        XCTAssertTrue(persistedActiveProfile.bindings.values.allSatisfy { $0 == .none })
    }

    func testMomentaryProfileReturnsUsingPressedActionFromOriginalProfile() async {
        let fixture = makeFixture()
        let model = fixture.model
        let originalID = model.configuration.activeProfileID
        let target = ControllerProfile(name: "Momentary", bindings: [.key01: .none])
        model.configuration.profiles.append(target)
        model.setBinding(.profileSwitch(profileID: target.id, behavior: .momentary), for: .key01)

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, target.id)
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, originalID)
    }

    func testOverlappingMomentaryProfilesAreRuntimeOnlyAndReleaseOutOfOrder() async throws {
        let fixture = makeFixture()
        let model = fixture.model
        let originalID = model.configuration.activeProfileID
        let second = ControllerProfile(name: "Second", bindings: [:])
        var third = ControllerProfile(name: "Third", bindings: [:])
        third.bindings[.key02] = BindingAction.none
        var secondWithBinding = second
        secondWithBinding.bindings[.key02] =
            .profileSwitch(profileID: third.id, behavior: .momentary)
        model.configuration.profiles.append(contentsOf: [secondWithBinding, third])
        model.setBinding(
            .profileSwitch(profileID: second.id, behavior: .momentary),
            for: .key01
        )

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, second.id)
        XCTAssertEqual(try fixture.model.store.load().activeProfileID, originalID)

        fixture.hid.emitButton(.key02, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, third.id)
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, third.id)
        fixture.hid.emitButton(.key02, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, originalID)
        XCTAssertEqual(try fixture.model.store.load().activeProfileID, originalID)
    }

    func testMomentaryProfileExportsPersistentBaseAndDeleteTargetsVisibleProfile() async throws {
        let fixture = makeFixture()
        let model = fixture.model
        let originalID = model.configuration.activeProfileID
        let target = ControllerProfile(name: "Visible momentary profile", bindings: [:])
        model.configuration.profiles.append(target)
        model.setBinding(
            .profileSwitch(profileID: target.id, behavior: .momentary),
            for: .key01
        )

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, target.id)
        XCTAssertEqual(model.persistedConfigurationSnapshot().activeProfileID, originalID)

        model.deleteActiveProfile()
        XCTAssertFalse(model.configuration.profiles.contains(where: { $0.id == target.id }))
        XCTAssertTrue(model.configuration.profiles.contains(where: { $0.id == originalID }))
        XCTAssertEqual(model.configuration.activeProfileID, originalID)
        XCTAssertEqual(try model.store.load().activeProfileID, originalID)

        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, originalID)
    }

    func testCorruptConfigurationIsBackedUpBeforeDefaultsAreSaved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nostromo-corrupt-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("profiles.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corruptData = Data("{truncated".utf8)
        try corruptData.write(to: fileURL)
        let store = ConfigurationStore(fileURL: fileURL)
        let bridge = FakeBridge()
        let hid = FakeHID()
        let launcher = FakeLauncher()
        let shortcutPoster = FakeShortcutPoster(access: true)
        let model = AppModel(
            store: store,
            launcher: launcher,
            hid: hid,
            bridge: bridge,
            shortcutPoster: shortcutPoster,
            keyboardSuppressor: FakeKeyboardSuppressor()
        )

        XCTAssertNotNil(model.lastError)
        model.renameActiveProfile("Recovered")
        model.renameActiveProfile("Recovered Again")

        let recovered = try store.load()
        XCTAssertEqual(recovered.profiles[0].name, "Recovered Again")
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("profiles.invalid-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first)), corruptData)
    }

    func testFailedProfileActivationNeverPublishesUnpersistedCandidate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nostromo-transaction-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("profiles.json")
        let store = ConfigurationStore(fileURL: fileURL)
        var stored = AppConfiguration.defaults()
        let second = ControllerProfile(name: "Second", bindings: [:])
        stored.profiles.append(second)
        try store.save(stored)

        let model = AppModel(
            store: store,
            launcher: FakeLauncher(),
            hid: FakeHID(),
            bridge: FakeBridge(),
            shortcutPoster: FakeShortcutPoster(access: true),
            keyboardSuppressor: FakeKeyboardSuppressor()
        )
        let originalID = model.configuration.activeProfileID

        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.removeItem(at: directory)
        try Data("not a directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        model.activateProfile(second.id)

        XCTAssertEqual(model.configuration.activeProfileID, originalID)
        XCTAssertEqual(model.persistedConfigurationSnapshot().activeProfileID, originalID)
        XCTAssertNotNil(model.lastError)
    }
}
