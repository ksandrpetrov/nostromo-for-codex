import Foundation
@testable import NostromoCodexCore
import XCTest

final class LightingSettingsTests: XCTestCase {
    func testDefaultsPreserveLegacyLightingBehavior() {
        let settings = LightingSettings.defaults

        XCTAssertTrue(settings.keypadEnabled)
        XCTAssertEqual(settings.maximumBrightness, 1)
        XCTAssertTrue(settings.pressFeedbackEnabled)
        XCTAssertEqual(settings.pressFeedbackStrength, 1)

        let configuration = AppConfiguration.defaults()
        XCTAssertEqual(configuration.version, 1)
        XCTAssertEqual(configuration.lighting, .defaults)
    }

    func testLightingSettingsClampInitializerAndDecodedValues() throws {
        let initialized = LightingSettings(
            maximumBrightness: -2,
            pressFeedbackStrength: 9
        )
        XCTAssertEqual(initialized.maximumBrightness, 0)
        XCTAssertEqual(initialized.pressFeedbackStrength, 1)

        let decoded = try JSONDecoder().decode(
            LightingSettings.self,
            from: Data(
                """
                {
                  "keypadEnabled": false,
                  "maximumBrightness": 4.5,
                  "pressFeedbackEnabled": false,
                  "pressFeedbackStrength": -0.25
                }
                """.utf8
            )
        )
        XCTAssertFalse(decoded.keypadEnabled)
        XCTAssertEqual(decoded.maximumBrightness, 1)
        XCTAssertFalse(decoded.pressFeedbackEnabled)
        XCTAssertEqual(decoded.pressFeedbackStrength, 0)

        let partial = try JSONDecoder().decode(
            LightingSettings.self,
            from: Data(#"{"maximumBrightness":0.4}"#.utf8)
        )
        XCTAssertEqual(
            partial,
            LightingSettings(
                keypadEnabled: true,
                maximumBrightness: 0.4,
                pressFeedbackEnabled: true,
                pressFeedbackStrength: 1
            )
        )
    }

    func testLegacyConfigurationDefaultsMissingLightingAndIgnoresRemovedProfileIndicator() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfiguration.defaults()))
                as? [String: Any]
        )
        object.removeValue(forKey: "lighting")
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        profiles[0]["indicator"] = "blue"
        object["profiles"] = profiles

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.lighting, .defaults)
        let reencoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))
                as? [String: Any]
        )
        let reencodedProfiles = try XCTUnwrap(reencoded["profiles"] as? [[String: Any]])
        XCTAssertNil(reencodedProfiles[0]["indicator"])
    }

    func testLightingSettingsAndConfigurationRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let settings = LightingSettings(
            keypadEnabled: false,
            maximumBrightness: 0.37,
            pressFeedbackEnabled: false,
            pressFeedbackStrength: 0.62
        )
        XCTAssertEqual(
            try decoder.decode(LightingSettings.self, from: encoder.encode(settings)),
            settings
        )

        var configuration = AppConfiguration.defaults()
        configuration.lighting = settings
        let decodedConfiguration = try decoder.decode(
            AppConfiguration.self,
            from: encoder.encode(configuration)
        )
        XCTAssertEqual(decodedConfiguration.version, 1)
        XCTAssertEqual(decodedConfiguration.lighting, settings)
    }

    func testResolutionAppliesMinimumAndUserMaximumWithByteRounding() {
        let idle = NostromoLightingResolution.resolve(
            from: CodexLightingState(),
            indicatorState: .unavailable,
            settings: .defaults
        )
        XCTAssertEqual(idle.requestedBrightness, 0.16, accuracy: 0.000_001)
        XCTAssertEqual(idle.maximumBrightness, 1)
        XCTAssertEqual(idle.appliedBrightness, 41)
        XCTAssertEqual(idle.summary.backlightBrightness, 41)
        XCTAssertEqual(idle.summary.backlightCeiling, 255)
        XCTAssertEqual(idle.summary.red, false)
        XCTAssertEqual(idle.summary.green, false)
        XCTAssertEqual(idle.summary.blue, false)
        XCTAssertFalse(idle.taskStatusOwnsIndicators)

        var dynamic = CodexLightingState()
        dynamic.keys.brightness = 0.5
        let capped = NostromoLightingResolution.resolve(
            from: dynamic,
            indicatorState: .unavailable,
            settings: LightingSettings(maximumBrightness: 0.5)
        )
        XCTAssertEqual(capped.requestedBrightness, 0.5)
        XCTAssertEqual(capped.maximumBrightness, 0.5)
        XCTAssertEqual(capped.appliedBrightness, 64)
        XCTAssertEqual(capped.summary.backlightBrightness, 64)
        XCTAssertEqual(capped.summary.backlightCeiling, 128)
    }

    func testResolutionUsesMaximumAcrossActiveThreadsAndZonesAndClampsInputs() {
        var state = CodexLightingState()
        state.threads[0].brightness = 0.75
        state.threads[0].color = 0
        state.threads[2].brightness = 0.6
        state.threads[2].color = 0xFF0000
        state.threads[1].brightness = -5
        state.keys.brightness = 0.4
        state.ambient.brightness = 4

        var settings = LightingSettings()
        settings.maximumBrightness = 2
        let resolution = NostromoLightingResolution.resolve(
            from: state,
            indicatorState: .unavailable,
            settings: settings
        )

        XCTAssertEqual(resolution.requestedBrightness, 1)
        XCTAssertEqual(resolution.maximumBrightness, 1)
        XCTAssertEqual(resolution.appliedBrightness, 255)
        XCTAssertEqual(resolution.summary.backlightCeiling, 255)

        state.ambient.brightness = .nan
        settings.maximumBrightness = .nan
        let invalid = NostromoLightingPolicy.resolve(
            from: state,
            indicatorState: .unavailable,
            settings: settings
        )
        XCTAssertEqual(invalid.requestedBrightness, 0.6)
        XCTAssertEqual(invalid.maximumBrightness, 1)
        XCTAssertEqual(invalid.appliedBrightness, 153)
    }

    func testResolutionIgnoresInactiveAndColorlessThreadsForDynamicBrightness() {
        var state = CodexLightingState()
        state.threads[0] = ThreadLighting(
            id: 0,
            color: 0xFF0000,
            brightness: 0.01
        )
        state.threads[1] = ThreadLighting(
            id: 1,
            color: 0,
            brightness: 1
        )

        let resolution = NostromoLightingResolution.resolve(
            from: state,
            indicatorState: .unavailable,
            settings: .defaults
        )

        XCTAssertEqual(resolution.requestedBrightness, 0.16, accuracy: 0.000_001)
        XCTAssertEqual(resolution.appliedBrightness, 41)
        XCTAssertFalse(resolution.taskStatusOwnsIndicators)
    }

    func testDisabledKeypadProducesZeroBrightnessAndCeilingWithoutDisablingReadyIndicator() {
        var state = CodexLightingState()
        state.keys.brightness = 1

        let resolution = NostromoLightingResolution.resolve(
            from: state,
            indicatorState: .ready,
            settings: LightingSettings(keypadEnabled: false)
        )

        XCTAssertEqual(resolution.requestedBrightness, 1)
        XCTAssertEqual(resolution.appliedBrightness, 0)
        XCTAssertEqual(resolution.summary.backlightBrightness, 0)
        XCTAssertEqual(resolution.summary.backlightCeiling, 0)
        XCTAssertFalse(resolution.summary.red)
        XCTAssertFalse(resolution.summary.green)
        XCTAssertTrue(resolution.summary.blue)
    }

    func testExplicitIndicatorStatesAreMutuallyExclusive() {
        let expected: [
            (NostromoCodexIndicatorState, red: Bool, green: Bool, blue: Bool)
        ] = [
            (.unavailable, false, false, false),
            (.ready, false, false, true),
            (.running, false, true, false),
            (.needsAttention, true, false, false),
        ]

        for (indicatorState, red, green, blue) in expected {
            let resolution = NostromoLightingResolution.resolve(
                from: CodexLightingState(),
                indicatorState: indicatorState,
                settings: .defaults
            )

            XCTAssertEqual(resolution.summary.red, red)
            XCTAssertEqual(resolution.summary.green, green)
            XCTAssertEqual(resolution.summary.blue, blue)
        }
    }

    func testCodexMicroThreadColorsCannotOverrideExplicitIndicatorState() {
        var state = CodexLightingState()
        state.threads[0] = ThreadLighting(
            id: 0,
            color: 0x00FF4C,
            brightness: 1
        )
        state.threads[1] = ThreadLighting(
            id: 1,
            color: 0x304FFE,
            brightness: 0.5
        )

        let running = NostromoLightingResolution.resolve(
            from: state,
            indicatorState: .running,
            settings: .defaults
        )
        XCTAssertFalse(running.summary.red)
        XCTAssertTrue(running.summary.green)
        XCTAssertFalse(running.summary.blue)

        let ready = NostromoLightingResolution.resolve(
            from: state,
            indicatorState: .ready,
            settings: .defaults
        )
        XCTAssertFalse(ready.summary.red)
        XCTAssertFalse(ready.summary.green)
        XCTAssertTrue(ready.summary.blue)
    }

    func testCodexMicroInactivityBlackoutDoesNotClearRunningIndicator() {
        var activeLighting = CodexLightingState()
        activeLighting.threads[0] = ThreadLighting(
            id: 0,
            color: 0x304FFE,
            brightness: 1
        )
        let beforeBlackout = NostromoLightingResolution.resolve(
            from: activeLighting,
            indicatorState: .running,
            settings: .defaults
        )
        let afterBlackout = NostromoLightingResolution.resolve(
            from: CodexLightingState(),
            indicatorState: .running,
            settings: .defaults
        )

        XCTAssertTrue(beforeBlackout.summary.green)
        XCTAssertTrue(afterBlackout.summary.green)
        XCTAssertFalse(afterBlackout.summary.red)
        XCTAssertFalse(afterBlackout.summary.blue)
    }
}
