import Foundation

public struct InputReconnectGate: Sendable {
    public var settlingInterval: TimeInterval
    public var dpadIdleInterval: TimeInterval

    private var acceptAfter: TimeInterval = 0
    private var suppressedButtons: Set<String> = []
    private var suppressDPad = false
    private var lastSuppressedDPadEvent: TimeInterval?

    public init(
        settlingInterval: TimeInterval = 0.25,
        dpadIdleInterval: TimeInterval = 0.13
    ) {
        self.settlingInterval = settlingInterval
        self.dpadIdleInterval = dpadIdleInterval
    }

    public mutating func reconnect(at time: TimeInterval) {
        acceptAfter = time + settlingInterval
        suppressedButtons.removeAll(keepingCapacity: true)
        suppressDPad = false
        lastSuppressedDPadEvent = nil
    }

    public mutating func extendSettlingPeriod(at time: TimeInterval) {
        acceptAfter = max(acceptAfter, time + settlingInterval)
    }

    public mutating func reset() {
        acceptAfter = 0
        suppressedButtons.removeAll(keepingCapacity: true)
        suppressDPad = false
        lastSuppressedDPadEvent = nil
    }

    public mutating func shouldForward(
        signature: HIDSignature,
        value: Int,
        at time: TimeInterval
    ) -> Bool {
        if signature.kind == .button {
            let key = signature.portableKey
            if time < acceptAfter {
                if value != 0 {
                    suppressedButtons.insert(key)
                } else {
                    suppressedButtons.remove(key)
                }
                return false
            }
            if suppressedButtons.contains(key) {
                if value == 0 {
                    suppressedButtons.remove(key)
                }
                return false
            }
            return true
        }

        let isDPadAxis = signature.usagePage == 0x01
            && (signature.usage == 0x30 || signature.usage == 0x31)
        guard isDPadAxis else {
            return time >= acceptAfter
        }

        if suppressDPad {
            let wasIdle = lastSuppressedDPadEvent.map {
                time - $0 >= dpadIdleInterval
            } ?? false
            if wasIdle, time >= acceptAfter {
                suppressDPad = false
                lastSuppressedDPadEvent = nil
                return true
            }
            lastSuppressedDPadEvent = time
            return false
        }

        guard time >= acceptAfter else {
            suppressDPad = true
            lastSuppressedDPadEvent = time
            return false
        }
        return true
    }
}
