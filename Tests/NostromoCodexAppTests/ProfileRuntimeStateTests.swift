import Foundation
@testable import NostromoCodexApp
import NostromoCodexCore
import XCTest

final class ProfileRuntimeStateTests: XCTestCase {
    func testOverlappingMomentaryProfilesRestorePersistentBaseOutOfOrder() {
        let persistent = UUID()
        let second = UUID()
        let third = UUID()
        var state = ProfileRuntimeState(persistentProfileID: persistent)

        XCTAssertEqual(state.beginMomentary(control: .key01, target: second), second)
        XCTAssertEqual(state.beginMomentary(control: .key02, target: third), third)
        XCTAssertNil(state.releaseMomentary(control: .key01))
        XCTAssertEqual(state.releaseMomentary(control: .key02), persistent)
        XCTAssertEqual(state.persistentProfileID, persistent)
    }

    func testTopmostReleaseRevealsPreviousMomentaryProfile() {
        let persistent = UUID()
        let second = UUID()
        let third = UUID()
        var state = ProfileRuntimeState(persistentProfileID: persistent)

        state.beginMomentary(control: .key01, target: second)
        state.beginMomentary(control: .key02, target: third)

        XCTAssertEqual(state.releaseMomentary(control: .key02), second)
        XCTAssertEqual(state.releaseMomentary(control: .key01), persistent)
    }

    func testPersistentSelectionClearsTransientStackAndControlsSnapshot() {
        let original = AppConfiguration.defaults()
        let second = ControllerProfile(name: "Second", bindings: [:])
        var configuration = original
        configuration.profiles.append(second)
        configuration.activeProfileID = second.id
        var state = ProfileRuntimeState(persistentProfileID: original.activeProfileID)
        state.beginMomentary(control: .key01, target: second.id)

        XCTAssertEqual(
            state.persistedSnapshot(of: configuration).activeProfileID,
            original.activeProfileID
        )

        state.selectPersistent(second.id)
        XCTAssertEqual(state.persistentProfileID, second.id)
        XCTAssertNil(state.releaseMomentary(control: .key01))
        XCTAssertEqual(state.persistedSnapshot(of: configuration).activeProfileID, second.id)
    }
}
