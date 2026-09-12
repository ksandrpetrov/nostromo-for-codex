import Foundation
@testable import NostromoCodexApp
import XCTest

@MainActor
final class ChatGPTLaunchCoordinatorTests: AppModelTestCase {
    private var request: ChatGPTLaunchCoordinator.BridgeRequest {
        .init(preloadURL: URL(fileURLWithPath: "/unused/preload.cjs"),
              socketPath: "/unused/socket", sessionDescriptorPath: "/unused/session",
              token: "test", forceUnsupported: false)
    }

    func testStopBeforeTaskStartsPreventsTerminationAndFutureLaunches() async {
        let launcher = FakeLauncher()
        let coordinator = ChatGPTLaunchCoordinator(launcher: launcher)
        coordinator.start(.restart(request))
        coordinator.stop()
        coordinator.start(.normal)
        await drainTasks()
        XCTAssertFalse(coordinator.inProgress)
        XCTAssertEqual(launcher.terminateCalls, 0)
        XCTAssertEqual(launcher.normalLaunchCalls, 0)
        XCTAssertEqual(launcher.launchCalls, 0)
    }

    func testOnlyOneRestartRunsAndStopCancelsRecovery() async {
        let launcher = FakeLauncher()
        launcher.failLaunch(with: .launchFailed, delay: .seconds(100))
        let coordinator = ChatGPTLaunchCoordinator(launcher: launcher)
        var outcomes = 0
        coordinator.onOutcome = { _ in outcomes += 1 }
        coordinator.start(.restart(request))
        coordinator.start(.restart(request))
        let started = await waitUntil { launcher.launchCalls == 1 }
        XCTAssertTrue(started)
        coordinator.stop()
        let finished = await waitUntil { !coordinator.inProgress }
        XCTAssertTrue(finished)
        XCTAssertEqual(launcher.terminateCalls, 1)
        XCTAssertEqual(launcher.normalLaunchCalls, 0)
        XCTAssertEqual(outcomes, 0)
    }

    func testNormalLaunchPublishesOutcomeWithoutTerminatingApplication() async {
        let launcher = FakeLauncher()
        let coordinator = ChatGPTLaunchCoordinator(launcher: launcher)
        var outcome: ChatGPTLaunchCoordinator.Outcome?
        coordinator.onOutcome = { outcome = $0 }
        coordinator.start(.normal)
        let finished = await waitUntil { outcome != nil }
        XCTAssertTrue(finished)
        XCTAssertEqual(outcome?.needsRestart, true)
        XCTAssertNil(outcome?.errorMessage)
        XCTAssertEqual(launcher.terminateCalls, 0)
        XCTAssertEqual(launcher.normalLaunchCalls, 1)
    }
}
