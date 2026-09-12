import NostromoCodexCore

/// A calibration draft is transient until the facade commits the completed map.
/// Physical identities and release gating are owned together, not by UI fields.
struct CalibrationSession {
    private(set) var draft: CalibrationMap?
    private var queue: [ControlID] = []
    private var awaitingRelease: HIDSignature?
    private var buttons: Set<String> = []
    private var directions: Set<DPadDirection> = []

    var target: ControlID? { queue.first }

    mutating func begin(from map: CalibrationMap) {
        self = CalibrationSession()
        draft = map
        queue = ControlID.keypad + ControlID.dpad + [.wheelPress]
    }

    mutating func cancel() { self = CalibrationSession() }

    mutating func finish() {
        draft = nil
        buttons.removeAll()
        directions.removeAll()
        // Consume the final physical release even after persistence succeeds.
    }

    mutating func clearReleaseGate() { awaitingRelease = nil }

    mutating func consumesReleaseGate(signature: HIDSignature, value: Int) -> Bool {
        guard let awaitingRelease, signature.kind == .button else { return false }
        if value == 0, awaitingRelease.portableKey == signature.portableKey {
            self.awaitingRelease = nil
        }
        return true
    }

    /// Returns a validation message only for a duplicate physical control.
    mutating func recordButton(_ signature: HIDSignature, value: Int) -> String? {
        guard let target, !ControlID.dpad.contains(target), value != 0 else { return nil }
        awaitingRelease = signature
        guard buttons.insert(signature.portableKey).inserted else {
            return "Этот физический элемент уже записан. Отпустите его, затем нажмите \(target.title)."
        }
        draft?.signatures[target] = signature
        queue.removeFirst()
        return nil
    }

    mutating func recordDirection(_ direction: DPadDirection) -> String? {
        guard let target, ControlID.dpad.contains(target) else { return nil }
        guard directions.insert(direction).inserted else {
            return "Это направление уже записано. Верните крестовину в центр, затем нажмите \(target.title)."
        }
        if var draft {
            draft.dpadDirections = draft.dpadDirections.filter { $0.value != target }
            draft.dpadDirections[direction] = target
            self.draft = draft
        }
        queue.removeFirst()
        return nil
    }
}
