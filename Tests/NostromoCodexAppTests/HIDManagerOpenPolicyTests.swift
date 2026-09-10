import IOKit
@testable import NostromoCodexApp
import XCTest

final class HIDManagerOpenPolicyTests: XCTestCase {
    func testPrivilegeFallbackReplacesPartialExclusiveOpenBeforeSharedRetry() {
        enum Operation: Equatable {
            case open(IOOptionBits)
            case replaceManager
        }

        var operations: [Operation] = []
        var results = [kIOReturnNotPrivileged, kIOReturnSuccess]

        let result = HIDManagerOpenPolicy.open(
            requestedSeize: true,
            attempt: { options in
                operations.append(.open(options))
                return results.removeFirst()
            },
            replacePartiallyOpenedManager: {
                operations.append(.replaceManager)
            }
        )

        XCTAssertEqual(
            operations,
            [
                .open(IOOptionBits(kIOHIDOptionsTypeSeizeDevice)),
                .replaceManager,
                .open(IOOptionBits(kIOHIDOptionsTypeNone)),
            ]
        )
        XCTAssertEqual(result.status, kIOReturnSuccess)
        XCTAssertFalse(result.seized)
        XCTAssertEqual(result.exclusiveFailure, kIOReturnNotPrivileged)
    }

    func testPrivilegeFailureFallsBackWhenExclusiveAccessWasRequested() {
        XCTAssertTrue(
            HIDManagerOpenPolicy.shouldRetryWithoutSeizing(
                requestedSeize: true,
                status: kIOReturnNotPrivileged
            )
        )
        XCTAssertTrue(
            HIDManagerOpenPolicy.shouldRetryWithoutSeizing(
                requestedSeize: true,
                status: kIOReturnNotPermitted
            )
        )
    }

    func testSharedOpenNeverRetriesAndUnrelatedErrorsRemainVisible() {
        XCTAssertFalse(
            HIDManagerOpenPolicy.shouldRetryWithoutSeizing(
                requestedSeize: false,
                status: kIOReturnNotPrivileged
            )
        )
        XCTAssertFalse(
            HIDManagerOpenPolicy.shouldRetryWithoutSeizing(
                requestedSeize: true,
                status: kIOReturnExclusiveAccess
            )
        )
    }

    func testInputCallbackAcceptsCurrentDeviceRatherThanManagerIdentity() {
        let managerIdentity: UInt = 0xA11CE
        let currentDeviceIdentity: UInt = 0xD3A1CE

        XCTAssertNotEqual(managerIdentity, currentDeviceIdentity)
        XCTAssertTrue(
            HIDInputCallbackPolicy.shouldAccept(
                running: true,
                sourceDeviceIdentity: currentDeviceIdentity,
                currentDeviceIdentities: [currentDeviceIdentity]
            )
        )
    }

    func testInputCallbackRejectsStoppedOrStaleDevice() {
        XCTAssertFalse(
            HIDInputCallbackPolicy.shouldAccept(
                running: false,
                sourceDeviceIdentity: 0xD3A1CE,
                currentDeviceIdentities: [0xD3A1CE]
            )
        )
        XCTAssertFalse(
            HIDInputCallbackPolicy.shouldAccept(
                running: true,
                sourceDeviceIdentity: 0x57A1E,
                currentDeviceIdentities: [0xC011EC7]
            )
        )
        XCTAssertFalse(
            HIDInputCallbackPolicy.shouldAccept(
                running: true,
                sourceDeviceIdentity: nil,
                currentDeviceIdentities: [0xC011EC7]
            )
        )
    }
}
