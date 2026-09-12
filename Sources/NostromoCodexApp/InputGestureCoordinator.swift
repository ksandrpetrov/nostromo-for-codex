import Foundation
import NostromoCodexCore

/// Owns physical gesture state and deadlines. Mapping, permissions and action
/// dispatch stay with the MainActor facade, so a gesture never bypasses policy.
@MainActor
final class InputGestureCoordinator {
    private let scheduler: RuntimeScheduler
    private var dpad = DPadInterpreter()
    private var dpadButtons = DPadButtonInterpreter()
    private var wheel = WheelGestureMachine()
    private(set) var wheelPressed = false

    var onDirection: (DPadDirection, TimeInterval) -> Void = { _, _ in }
    var onDirectionReleased: (TimeInterval) -> Void = { _ in }
    var onWheelOutputs: ([WheelOutput]) -> Void = { _ in }

    init(scheduler: RuntimeScheduler) {
        self.scheduler = scheduler
    }

    func resetDPad() {
        scheduler.cancel(.dpadResolve)
        scheduler.cancel(.dpadRelease)
        dpad = DPadInterpreter()
        dpadButtons = DPadButtonInterpreter()
    }

    func reset() {
        resetDPad()
        scheduler.cancel(.wheelLongPress)
        wheelPressed = false
        wheel = WheelGestureMachine(mode: wheel.mode)
    }

    func ingest(axis: DPadAxis, value: Int, at time: TimeInterval) {
        dpad.ingest(axis: axis, value: value, at: time)
        // Repeating relative reports extend the idle deadline even when the
        // resolved direction does not change.
        scheduleDPadRelease()
        guard !scheduler.contains(.dpadResolve) else { return }
        scheduler.schedule(.dpadResolve, after: 0.013) { [weak self] in
            guard let self else { return }
            let now = self.scheduler.clock.now
            guard let direction = self.dpad.resolve(at: now) else { return }
            self.onDirection(direction, now)
            self.scheduleDPadRelease()
        }
    }

    func ingest(button: DPadButton, pressed: Bool, at time: TimeInterval) {
        if dpadButtons.ingest(button: button, pressed: pressed, at: time) != nil {
            onDirectionReleased(time)
        }
        if !pressed, dpadButtons.isIdle {
            scheduler.cancel(.dpadResolve)
            return
        }
        guard pressed, !scheduler.contains(.dpadResolve) else { return }
        scheduler.schedule(.dpadResolve, after: 0.013) { [weak self] in
            guard let self else { return }
            let now = self.scheduler.clock.now
            guard let direction = self.dpadButtons.resolve(at: now) else { return }
            self.onDirection(direction, now)
        }
    }

    private func scheduleDPadRelease() {
        scheduler.schedule(.dpadRelease, after: 0.130) { [weak self] in
            guard let self else { return }
            let now = self.scheduler.clock.now
            guard self.dpad.releaseIfIdle(at: now) != nil else { return }
            self.onDirectionReleased(now)
        }
    }

    func pressWheel(at time: TimeInterval) {
        guard !wheelPressed else { return }
        wheelPressed = true
        wheel.press(at: time)
        scheduler.schedule(.wheelLongPress, after: 0.610) { [weak self] in
            guard let self else { return }
            self.onWheelOutputs(self.wheel.longPressFired(at: self.scheduler.clock.now))
        }
    }

    func releaseWheel(at time: TimeInterval) {
        guard wheelPressed else { return }
        wheelPressed = false
        scheduler.cancel(.wheelLongPress)
        onWheelOutputs(wheel.release(at: time))
    }

    func rotateWheel(_ delta: Int, at time: TimeInterval) {
        onWheelOutputs(wheel.rotate(delta: delta, at: time))
    }
}
