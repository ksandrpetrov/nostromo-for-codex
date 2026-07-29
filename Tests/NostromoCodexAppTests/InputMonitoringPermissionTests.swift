import IOKit.hid
@testable import NostromoCodexApp
import XCTest

final class InputMonitoringPermissionTests: XCTestCase {
    func testDeniedAccessOpensInputMonitoringSettings() {
        let permission = FakeInputMonitoringPermissionController(
            access: kIOHIDAccessTypeDenied
        )
        let manager = NostromoHIDManager(inputMonitoringPermission: permission)

        manager.requestInputMonitoring()

        XCTAssertEqual(permission.requestCount, 0)
        XCTAssertEqual(permission.openSettingsCount, 1)
    }

    func testUnknownAccessRequestsSystemPermissionWithoutOpeningSettings() {
        let permission = FakeInputMonitoringPermissionController(
            access: kIOHIDAccessTypeUnknown
        )
        let manager = NostromoHIDManager(inputMonitoringPermission: permission)

        manager.requestInputMonitoring()

        XCTAssertEqual(permission.requestCount, 1)
        XCTAssertEqual(permission.openSettingsCount, 0)
    }

    func testGrantedAccessDoesNotRequestPermissionOrOpenSettings() {
        let permission = FakeInputMonitoringPermissionController(
            access: kIOHIDAccessTypeGranted
        )
        let manager = NostromoHIDManager(inputMonitoringPermission: permission)

        manager.requestInputMonitoring()

        XCTAssertEqual(permission.requestCount, 0)
        XCTAssertEqual(permission.openSettingsCount, 0)
    }
}

private final class FakeInputMonitoringPermissionController:
    InputMonitoringPermissionControlling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let access: IOHIDAccessType
    private var requestCountStorage = 0
    private var openSettingsCountStorage = 0

    init(access: IOHIDAccessType) {
        self.access = access
    }

    var requestCount: Int {
        lock.withLock { requestCountStorage }
    }

    var openSettingsCount: Int {
        lock.withLock { openSettingsCountStorage }
    }

    func checkAccess() -> IOHIDAccessType {
        access
    }

    func requestAccess() -> Bool {
        lock.withLock { requestCountStorage += 1 }
        return false
    }

    func openSettings() {
        lock.withLock { openSettingsCountStorage += 1 }
    }
}
