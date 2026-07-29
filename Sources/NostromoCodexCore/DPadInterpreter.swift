import Foundation

public enum DPadAxis: Sendable {
    case x
    case y
}

/// Keyboard-page usages emitted by the Razer Nostromo's second HID interface.
/// The firmware reports the four switches as USB arrow keys, but the physical
/// thumb pad is mounted a quarter-turn clockwise relative to those usages.
/// Diagonals are represented by two simultaneous buttons.
public enum DPadButton: Hashable, Sendable {
    case up
    case right
    case down
    case left

    public init?(keyboardUsage: UInt32) {
        switch keyboardUsage {
        case 0x4F: self = .down
        case 0x50: self = .up
        case 0x51: self = .left
        case 0x52: self = .right
        default: return nil
        }
    }
}

public struct DPadButtonInterpreter: Sendable {
    public let coalescingInterval: TimeInterval

    private var pressedButtons: Set<DPadButton> = []
    private var firstPressAt: TimeInterval?
    private var activeDirection: DPadDirection?

    public init(coalescingInterval: TimeInterval = 0.012) {
        self.coalescingInterval = coalescingInterval
    }

    public var isIdle: Bool {
        pressedButtons.isEmpty && activeDirection == nil
    }

    /// Records one edge. A non-nil return means the active physical gesture
    /// ended and the mapped control must be released.
    public mutating func ingest(
        button: DPadButton,
        pressed: Bool,
        at time: TimeInterval
    ) -> DPadDirection? {
        if pressed {
            let inserted = pressedButtons.insert(button).inserted
            if inserted, pressedButtons.count == 1, activeDirection == nil {
                firstPressAt = time
            }
            return nil
        }

        pressedButtons.remove(button)
        guard pressedButtons.isEmpty else { return nil }
        firstPressAt = nil
        defer { activeDirection = nil }
        return activeDirection
    }

    public mutating func resolve(at time: TimeInterval) -> DPadDirection? {
        guard
            activeDirection == nil,
            !pressedButtons.isEmpty,
            let firstPressAt,
            time - firstPressAt >= coalescingInterval
        else {
            return nil
        }

        let x = (pressedButtons.contains(.right) ? 1 : 0)
            - (pressedButtons.contains(.left) ? 1 : 0)
        let y = (pressedButtons.contains(.down) ? 1 : 0)
            - (pressedButtons.contains(.up) ? 1 : 0)
        let direction = DPadInterpreter.direction(x: x, y: y)
        self.firstPressAt = nil
        activeDirection = direction
        return direction
    }
}

public struct DPadInterpreter: Sendable {
    public let coalescingInterval: TimeInterval
    public let releaseInterval: TimeInterval

    private var x = 0
    private var y = 0
    private var firstAxisAt: TimeInterval?
    private var lastInputAt: TimeInterval?
    private var activeDirection: DPadDirection?

    public init(coalescingInterval: TimeInterval = 0.012, releaseInterval: TimeInterval = 0.12) {
        self.coalescingInterval = coalescingInterval
        self.releaseInterval = releaseInterval
    }

    public mutating func ingest(axis: DPadAxis, value: Int, at time: TimeInterval) {
        if let lastInputAt, time - lastInputAt > releaseInterval {
            x = 0
            y = 0
            activeDirection = nil
            firstAxisAt = nil
        }
        if firstAxisAt == nil { firstAxisAt = time }
        lastInputAt = time
        switch axis {
        case .x: x = value
        case .y: y = value
        }
    }

    public mutating func resolve(at time: TimeInterval) -> DPadDirection? {
        guard let firstAxisAt, time - firstAxisAt >= coalescingInterval else { return nil }
        let direction = Self.direction(x: x, y: y)
        self.firstAxisAt = nil
        x = 0
        y = 0
        // One physical deflection produces at most one action. Moving
        // through a cardinal direction on the way to/from a diagonal must
        // not trigger neighboring bindings.
        guard activeDirection == nil else { return nil }
        activeDirection = direction
        return direction
    }

    public mutating func releaseIfIdle(at time: TimeInterval) -> DPadDirection? {
        guard let lastInputAt, time - lastInputAt >= releaseInterval else { return nil }
        defer {
            activeDirection = nil
            self.lastInputAt = nil
            firstAxisAt = nil
            x = 0
            y = 0
        }
        return activeDirection
    }

    public static func direction(x: Int, y: Int) -> DPadDirection? {
        let sx = x == 0 ? 0 : (x > 0 ? 1 : -1)
        let sy = y == 0 ? 0 : (y > 0 ? 1 : -1)
        return switch (sx, sy) {
        case (0, -1): .up
        case (1, -1): .upRight
        case (1, 0): .right
        case (1, 1): .downRight
        case (0, 1): .down
        case (-1, 1): .downLeft
        case (-1, 0): .left
        case (-1, -1): .upLeft
        default: nil
        }
    }
}
