@testable import NostromoCodexCore
import XCTest

final class InputGestureBoundaryTests: XCTestCase {
    func testWheelLongPressThresholdIsInclusive() {
        var wheel = WheelGestureMachine(longPressInterval: 0.5)
        wheel.press(at: 10)

        XCTAssertEqual(wheel.longPressFired(at: 10.499), [])
        XCTAssertEqual(wheel.longPressFired(at: 10.5), [.openSettings])
        XCTAssertEqual(wheel.longPressFired(at: 50), [])
        XCTAssertEqual(wheel.release(at: 51), [])
        XCTAssertEqual(wheel.mode, .scroll)
    }

    func testWheelReleaseWithoutPressAndZeroRotationAreNoOps() {
        var wheel = WheelGestureMachine()

        XCTAssertEqual(wheel.release(at: 1), [])
        XCTAssertEqual(wheel.rotate(delta: 0, at: 2), [])
        XCTAssertEqual(wheel.longPressFired(at: 3), [])
        XCTAssertEqual(wheel.mode, .scroll)
    }

    func testWheelPersistentModesAndHeldOverride() {
        var wheel = WheelGestureMachine(mode: .scroll)
        XCTAssertEqual(wheel.rotate(delta: -4, at: 1), [.scroll(-4)])

        wheel.press(at: 2)
        XCTAssertEqual(wheel.release(at: 2.1), [.modeChanged(.reasoning)])
        XCTAssertEqual(wheel.rotate(delta: 3, at: 3), [.reasoning(3)])

        wheel.press(at: 4)
        XCTAssertEqual(wheel.rotate(delta: -2, at: 4.1), [.reasoning(-2)])
        XCTAssertEqual(wheel.longPressFired(at: 5), [])
        XCTAssertEqual(wheel.release(at: 5.1), [])
        XCTAssertEqual(wheel.mode, .reasoning)

        wheel.press(at: 6)
        XCTAssertEqual(wheel.release(at: 6.1), [.modeChanged(.scroll)])
        XCTAssertEqual(wheel.rotate(delta: 5, at: 7), [.scroll(5)])
    }

    func testWheelNewPressResetsSuppressionState() {
        var wheel = WheelGestureMachine()
        wheel.press(at: 1)
        XCTAssertEqual(wheel.rotate(delta: 1, at: 1.1), [.reasoning(1)])
        XCTAssertEqual(wheel.release(at: 1.2), [])

        wheel.press(at: 2)
        XCTAssertEqual(wheel.release(at: 2.1), [.modeChanged(.reasoning)])

        wheel.press(at: 3)
        XCTAssertEqual(wheel.longPressFired(at: 3.6), [.openSettings])
        XCTAssertEqual(wheel.release(at: 4), [])

        wheel.press(at: 5)
        XCTAssertEqual(wheel.release(at: 5.1), [.modeChanged(.scroll)])
    }

    func testTenThousandWheelRotationsAreDeterministic() {
        var wheel = WheelGestureMachine()
        var scrollTotal = 0

        for index in 0 ..< 10_000 {
            let delta = index.isMultiple(of: 2) ? 1 : -1
            let output = wheel.rotate(delta: delta, at: Double(index) / 1_000)
            XCTAssertEqual(output, [.scroll(delta)], "rotation \(index)")
            if case let .scroll(value) = output.first {
                scrollTotal += value
            }
        }
        XCTAssertEqual(scrollTotal, 0)
        XCTAssertEqual(wheel.mode, .scroll)
    }

    func testPushToTalkDoublePressThresholdIsInclusive() {
        var ptt = PushToTalkGestureMachine(doublePressInterval: 0.25)

        XCTAssertEqual(ptt.press(at: 1), [.start])
        XCTAssertEqual(ptt.release(at: 1.125), [.stop])
        XCTAssertEqual(ptt.press(at: 1.375), [.start, .latched])
        XCTAssertTrue(ptt.isLatched)
        XCTAssertEqual(ptt.release(at: 1.5), [])
    }

    func testPushToTalkPressOutsideDoubleWindowIsMomentary() {
        var ptt = PushToTalkGestureMachine(doublePressInterval: 0.25)

        XCTAssertEqual(ptt.press(at: 1), [.start])
        XCTAssertEqual(ptt.release(at: 1.1), [.stop])
        XCTAssertEqual(ptt.press(at: 1.351), [.start])
        XCTAssertFalse(ptt.isLatched)
        XCTAssertEqual(ptt.release(at: 1.5), [.stop])
    }

    func testPushToTalkLatchCanBeStoppedAndFreshSequenceStartsNormally() {
        var ptt = PushToTalkGestureMachine(doublePressInterval: 0.25)
        _ = ptt.press(at: 1)
        _ = ptt.release(at: 1.1)
        XCTAssertEqual(ptt.press(at: 1.2), [.start, .latched])
        XCTAssertEqual(ptt.release(at: 1.21), [])

        XCTAssertEqual(ptt.press(at: 2), [.stop, .unlatched])
        XCTAssertEqual(ptt.release(at: 2.1), [])
        XCTAssertFalse(ptt.isLatched)

        XCTAssertEqual(ptt.press(at: 3), [.start])
        XCTAssertEqual(ptt.release(at: 3.1), [.stop])
    }

    func testTenThousandSeparatedPushToTalkCyclesNeverLatch() {
        var ptt = PushToTalkGestureMachine(doublePressInterval: 0.25)

        for index in 0 ..< 10_000 {
            let pressedAt = Double(index)
            XCTAssertEqual(ptt.press(at: pressedAt), [.start], "press \(index)")
            XCTAssertEqual(ptt.release(at: pressedAt + 0.1), [.stop], "release \(index)")
            XCTAssertFalse(ptt.isLatched, "cycle \(index)")
        }
    }

    func testDPadDirectionUsesSignForAllMagnitudes() {
        let cases: [(Int, Int, DPadDirection)] = [
            (0, -1, .up),
            (1, -1, .upRight),
            (1, 0, .right),
            (1, 1, .downRight),
            (0, 1, .down),
            (-1, 1, .downLeft),
            (-1, 0, .left),
            (-1, -1, .upLeft),
        ]
        let magnitudes = [1, 2, 127, 1_024, Int.max]

        for magnitude in magnitudes {
            for (x, y, expected) in cases {
                let scaledX = x == 0 ? 0 : (x > 0 ? magnitude : -magnitude)
                let scaledY = y == 0 ? 0 : (y > 0 ? magnitude : -magnitude)
                XCTAssertEqual(
                    DPadInterpreter.direction(x: scaledX, y: scaledY),
                    expected,
                    "x \(scaledX), y \(scaledY)"
                )
            }
        }
        XCTAssertNil(DPadInterpreter.direction(x: 0, y: 0))
    }

    func testDPadCoalescingAndReleaseThresholdsAreInclusive() {
        var dpad = DPadInterpreter(coalescingInterval: 0.125, releaseInterval: 0.5)
        dpad.ingest(axis: .x, value: -1, at: 10)
        dpad.ingest(axis: .y, value: -1, at: 10.01)

        XCTAssertNil(dpad.resolve(at: 10.124))
        XCTAssertEqual(dpad.resolve(at: 10.125), .upLeft)
        XCTAssertNil(dpad.releaseIfIdle(at: 10.509))
        XCTAssertEqual(dpad.releaseIfIdle(at: 10.51), .upLeft)
        XCTAssertNil(dpad.releaseIfIdle(at: 11))
    }

    func testDPadSuppressesNeighborTransitionsUntilIdleRelease() {
        var dpad = DPadInterpreter(coalescingInterval: 0.01, releaseInterval: 0.2)

        ingest(.right, at: 1, into: &dpad)
        XCTAssertEqual(dpad.resolve(at: 1.02), .right)

        ingest(.right, at: 1.03, into: &dpad)
        XCTAssertNil(dpad.resolve(at: 1.05))

        ingest(.downRight, at: 1.06, into: &dpad)
        XCTAssertNil(dpad.resolve(at: 1.08))

        ingest(.down, at: 1.09, into: &dpad)
        XCTAssertNil(dpad.resolve(at: 1.11))
        XCTAssertEqual(dpad.releaseIfIdle(at: 1.3), .right)

        ingest(.down, at: 2, into: &dpad)
        XCTAssertEqual(dpad.resolve(at: 2.02), .down)
    }

    func testDPadResetsStalePartialAxisBeforeNewGesture() {
        var dpad = DPadInterpreter(coalescingInterval: 0.01, releaseInterval: 0.1)
        dpad.ingest(axis: .x, value: 1, at: 1)
        dpad.ingest(axis: .y, value: -1, at: 1.2)

        XCTAssertEqual(dpad.resolve(at: 1.22), .up)
        XCTAssertEqual(dpad.releaseIfIdle(at: 1.3), .up)
    }

    func testAllDPadDirectionsRemainStableAcrossTenThousandGestures() {
        var dpad = DPadInterpreter(coalescingInterval: 0, releaseInterval: 0)
        let directions = DPadDirection.allCases

        for index in 0 ..< 10_000 {
            let expected = directions[index % directions.count]
            let time = Double(index)
            ingest(expected, at: time, into: &dpad)
            XCTAssertEqual(dpad.resolve(at: time), expected, "gesture \(index)")
            XCTAssertEqual(dpad.releaseIfIdle(at: time), expected, "release \(index)")
        }
    }

    private func ingest(
        _ direction: DPadDirection,
        at time: TimeInterval,
        into dpad: inout DPadInterpreter
    ) {
        let vector: (x: Int, y: Int) = switch direction {
        case .up: (0, -1)
        case .upRight: (1, -1)
        case .right: (1, 0)
        case .downRight: (1, 1)
        case .down: (0, 1)
        case .downLeft: (-1, 1)
        case .left: (-1, 0)
        case .upLeft: (-1, -1)
        }
        dpad.ingest(axis: .x, value: vector.x, at: time)
        dpad.ingest(axis: .y, value: vector.y, at: time)
    }
}
