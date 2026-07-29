@testable import NostromoCodexCore
import XCTest

final class InputReconnectGateTests: XCTestCase {
    private let button = HIDSignature(
        usagePage: 0x07,
        usage: 0x2B,
        cookie: 1,
        kind: .button
    )
    private let dpadY = HIDSignature(
        usagePage: 0x01,
        usage: 0x31,
        cookie: 2,
        kind: .axis
    )
    private let wheel = HIDSignature(
        usagePage: 0x01,
        usage: 0x38,
        cookie: 3,
        kind: .axis
    )

    func testButtonHeldAcrossReconnectRequiresReleaseBeforeItCanFire() {
        var gate = InputReconnectGate()
        gate.reconnect(at: 10)

        XCTAssertFalse(gate.shouldForward(signature: button, value: 1, at: 10.01))
        XCTAssertFalse(gate.shouldForward(signature: button, value: 1, at: 10.40))
        XCTAssertFalse(gate.shouldForward(signature: button, value: 0, at: 10.41))
        XCTAssertTrue(gate.shouldForward(signature: button, value: 1, at: 10.50))
        XCTAssertTrue(gate.shouldForward(signature: button, value: 0, at: 10.51))
    }

    func testFreshButtonAfterSettlingIsNotConsumed() {
        var gate = InputReconnectGate()
        gate.reconnect(at: 20)

        XCTAssertTrue(gate.shouldForward(signature: button, value: 1, at: 20.26))
        XCTAssertTrue(gate.shouldForward(signature: button, value: 0, at: 20.27))
    }

    func testHeldDPadRemainsSuppressedUntilAnIdleGap() {
        var gate = InputReconnectGate()
        gate.reconnect(at: 30)

        XCTAssertFalse(gate.shouldForward(signature: dpadY, value: -1, at: 30.01))
        XCTAssertFalse(gate.shouldForward(signature: dpadY, value: -1, at: 30.20))
        XCTAssertFalse(gate.shouldForward(signature: dpadY, value: -1, at: 30.30))
        XCTAssertFalse(gate.shouldForward(signature: dpadY, value: -1, at: 30.40))
        XCTAssertTrue(gate.shouldForward(signature: dpadY, value: -1, at: 30.54))
    }

    func testWheelDeltasAreDroppedOnlyDuringSettling() {
        var gate = InputReconnectGate()
        gate.reconnect(at: 40)

        XCTAssertFalse(gate.shouldForward(signature: wheel, value: 1, at: 40.10))
        XCTAssertTrue(gate.shouldForward(signature: wheel, value: -1, at: 40.26))
    }

    func testAdditionalInterfaceExtendsGuardWithoutForgettingHeldButton() {
        var gate = InputReconnectGate()
        gate.reconnect(at: 50)
        XCTAssertFalse(gate.shouldForward(signature: button, value: 1, at: 50.10))
        gate.extendSettlingPeriod(at: 50.20)

        XCTAssertFalse(gate.shouldForward(signature: button, value: 1, at: 50.50))
        XCTAssertFalse(gate.shouldForward(signature: button, value: 0, at: 50.51))
        XCTAssertTrue(gate.shouldForward(signature: button, value: 1, at: 50.52))
    }
}
