import AppKit
@testable import NostromoCodexApp
import XCTest

@MainActor
final class ApplicationLifecycleTests: XCTestCase {
    private func isolateDashboardOpeningState() {
        NostromoApplicationDelegate.resetDashboardOpeningForTesting()
    }

    func testLaunchHandlerRunsWhenInstalledBeforeLaunchNotification() {
        NostromoApplicationDelegate.resetLaunchHandlingForTesting()
        defer { NostromoApplicationDelegate.resetLaunchHandlingForTesting() }
        var callCount = 0

        NostromoApplicationDelegate.installDidFinishLaunchingHandler {
            callCount += 1
        }
        NostromoApplicationDelegate().applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        XCTAssertEqual(callCount, 1)
    }

    func testLaunchHandlerIsReplayedWhenInstalledAfterLaunchNotification() {
        NostromoApplicationDelegate.resetLaunchHandlingForTesting()
        defer { NostromoApplicationDelegate.resetLaunchHandlingForTesting() }
        var callCount = 0

        NostromoApplicationDelegate().applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        NostromoApplicationDelegate.installDidFinishLaunchingHandler {
            callCount += 1
        }

        XCTAssertEqual(callCount, 1)
    }

    func testDashboardRequestWaitsForStatusControllerAndPreservesSection() {
        isolateDashboardOpeningState()
        defer { NostromoApplicationDelegate.resetDashboardOpeningForTesting() }
        var openedSections: [DashboardSection?] = []

        NostromoApplicationDelegate.requestDashboardOpen(.connection)
        XCTAssertTrue(openedSections.isEmpty)

        NostromoApplicationDelegate.installDashboardOpenHandler { section in
            openedSections.append(section)
        }

        XCTAssertEqual(openedSections.count, 1)
        XCTAssertEqual(openedSections[0], .connection)
    }

    func testQueuedDashboardRequestsCoalesceAndKeepLatestExplicitSection() {
        isolateDashboardOpeningState()
        defer { NostromoApplicationDelegate.resetDashboardOpeningForTesting() }
        var openedSections: [DashboardSection?] = []

        NostromoApplicationDelegate.requestDashboardOpen()
        NostromoApplicationDelegate.requestDashboardOpen(.profiles)
        NostromoApplicationDelegate.requestDashboardOpen(.connection)
        NostromoApplicationDelegate.installDashboardOpenHandler { section in
            openedSections.append(section)
        }

        XCTAssertEqual(openedSections.count, 1)
        XCTAssertEqual(openedSections[0], .connection)
    }

    func testInstalledDashboardHandlerReceivesEveryRequest() {
        isolateDashboardOpeningState()
        defer { NostromoApplicationDelegate.resetDashboardOpeningForTesting() }
        var openedSections: [DashboardSection?] = []
        NostromoApplicationDelegate.installDashboardOpenHandler { section in
            openedSections.append(section)
        }

        NostromoApplicationDelegate.requestDashboardOpen()
        NostromoApplicationDelegate.requestDashboardOpen(.profiles)

        XCTAssertEqual(openedSections.count, 2)
        XCTAssertNil(openedSections[0])
        XCTAssertEqual(openedSections[1], .profiles)
    }

    func testReopenWithoutDashboardQueuesOpenUntilLaunchFinishes() {
        isolateDashboardOpeningState()
        defer { NostromoApplicationDelegate.resetDashboardOpeningForTesting() }
        let delegate = NostromoApplicationDelegate()
        let handled = delegate.applicationShouldHandleReopen(
            NSApplication.shared,
            hasVisibleWindows: false
        )
        var openCount = 0

        NostromoApplicationDelegate.installDashboardOpenHandler { _ in
            openCount += 1
        }

        XCTAssertFalse(handled)
        XCTAssertEqual(openCount, 1)
    }

    func testReopenWithVisibleWindowDoesNotRequestAnotherDashboard() {
        isolateDashboardOpeningState()
        defer { NostromoApplicationDelegate.resetDashboardOpeningForTesting() }
        var openCount = 0
        NostromoApplicationDelegate.installDashboardOpenHandler { _ in
            openCount += 1
        }

        let handled = NostromoApplicationDelegate()
            .applicationShouldHandleReopen(
                NSApplication.shared,
                hasVisibleWindows: true
            )

        XCTAssertFalse(handled)
        XCTAssertEqual(openCount, 0)
    }

}
