import Foundation
@testable import NostromoCodexApp
import NostromoCodexCore
import XCTest

@MainActor
final class InputGestureCoordinatorTests: XCTestCase {
    func testRepeatedReportsResolveDuringStreamAndExtendReleaseDeadline() async {
        let clock = ManualRuntimeClock()
        let scheduler = RuntimeScheduler(clock: clock)
        let gestures = InputGestureCoordinator(scheduler: scheduler)
        var directions: [DPadDirection] = []
        var releases = 0
        gestures.onDirection = { direction, _ in directions.append(direction) }
        gestures.onDirectionReleased = { _ in releases += 1 }
        for _ in 0..<40 {
            gestures.ingest(axis: .y, value: -1, at: clock.now)
            await drainTasks()
            clock.advance(by: 0.002)
            await drainTasks()
        }
        XCTAssertEqual(directions, [.up])
        XCTAssertEqual(releases, 0)
        clock.advance(by: 0.100)
        await drainTasks()
        XCTAssertEqual(releases, 0)
        clock.advance(by: 0.050)
        await drainTasks()
        XCTAssertEqual(releases, 1)
    }

    func testResetCancelsPendingDirectionAndLongPress() async {
        let clock = ManualRuntimeClock()
        let scheduler = RuntimeScheduler(clock: clock)
        let gestures = InputGestureCoordinator(scheduler: scheduler)
        var outputs: [WheelOutput] = []
        var directions: [DPadDirection] = []
        gestures.onDirection = { direction, _ in directions.append(direction) }
        gestures.onWheelOutputs = { outputs += $0 }
        gestures.ingest(button: .up, pressed: true, at: clock.now)
        gestures.pressWheel(at: clock.now)
        await clock.waitForSleepers(2)
        gestures.reset()
        clock.advance(by: 1)
        await drainTasks()
        gestures.releaseWheel(at: clock.now)
        XCTAssertTrue(outputs.isEmpty)
        XCTAssertTrue(directions.isEmpty)
        XCTAssertFalse(gestures.wheelPressed)
    }

    func testLongPressRunsOnceAndReleaseDoesNotToggleMode() async {
        let clock = ManualRuntimeClock()
        let scheduler = RuntimeScheduler(clock: clock)
        let gestures = InputGestureCoordinator(scheduler: scheduler)
        var outputs: [WheelOutput] = []
        gestures.onWheelOutputs = { outputs += $0 }
        gestures.pressWheel(at: clock.now)
        gestures.pressWheel(at: clock.now)
        await clock.waitForSleepers(1)
        clock.advance(by: 0.610)
        await drainTasks()
        gestures.releaseWheel(at: clock.now)
        clock.advance(by: 1)
        await drainTasks()
        XCTAssertEqual(outputs, [.openSettings])
    }
}
