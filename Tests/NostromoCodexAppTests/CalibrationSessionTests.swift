@testable import NostromoCodexApp
import NostromoCodexCore
import XCTest

final class CalibrationSessionTests: XCTestCase {
    func testCompletedDraftConsumesFinalReleaseAfterCommit() throws {
        var session = CalibrationSession()
        session.begin(from: .nostromoFactory)
        let controls = ControlID.keypad + [.wheelPress]
        for control in ControlID.keypad {
            let signature = try XCTUnwrap(CalibrationMap.nostromoFactory.signatures[control])
            XCTAssertNil(session.recordButton(signature, value: 1))
            XCTAssertTrue(session.consumesReleaseGate(signature: signature, value: 0))
        }
        for direction in DPadDirection.allCases {
            XCTAssertNil(session.recordDirection(direction))
        }
        let last = try XCTUnwrap(CalibrationMap.nostromoFactory.signatures[.wheelPress])
        XCTAssertNil(session.recordButton(last, value: 1))
        XCTAssertNil(session.target)
        XCTAssertEqual(session.draft?.signatures.count, controls.count)
        session.finish()
        XCTAssertNil(session.draft)
        XCTAssertTrue(session.consumesReleaseGate(signature: last, value: 1))
        XCTAssertTrue(session.consumesReleaseGate(signature: last, value: 0))
        XCTAssertFalse(session.consumesReleaseGate(signature: last, value: 1))
    }

    func testCancellationDiscardsDraftAndReleaseGate() throws {
        var session = CalibrationSession()
        session.begin(from: .nostromoFactory)
        let button = try XCTUnwrap(CalibrationMap.nostromoFactory.signatures[.key01])
        XCTAssertNil(session.recordButton(button, value: 1))
        session.cancel()
        XCTAssertNil(session.target)
        XCTAssertNil(session.draft)
        XCTAssertFalse(session.consumesReleaseGate(signature: button, value: 0))
    }
}
