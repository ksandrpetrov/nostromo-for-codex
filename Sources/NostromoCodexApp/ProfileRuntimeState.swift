import Foundation
import NostromoCodexCore

/// Keeps transient profile selection separate from the profile persisted in
/// profiles.json. The value has no I/O or UI side effects and is safe to test
/// independently from AppModel.
struct ProfileRuntimeState: Equatable, Sendable {
    private struct Hold: Equatable, Sendable {
        let control: ControlID
        let target: UUID
    }

    private(set) var persistentProfileID: UUID
    private var momentaryHolds: [Hold] = []
    private var momentaryBaseProfileID: UUID?

    init(persistentProfileID: UUID) {
        self.persistentProfileID = persistentProfileID
    }

    mutating func selectPersistent(_ profileID: UUID) {
        momentaryHolds.removeAll()
        momentaryBaseProfileID = nil
        persistentProfileID = profileID
    }

    @discardableResult
    mutating func beginMomentary(control: ControlID, target: UUID) -> UUID {
        if momentaryHolds.isEmpty {
            momentaryBaseProfileID = persistentProfileID
        }
        momentaryHolds.append(Hold(control: control, target: target))
        return target
    }

    /// Returns a new visible profile only when releasing this control changes
    /// the top of the momentary stack.
    mutating func releaseMomentary(control: ControlID) -> UUID? {
        guard let index = momentaryHolds.firstIndex(where: { $0.control == control }) else {
            return nil
        }
        let wasTopmost = index == momentaryHolds.index(before: momentaryHolds.endIndex)
        momentaryHolds.remove(at: index)
        guard wasTopmost else { return nil }

        if let next = momentaryHolds.last?.target {
            return next
        }
        let base = momentaryBaseProfileID ?? persistentProfileID
        momentaryBaseProfileID = nil
        return base
    }

    @discardableResult
    mutating func restorePersistent() -> UUID {
        momentaryHolds.removeAll()
        momentaryBaseProfileID = nil
        return persistentProfileID
    }

    func persistedSnapshot(of configuration: AppConfiguration) -> AppConfiguration {
        var snapshot = configuration
        if snapshot.profiles.contains(where: { $0.id == persistentProfileID }) {
            snapshot.activeProfileID = persistentProfileID
        }
        return snapshot
    }
}
