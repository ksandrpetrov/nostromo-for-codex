@testable import NostromoCodexCore
import XCTest

final class InputGestureTests: XCTestCase {
    func testShortWheelPressTogglesPersistentMode() {
        var wheel = WheelGestureMachine()
        wheel.press(at: 10)
        XCTAssertEqual(wheel.release(at: 10.2), [.modeChanged(.reasoning)])
        XCTAssertEqual(wheel.rotate(delta: 2, at: 11), [.reasoning(2)])
    }

    func testHeldRotationIsReasoningAndSuppressesClick() {
        var wheel = WheelGestureMachine()
        wheel.press(at: 10)
        XCTAssertEqual(wheel.rotate(delta: -1, at: 10.1), [.reasoning(-1)])
        XCTAssertEqual(wheel.release(at: 10.2), [])
        XCTAssertEqual(wheel.mode, .scroll)
    }

    func testLongPressOpensSettingsOnlyOnceAndSuppressesClick() {
        var wheel = WheelGestureMachine()
        wheel.press(at: 1)
        XCTAssertEqual(wheel.longPressFired(at: 1.59), [])
        XCTAssertEqual(wheel.longPressFired(at: 1.6), [.openSettings])
        XCTAssertEqual(wheel.longPressFired(at: 2), [])
        XCTAssertEqual(wheel.release(at: 2.1), [])
    }

    func testEightDPadDirections() {
        XCTAssertEqual(DPadInterpreter.direction(x: 0, y: -1), .up)
        XCTAssertEqual(DPadInterpreter.direction(x: 1, y: -1), .upRight)
        XCTAssertEqual(DPadInterpreter.direction(x: 1, y: 0), .right)
        XCTAssertEqual(DPadInterpreter.direction(x: 1, y: 1), .downRight)
        XCTAssertEqual(DPadInterpreter.direction(x: 0, y: 1), .down)
        XCTAssertEqual(DPadInterpreter.direction(x: -1, y: 1), .downLeft)
        XCTAssertEqual(DPadInterpreter.direction(x: -1, y: 0), .left)
        XCTAssertEqual(DPadInterpreter.direction(x: -1, y: -1), .upLeft)
        XCTAssertNil(DPadInterpreter.direction(x: 0, y: 0))
    }

    func testDPadCoalescesAxesIntoDiagonalAndDebouncesRepeat() {
        var dpad = DPadInterpreter(coalescingInterval: 0.012, releaseInterval: 0.12)
        dpad.ingest(axis: .x, value: 1, at: 5)
        dpad.ingest(axis: .y, value: -1, at: 5.004)
        XCTAssertNil(dpad.resolve(at: 5.01))
        XCTAssertEqual(dpad.resolve(at: 5.013), .upRight)

        dpad.ingest(axis: .x, value: 1, at: 5.02)
        dpad.ingest(axis: .y, value: -1, at: 5.021)
        XCTAssertNil(dpad.resolve(at: 5.04))
        XCTAssertEqual(dpad.releaseIfIdle(at: 5.15), .upRight)
    }

    func testKeyboardDPadCoalescesDiagonalAndReleasesOnce() {
        var dpad = DPadButtonInterpreter(coalescingInterval: 0.012)

        XCTAssertNil(dpad.ingest(button: .up, pressed: true, at: 1.000))
        XCTAssertNil(dpad.ingest(button: .right, pressed: true, at: 1.004))
        XCTAssertNil(dpad.resolve(at: 1.011))
        XCTAssertEqual(dpad.resolve(at: 1.013), .upRight)
        XCTAssertNil(dpad.ingest(button: .up, pressed: false, at: 1.050))
        XCTAssertEqual(
            dpad.ingest(button: .right, pressed: false, at: 1.055),
            .upRight
        )
        XCTAssertTrue(dpad.isIdle)
    }

    func testKeyboardDPadSuppressesCardinalTransitionWithinOneHold() {
        var dpad = DPadButtonInterpreter(coalescingInterval: 0)

        _ = dpad.ingest(button: .up, pressed: true, at: 1)
        XCTAssertEqual(dpad.resolve(at: 1), .up)
        _ = dpad.ingest(button: .right, pressed: true, at: 1.1)
        XCTAssertNil(dpad.resolve(at: 1.1))
        XCTAssertNil(dpad.ingest(button: .up, pressed: false, at: 1.2))
        XCTAssertEqual(dpad.ingest(button: .right, pressed: false, at: 1.3), .up)
    }

    func testNostromoKeyboardUsageMappingCorrectsPhysicalQuarterTurn() {
        XCTAssertEqual(DPadButton(keyboardUsage: 0x4F), .down)
        XCTAssertEqual(DPadButton(keyboardUsage: 0x50), .up)
        XCTAssertEqual(DPadButton(keyboardUsage: 0x51), .left)
        XCTAssertEqual(DPadButton(keyboardUsage: 0x52), .right)
        XCTAssertNil(DPadButton(keyboardUsage: 0x28))
    }

    func testNostromoKeyboardUsagesCoverAllEightPhysicalDirections() throws {
        let cases: [([UInt32], DPadDirection)] = [
            ([0x50], .up),
            ([0x50, 0x52], .upRight),
            ([0x52], .right),
            ([0x52, 0x4F], .downRight),
            ([0x4F], .down),
            ([0x4F, 0x51], .downLeft),
            ([0x51], .left),
            ([0x51, 0x50], .upLeft),
        ]

        for (usages, expected) in cases {
            var dpad = DPadButtonInterpreter(coalescingInterval: 0)
            for usage in usages {
                let button = try XCTUnwrap(DPadButton(keyboardUsage: usage))
                XCTAssertNil(dpad.ingest(button: button, pressed: true, at: 1))
            }
            XCTAssertEqual(dpad.resolve(at: 1), expected)
        }
    }

    func testPushToTalkHoldAndDoublePressLatch() {
        var ptt = PushToTalkGestureMachine()
        XCTAssertEqual(ptt.press(at: 1), [.start])
        XCTAssertEqual(ptt.release(at: 1.1), [.stop])
        XCTAssertEqual(ptt.press(at: 1.25), [.start, .latched])
        XCTAssertTrue(ptt.isLatched)
        XCTAssertEqual(ptt.release(at: 1.3), [])
        XCTAssertEqual(ptt.press(at: 2), [.stop, .unlatched])
        XCTAssertFalse(ptt.isLatched)
        XCTAssertEqual(ptt.release(at: 2.1), [])
    }
}
