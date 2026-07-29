import NostromoCodexCore
@testable import NostromoCodexApp
import XCTest

final class NostromoLightingEffectsTests: XCTestCase {
    func testPressPulseStaysBetweenCurrentBrightnessAndUserCeiling() {
        var effects = NostromoLightingEffects(
            desired: NostromoLightingSummary(
                red: false,
                green: true,
                blue: false,
                backlightBrightness: 40,
                backlightCeiling: 128
            )
        )

        effects.pressStrength = 0.5
        XCTAssertEqual(
            effects.render,
            NostromoLightingSummary(
                red: false,
                green: true,
                blue: false,
                backlightBrightness: 84,
                backlightCeiling: 128
            )
        )

        effects.pressStrength = 1
        XCTAssertEqual(effects.render.backlightBrightness, 128)
    }

    func testTaskStatusUsesSteadyRender() {
        let effects = NostromoLightingEffects(
            desired: NostromoLightingSummary(
                red: false,
                green: true,
                blue: false,
                backlightBrightness: 41
            )
        )

        XCTAssertEqual(effects.render, effects.desired)
    }
}
