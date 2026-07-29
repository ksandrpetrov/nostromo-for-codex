import Foundation

public enum PushToTalkOutput: Equatable, Sendable {
    case start
    case stop
    case latched
    case unlatched
}

public struct PushToTalkGestureMachine: Sendable {
    public let doublePressInterval: TimeInterval
    public private(set) var isLatched = false

    private var lastReleaseAt: TimeInterval?
    private var suppressRelease = false

    public init(doublePressInterval: TimeInterval = 0.34) {
        self.doublePressInterval = doublePressInterval
    }

    public mutating func press(at time: TimeInterval) -> [PushToTalkOutput] {
        if isLatched {
            isLatched = false
            suppressRelease = true
            lastReleaseAt = nil
            return [.stop, .unlatched]
        }

        if let lastReleaseAt, time - lastReleaseAt <= doublePressInterval {
            isLatched = true
            suppressRelease = true
            self.lastReleaseAt = nil
            return [.start, .latched]
        }

        suppressRelease = false
        return [.start]
    }

    public mutating func release(at time: TimeInterval) -> [PushToTalkOutput] {
        if suppressRelease {
            suppressRelease = false
            return []
        }
        guard !isLatched else { return [] }
        lastReleaseAt = time
        return [.stop]
    }
}
