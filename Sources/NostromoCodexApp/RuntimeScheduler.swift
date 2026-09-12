import Foundation

/// All deadlines use the same monotonic time domain as HID event timestamps.
@MainActor
protocol RuntimeClock: AnyObject {
    var now: TimeInterval { get }
    func sleep(until deadline: TimeInterval) async throws
}

@MainActor
final class SystemRuntimeClock: RuntimeClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func sleep(until deadline: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, deadline - now)))
    }
}

/// Owns replaceable deadlines. A cancelled job cannot run or remove its successor,
/// even when the clock resumes an old continuation after cancellation.
@MainActor
final class RuntimeScheduler {
    enum Key: Hashable, Sendable {
        case dpadResolve, dpadRelease, wheelLongPress, feedback
    }

    private struct Job {
        let id: UUID
        let task: Task<Void, Never>
    }

    let clock: any RuntimeClock
    private var jobs: [Key: Job] = [:]

    init(clock: any RuntimeClock = SystemRuntimeClock()) {
        self.clock = clock
    }

    deinit {
        for job in jobs.values { job.task.cancel() }
    }

    func contains(_ key: Key) -> Bool { jobs[key] != nil }

    func schedule(_ key: Key, after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        cancel(key)
        let id = UUID()
        let deadline = clock.now + delay
        let clock = clock
        let task = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled, let self, self.jobs[key]?.id == id else { return }
            self.jobs[key] = nil
            action()
        }
        jobs[key] = Job(id: id, task: task)
    }

    func cancel(_ key: Key) {
        jobs.removeValue(forKey: key)?.task.cancel()
    }

    func cancelAll() {
        for job in jobs.values { job.task.cancel() }
        jobs.removeAll()
    }
}
