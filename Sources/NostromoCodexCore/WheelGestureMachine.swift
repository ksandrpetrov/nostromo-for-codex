import Foundation

public enum WheelMode: String, Codable, CaseIterable, Sendable {
    case scroll
    case reasoning
}

public enum WheelOutput: Equatable, Sendable {
    case scroll(Int)
    case reasoning(Int)
    case modeChanged(WheelMode)
    case openSettings
}

public struct WheelGestureMachine: Sendable {
    public private(set) var mode: WheelMode
    public let longPressInterval: TimeInterval

    private var pressedAt: TimeInterval?
    private var rotatedWhilePressed = false
    private var longPressConsumed = false

    public init(mode: WheelMode = .scroll, longPressInterval: TimeInterval = 0.6) {
        self.mode = mode
        self.longPressInterval = longPressInterval
    }

    public mutating func press(at time: TimeInterval) {
        pressedAt = time
        rotatedWhilePressed = false
        longPressConsumed = false
    }

    public mutating func rotate(delta: Int, at _: TimeInterval) -> [WheelOutput] {
        guard delta != 0 else { return [] }
        if pressedAt != nil {
            rotatedWhilePressed = true
            return [.reasoning(delta)]
        }
        return mode == .scroll ? [.scroll(delta)] : [.reasoning(delta)]
    }

    public mutating func longPressFired(at time: TimeInterval) -> [WheelOutput] {
        guard
            let pressedAt,
            !rotatedWhilePressed,
            !longPressConsumed,
            time - pressedAt >= longPressInterval
        else { return [] }
        longPressConsumed = true
        return [.openSettings]
    }

    public mutating func release(at _: TimeInterval) -> [WheelOutput] {
        defer {
            pressedAt = nil
            rotatedWhilePressed = false
            longPressConsumed = false
        }
        guard pressedAt != nil, !rotatedWhilePressed, !longPressConsumed else { return [] }
        mode = mode == .scroll ? .reasoning : .scroll
        return [.modeChanged(mode)]
    }
}
