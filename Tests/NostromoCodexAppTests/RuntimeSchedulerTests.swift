import Foundation
@testable import NostromoCodexApp
import XCTest

@MainActor
final class RuntimeSchedulerTests: XCTestCase {
    func testReplacingCancelledDeadlineCannotRunOrEraseSuccessor() async {
        let clock = ManualRuntimeClock()
        let scheduler = RuntimeScheduler(clock: clock)
        var results: [Int] = []
        scheduler.schedule(.dpadResolve, after: 1) { results.append(1) }
        await clock.waitForSleepers(1)
        scheduler.schedule(.dpadResolve, after: 2) { results.append(2) }
        await clock.waitForSleepers(2)
        clock.advance(by: 1)
        await drainTasks()
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(scheduler.contains(.dpadResolve))
        clock.advance(by: 1)
        await drainTasks()
        XCTAssertEqual(results, [2])
        XCTAssertFalse(scheduler.contains(.dpadResolve))
    }

    func testCancelAllSuppressesEveryPendingAction() async {
        let clock = ManualRuntimeClock()
        let scheduler = RuntimeScheduler(clock: clock)
        var calls = 0
        scheduler.schedule(.feedback, after: 1) { calls += 1 }
        scheduler.schedule(.wheelLongPress, after: 1) { calls += 1 }
        await clock.waitForSleepers(2)
        scheduler.cancelAll()
        clock.advance(by: 2)
        await drainTasks()
        XCTAssertEqual(calls, 0)
    }

    func testActionCanScheduleItsOwnSuccessor() async {
        let clock = ManualRuntimeClock()
        let scheduler = RuntimeScheduler(clock: clock)
        var calls = 0
        scheduler.schedule(.feedback, after: 1) {
            calls += 1
            scheduler.schedule(.feedback, after: 1) { calls += 1 }
        }
        await clock.waitForSleepers(1)
        clock.advance(by: 1)
        await clock.waitForSleepers(1)
        XCTAssertEqual(calls, 1)
        clock.advance(by: 1)
        await drainTasks()
        XCTAssertEqual(calls, 2)
    }
}

/// Deliberately resumes cancelled sleepers too, exercising the scheduler's
/// generation guard independently from a particular clock's cancellation.
@MainActor
final class ManualRuntimeClock: RuntimeClock {
    var now: TimeInterval = 0
    private var sleepers: [(TimeInterval, CheckedContinuation<Void, Never>)] = []

    func sleep(until deadline: TimeInterval) async throws {
        guard deadline > now else { return }
        await withCheckedContinuation { sleepers.append((deadline, $0)) }
    }

    func advance(by interval: TimeInterval) {
        now += interval
        let ready = sleepers.filter { $0.0 <= now }
        sleepers.removeAll { $0.0 <= now }
        for (_, continuation) in ready { continuation.resume() }
    }

    func waitForSleepers(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if sleepers.count == count { return }
            await Task.yield()
        }
        XCTFail("Expected \(count) sleepers, got \(sleepers.count)", file: file, line: line)
    }
}

@MainActor
func drainTasks() async {
    for _ in 0..<20 { await Task.yield() }
}
