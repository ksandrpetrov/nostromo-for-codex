import Foundation
@preconcurrency import IOKit.hid

enum NostromoKeyMappingSnapshot: Equatable, Sendable, Codable {
    case missing
    case value(Data)

    private enum Kind: String, Codable {
        case missing
        case value
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case data
    }

    init(property: AnyObject?) throws {
        guard let property else {
            self = .missing
            return
        }
        guard
            PropertyListSerialization.propertyList(
                property,
                isValidFor: .binary
            )
        else {
            throw NostromoKeyboardRecoveryError.invalidPropertyList
        }
        self = .value(
            try PropertyListSerialization.data(
                fromPropertyList: property,
                format: .binary,
                options: 0
            )
        )
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .missing:
            guard !container.contains(.data) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .data,
                    in: container,
                    debugDescription: "Missing mappings cannot contain data."
                )
            }
            self = .missing
        case .value:
            let data = try container.decode(Data.self, forKey: .data)
            _ = try Self.decodePropertyList(from: data)
            self = .value(data)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .missing:
            try container.encode(Kind.missing, forKey: .kind)
        case let .value(data):
            try container.encode(Kind.value, forKey: .kind)
            try container.encode(data, forKey: .data)
        }
    }

    var restorationProperty: AnyObject {
        get throws {
            switch self {
            case .missing:
                // IOHID exposes no remove-property operation. An empty mapping
                // is its canonical representation of no UserKeyMapping.
                return NSArray()
            case let .value(data):
                return try Self.decodePropertyList(from: data) as AnyObject
            }
        }
    }

    private static func decodePropertyList(from data: Data) throws -> Any {
        try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
    }
}

enum NostromoKeyboardRecoveryError: Error {
    case invalidPropertyList
}

struct NostromoKeyboardRecoverySnapshot: Codable, Equatable, Sendable {
    let registryID: UInt64
    let originalMapping: NostromoKeyMappingSnapshot
    let suppressedUsages: Set<UInt32>
    let appliedMapping: NostromoKeyMappingSnapshot?

    init(
        registryID: UInt64,
        originalMapping: NostromoKeyMappingSnapshot,
        suppressedUsages: Set<UInt32> = [],
        appliedMapping: NostromoKeyMappingSnapshot? = nil
    ) {
        self.registryID = registryID
        self.originalMapping = originalMapping
        self.suppressedUsages = suppressedUsages
        self.appliedMapping = appliedMapping
    }

    private enum CodingKeys: String, CodingKey {
        case registryID
        case originalMapping
        case suppressedUsages
        case appliedMapping
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        registryID = try container.decode(UInt64.self, forKey: .registryID)
        originalMapping = try container.decode(
            NostromoKeyMappingSnapshot.self,
            forKey: .originalMapping
        )
        suppressedUsages = try container.decodeIfPresent(
            Set<UInt32>.self,
            forKey: .suppressedUsages
        ) ?? []
        appliedMapping = try container.decodeIfPresent(
            NostromoKeyMappingSnapshot.self,
            forKey: .appliedMapping
        )
    }
}

struct NostromoKeyboardServiceIdentity: Equatable, Sendable {
    let registryID: UInt64
    let vendorID: Int?
    let productID: Int?
    let isKeyboard: Bool
}

@MainActor
protocol NostromoKeyboardServicePropertyAccessing: AnyObject {
    func targetKeyboardServices() -> [NostromoKeyboardServiceIdentity]
    func copyMapping(registryID: UInt64) -> AnyObject?
    func setMapping(registryID: UInt64, property: AnyObject) -> Bool
}

@MainActor
final class IOKitNostromoKeyboardServicePropertyAccess:
    NostromoKeyboardServicePropertyAccessing
{
    private let client: IOHIDEventSystemClient
    private var servicesByRegistryID: [UInt64: IOHIDServiceClient] = [:]

    init(
        client: IOHIDEventSystemClient =
            IOHIDEventSystemClientCreateSimpleClient(nil)
    ) {
        self.client = client
    }

    func targetKeyboardServices() -> [NostromoKeyboardServiceIdentity] {
        guard
            let services = IOHIDEventSystemClientCopyServices(client)
                as? [IOHIDServiceClient]
        else {
            servicesByRegistryID = [:]
            return []
        }

        var refreshed: [UInt64: IOHIDServiceClient] = [:]
        let identities: [NostromoKeyboardServiceIdentity] =
            services.compactMap {
                service -> NostromoKeyboardServiceIdentity? in
            let identity = NostromoKeyboardServiceIdentity(
                registryID: serviceRegistryID(service),
                vendorID: Self.integerProperty(
                    kIOHIDVendorIDKey,
                    from: service
                ),
                productID: Self.integerProperty(
                    kIOHIDProductIDKey,
                    from: service
                ),
                isKeyboard: IOHIDServiceClientConformsTo(
                    service,
                    UInt32(kHIDPage_GenericDesktop),
                    UInt32(kHIDUsage_GD_Keyboard)
                ) != 0
            )
            guard
                NostromoKeyboardRecoveryPlanner.isTargetKeyboard(identity)
            else {
                return nil
            }
            guard refreshed[identity.registryID] == nil else {
                return nil
            }
            refreshed[identity.registryID] = service
            return identity
        }
        servicesByRegistryID = refreshed
        return identities
    }

    func copyMapping(registryID: UInt64) -> AnyObject? {
        guard let service = servicesByRegistryID[registryID] else {
            return nil
        }
        return IOHIDServiceClientCopyProperty(
            service,
            kIOHIDUserKeyUsageMapKey as CFString
        )
    }

    func setMapping(
        registryID: UInt64,
        property: AnyObject
    ) -> Bool {
        guard let service = servicesByRegistryID[registryID] else {
            return false
        }
        return IOHIDServiceClientSetProperty(
            service,
            kIOHIDUserKeyUsageMapKey as CFString,
            property
        )
    }

    private func serviceRegistryID(
        _ service: IOHIDServiceClient
    ) -> UInt64 {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
            ?? UInt64(CFHash(service))
    }

    private static func integerProperty(
        _ key: String,
        from service: IOHIDServiceClient
    ) -> Int? {
        (IOHIDServiceClientCopyProperty(
            service,
            key as CFString
        ) as? NSNumber)?.intValue
    }
}

struct NostromoKeyboardRecoveryAssignment: Equatable, Sendable {
    let snapshotRegistryID: UInt64
    let serviceRegistryID: UInt64
}

struct NostromoKeyboardRecoveryAttempt: Equatable, Sendable {
    let restoredSnapshotRegistryIDs: Set<UInt64>
    let remainingSnapshots: [NostromoKeyboardRecoverySnapshot]
}

enum NostromoKeyboardRecoveryPlanner {
    static let targetVendorID = 0x1532
    static let targetProductID = 0x0111

    static func isTargetKeyboard(
        _ service: NostromoKeyboardServiceIdentity
    ) -> Bool {
        service.vendorID == targetVendorID
            && service.productID == targetProductID
            && service.isKeyboard
    }

    static func assignments(
        snapshots: [NostromoKeyboardRecoverySnapshot],
        services: [NostromoKeyboardServiceIdentity]
    ) -> [NostromoKeyboardRecoveryAssignment] {
        let eligibleServices = services.filter(isTargetKeyboard)
        let snapshotGroups = Dictionary(grouping: snapshots, by: \.registryID)
        let serviceGroups = Dictionary(grouping: eligibleServices, by: \.registryID)
        guard
            snapshotGroups.values.allSatisfy({ $0.count == 1 }),
            serviceGroups.values.allSatisfy({ $0.count == 1 })
        else {
            return []
        }

        var result: [NostromoKeyboardRecoveryAssignment] = []
        var matchedSnapshotIDs: Set<UInt64> = []
        var matchedServiceIDs: Set<UInt64> = []
        for snapshot in snapshots where serviceGroups[snapshot.registryID] != nil {
            result.append(
                NostromoKeyboardRecoveryAssignment(
                    snapshotRegistryID: snapshot.registryID,
                    serviceRegistryID: snapshot.registryID
                )
            )
            matchedSnapshotIDs.insert(snapshot.registryID)
            matchedServiceIDs.insert(snapshot.registryID)
        }

        let unmatchedSnapshots = snapshots.filter {
            !matchedSnapshotIDs.contains($0.registryID)
        }
        let unmatchedServices = eligibleServices.filter {
            !matchedServiceIDs.contains($0.registryID)
        }
        if unmatchedSnapshots.count == 1, unmatchedServices.count == 1 {
            result.append(
                NostromoKeyboardRecoveryAssignment(
                    snapshotRegistryID: unmatchedSnapshots[0].registryID,
                    serviceRegistryID: unmatchedServices[0].registryID
                )
            )
        }
        return result
    }

    static func attemptRecovery(
        snapshots: [NostromoKeyboardRecoverySnapshot],
        services: [NostromoKeyboardServiceIdentity],
        restore: (
            NostromoKeyboardRecoverySnapshot,
            NostromoKeyboardServiceIdentity
        ) -> Bool
    ) -> NostromoKeyboardRecoveryAttempt {
        let snapshotGroups = Dictionary(grouping: snapshots, by: \.registryID)
        let eligibleServices = services.filter(isTargetKeyboard)
        let serviceGroups = Dictionary(
            grouping: eligibleServices,
            by: \.registryID
        )
        guard
            snapshotGroups.values.allSatisfy({ $0.count == 1 }),
            serviceGroups.values.allSatisfy({ $0.count == 1 })
        else {
            return NostromoKeyboardRecoveryAttempt(
                restoredSnapshotRegistryIDs: [],
                remainingSnapshots: snapshots
            )
        }
        let snapshotByID = Dictionary(
            uniqueKeysWithValues: snapshots.map { ($0.registryID, $0) }
        )
        let serviceByID = Dictionary(
            uniqueKeysWithValues: eligibleServices.map { ($0.registryID, $0) }
        )
        var restored: Set<UInt64> = []
        for assignment in assignments(snapshots: snapshots, services: services) {
            guard
                let snapshot = snapshotByID[assignment.snapshotRegistryID],
                let service = serviceByID[assignment.serviceRegistryID],
                restore(snapshot, service)
            else {
                continue
            }
            restored.insert(snapshot.registryID)
        }
        return NostromoKeyboardRecoveryAttempt(
            restoredSnapshotRegistryIDs: restored,
            remainingSnapshots: snapshots.filter {
                !restored.contains($0.registryID)
            }
        )
    }
}

enum NostromoKeyboardRecoveryLoadResult: Equatable, Sendable {
    case absent
    case snapshots([NostromoKeyboardRecoverySnapshot])
    case invalid
}

protocol NostromoKeyboardRecoveryStoring: AnyObject {
    func load() -> NostromoKeyboardRecoveryLoadResult

    @discardableResult
    func replace(
        with snapshots: [NostromoKeyboardRecoverySnapshot]
    ) -> Bool
}

private enum NostromoKeyboardRecoveryCodec {
    private struct Envelope: Codable {
        let version: Int
        let snapshots: [NostromoKeyboardRecoverySnapshot]
    }

    static func decode(_ data: Data) -> NostromoKeyboardRecoveryLoadResult {
        do {
            let envelope = try PropertyListDecoder().decode(
                Envelope.self,
                from: data
            )
            let registryIDs = envelope.snapshots.map(\.registryID)
            guard
                envelope.version == 1 || envelope.version == 2,
                !envelope.snapshots.isEmpty,
                Set(registryIDs).count == registryIDs.count
            else {
                return .invalid
            }
            return .snapshots(envelope.snapshots)
        } catch {
            return .invalid
        }
    }

    static func encode(
        _ snapshots: [NostromoKeyboardRecoverySnapshot]
    ) throws -> Data {
        let registryIDs = snapshots.map(\.registryID)
        guard
            !snapshots.isEmpty,
            Set(registryIDs).count == registryIDs.count
        else {
            throw NostromoKeyboardRecoveryError.invalidPropertyList
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(
            Envelope(version: 2, snapshots: snapshots)
        )
    }
}

/// Legacy reader retained only so existing v1 recovery markers can be moved
/// to the atomic Application Support file.
final class UserDefaultsNostromoKeyboardRecoveryStore:
    NostromoKeyboardRecoveryStoring
{
    static let productionKey =
        "io.nostromo-codex.hid.user-key-mapping-recovery.v1"

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = productionKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> NostromoKeyboardRecoveryLoadResult {
        guard let storedValue = defaults.object(forKey: key) else {
            return .absent
        }
        guard let data = storedValue as? Data else {
            return .invalid
        }
        return NostromoKeyboardRecoveryCodec.decode(data)
    }

    @discardableResult
    func replace(
        with snapshots: [NostromoKeyboardRecoverySnapshot]
    ) -> Bool {
        if snapshots.isEmpty {
            defaults.removeObject(forKey: key)
            return defaults.synchronize()
                && defaults.object(forKey: key) == nil
        }

        let registryIDs = snapshots.map(\.registryID)
        guard Set(registryIDs).count == registryIDs.count else {
            return false
        }
        do {
            let data = try NostromoKeyboardRecoveryCodec.encode(snapshots)
            defaults.set(data, forKey: key)
            return defaults.synchronize()
                && defaults.data(forKey: key) == data
        } catch {
            return false
        }
    }
}

final class AtomicNostromoKeyboardRecoveryStore:
    NostromoKeyboardRecoveryStoring
{
    static let productionFileName =
        "hid-user-key-mapping-recovery-v2.plist"

    private let fileURL: URL
    private let fileManager: FileManager
    private let legacyStore: UserDefaultsNostromoKeyboardRecoveryStore?

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        legacyStore: UserDefaultsNostromoKeyboardRecoveryStore? =
            UserDefaultsNostromoKeyboardRecoveryStore()
    ) {
        self.fileManager = fileManager
        self.legacyStore = legacyStore
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent("Nostromo Codex", isDirectory: true)
            .appendingPathComponent(Self.productionFileName)
        }
    }

    func load() -> NostromoKeyboardRecoveryLoadResult {
        if fileManager.fileExists(atPath: fileURL.path) {
            guard let data = try? Data(contentsOf: fileURL) else {
                return .invalid
            }
            return NostromoKeyboardRecoveryCodec.decode(data)
        }

        guard let legacyStore else { return .absent }
        let legacy = legacyStore.load()
        guard case let .snapshots(snapshots) = legacy else {
            return legacy
        }
        guard replace(with: snapshots) else {
            return .invalid
        }
        _ = legacyStore.replace(with: [])
        return .snapshots(snapshots)
    }

    @discardableResult
    func replace(
        with snapshots: [NostromoKeyboardRecoverySnapshot]
    ) -> Bool {
        if snapshots.isEmpty {
            do {
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(at: fileURL)
                }
                return !fileManager.fileExists(atPath: fileURL.path)
            } catch {
                return false
            }
        }

        do {
            let data = try NostromoKeyboardRecoveryCodec.encode(snapshots)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])
            return try Data(contentsOf: fileURL) == data
        } catch {
            return false
        }
    }
}

/// Prevents the Nostromo keyboard interface from also typing into the focused
/// macOS application while Nostromo Codex consumes the same physical controls.
///
/// `UserKeyMapping` is applied to the matching IOHID service only. Original
/// mappings are persisted before suppression so a later process can restore
/// them after an ungraceful termination.
///
/// AppModel is the MainActor owner of all calls. The suppressor registers no
/// asynchronous callback and does not publish its mutable snapshot dictionary.
@MainActor
final class NostromoKeyboardSuppressor: NostromoKeyboardSuppressing {
    private struct MappingPair: Equatable {
        let source: UInt64
        let destination: UInt64
    }

    private struct PropertyWriteResult {
        let setterReturned: Bool
        let readBackMatched: Bool

        var succeeded: Bool {
            readBackMatched
        }
    }

    private let serviceAccess: any NostromoKeyboardServicePropertyAccessing
    private let recoveryStore: any NostromoKeyboardRecoveryStoring
    private var activeSnapshots:
        [UInt64: NostromoKeyboardRecoverySnapshot] = [:]

    init(
        serviceAccess: any NostromoKeyboardServicePropertyAccessing =
            IOKitNostromoKeyboardServicePropertyAccess(),
        recoveryStore: any NostromoKeyboardRecoveryStoring =
            AtomicNostromoKeyboardRecoveryStore()
    ) {
        self.serviceAccess = serviceAccess
        self.recoveryStore = recoveryStore
    }

    func recover() -> NostromoKeyboardRestorationResult {
        recoverPendingSnapshots(
            using: serviceAccess.targetKeyboardServices(),
            excluding: []
        )
    }

    func suppress(usages: Set<UInt32>) -> NostromoInputProtectionStatus {
        guard !usages.isEmpty else {
            _ = restore()
            return .inactive
        }

        let services = serviceAccess.targetKeyboardServices()
        guard !services.isEmpty else {
            return .deviceUnavailable
        }
        let presentRegistryIDs = Set(services.map(\.registryID))
        let activePresentRegistryIDs = Set(activeSnapshots.keys)
            .intersection(presentRegistryIDs)
        let recovery = recoverPendingSnapshots(
            using: services,
            excluding: activePresentRegistryIDs
        )
        guard recovery.isComplete else {
            return .failed(
                NostromoKeyboardSuppressionFailure(
                    failures: recovery.failures.isEmpty
                        ? [
                            NostromoKeyboardServiceFailure(
                                registryID: nil,
                                stage: .recovery,
                                setterReturned: nil,
                                readBackMatched: nil,
                                detail:
                                    "Recovery marker не удалось сопоставить "
                                    + "с текущим HID-сервисом."
                            ),
                        ]
                        : recovery.failures,
                    recoveryPending: true
                )
            )
        }

        let persistedSnapshots: [NostromoKeyboardRecoverySnapshot]
        switch recoveryStore.load() {
        case .absent:
            persistedSnapshots = []
        case .invalid:
            return persistenceFailure(
                "Recovery marker повреждён; подавление не применено."
            )
        case let .snapshots(snapshots):
            persistedSnapshots = snapshots
        }

        var prepared: [NostromoKeyboardRecoverySnapshot] = []
        var desiredMappings: [UInt64: NSArray] = [:]
        var preparationFailures: [NostromoKeyboardServiceFailure] = []
        let persistedByID = Dictionary(
            uniqueKeysWithValues: persistedSnapshots.map {
                ($0.registryID, $0)
            }
        )

        for service in services {
            let registryID = service.registryID
            let current = serviceAccess.copyMapping(registryID: registryID)
            let original =
                activeSnapshots[registryID]?.originalMapping
                ?? persistedByID[registryID]?.originalMapping
            do {
                let desired = Self.mergedMapping(
                    existing: current,
                    suppressedUsages: usages
                ) as NSArray
                let snapshot = NostromoKeyboardRecoverySnapshot(
                    registryID: registryID,
                    originalMapping: try original
                        ?? NostromoKeyMappingSnapshot(property: current),
                    suppressedUsages: usages,
                    appliedMapping: try NostromoKeyMappingSnapshot(
                        property: desired
                    )
                )
                prepared.append(snapshot)
                desiredMappings[registryID] = desired
            } catch {
                preparationFailures.append(
                    NostromoKeyboardServiceFailure(
                        registryID: registryID,
                        stage: .snapshot,
                        setterReturned: nil,
                        readBackMatched: nil,
                        detail: "Текущее значение не является property list."
                    )
                )
            }
        }

        guard preparationFailures.isEmpty else {
            return .failed(
                NostromoKeyboardSuppressionFailure(
                    failures: preparationFailures,
                    recoveryPending: !persistedSnapshots.isEmpty
                )
            )
        }

        let preparedIDs = Set(prepared.map(\.registryID))
        let candidateSnapshots = persistedSnapshots.filter {
            !preparedIDs.contains($0.registryID)
        } + prepared
        guard recoveryStore.replace(with: candidateSnapshots) else {
            return persistenceFailure(
                "Не удалось атомарно сохранить recovery marker."
            )
        }
        activeSnapshots = Dictionary(
            uniqueKeysWithValues: prepared.map {
                ($0.registryID, $0)
            }
        )

        var applyFailures: [NostromoKeyboardServiceFailure] = []
        for snapshot in prepared {
            guard let desired = desiredMappings[snapshot.registryID] else {
                continue
            }
            let result = writeAndVerify(
                registryID: snapshot.registryID,
                property: desired
            )
            guard result.succeeded else {
                applyFailures.append(
                    NostromoKeyboardServiceFailure(
                        registryID: snapshot.registryID,
                        stage: result.setterReturned
                            ? .verification
                            : .apply,
                        setterReturned: result.setterReturned,
                        readBackMatched: result.readBackMatched,
                        detail:
                            "UserKeyMapping не подтверждён после записи."
                    )
                )
                continue
            }
        }

        guard applyFailures.isEmpty else {
            let rollback = rollback(snapshots: prepared)
            return .failed(
                NostromoKeyboardSuppressionFailure(
                    failures: applyFailures + rollback.failures,
                    recoveryPending: !rollback.isComplete
                )
            )
        }

        return .active(
            serviceCount: prepared.count,
            usageCount: usages.count
        )
    }

    func restore() -> NostromoKeyboardRestorationResult {
        recoverPendingSnapshots(
            using: serviceAccess.targetKeyboardServices(),
            excluding: []
        )
    }

    nonisolated static func mergedMapping(
        existing: AnyObject?,
        suppressedUsages: Set<UInt32>
    ) -> [[String: NSNumber]] {
        let sourceKey = kIOHIDKeyboardModifierMappingSrcKey as String
        let destinationKey = kIOHIDKeyboardModifierMappingDstKey as String
        let existingPairs = existing as? [[String: NSNumber]] ?? []
        let retainedPairs = existingPairs.filter { pair in
            guard let source = pair[sourceKey]?.uint64Value else { return true }
            let sourcePage = UInt32(source >> 32)
            let sourceUsage = UInt32(source & 0xFFFF_FFFF)
            return sourcePage != UInt32(kHIDPage_KeyboardOrKeypad)
                || !suppressedUsages.contains(sourceUsage)
        }

        let undefinedKeyboardUsage =
            UInt64(UInt32(kHIDPage_KeyboardOrKeypad)) << 32
        let suppressionPairs = suppressedUsages.sorted().map { usage in
            [
                sourceKey: NSNumber(
                    value:
                        (UInt64(UInt32(kHIDPage_KeyboardOrKeypad)) << 32)
                        | UInt64(usage)
                ),
                destinationKey: NSNumber(value: undefinedKeyboardUsage),
            ]
        }
        return retainedPairs + suppressionPairs
    }

    private func recoverPendingSnapshots(
        using services: [NostromoKeyboardServiceIdentity],
        excluding activeRegistryIDs: Set<UInt64>
    ) -> NostromoKeyboardRestorationResult {
        switch recoveryStore.load() {
        case .absent:
            if activeRegistryIDs.isEmpty {
                return .nothingPending
            }
            return NostromoKeyboardRestorationResult(
                restoredServiceCount: 0,
                pendingServiceCount: activeRegistryIDs.count,
                failures: [
                    NostromoKeyboardServiceFailure(
                        registryID: nil,
                        stage: .recoveryStore,
                        setterReturned: nil,
                        readBackMatched: nil,
                        detail:
                            "Активное mapping-состояние не имеет recovery marker."
                    ),
                ]
            )
        case .invalid:
            return NostromoKeyboardRestorationResult(
                restoredServiceCount: 0,
                pendingServiceCount: 1,
                failures: [
                    NostromoKeyboardServiceFailure(
                        registryID: nil,
                        stage: .recoveryStore,
                        setterReturned: nil,
                        readBackMatched: nil,
                        detail: "Recovery marker повреждён или несовместим."
                    ),
                ]
            )
        case let .snapshots(snapshots):
            let persistedRegistryIDs = Set(snapshots.map(\.registryID))
            guard activeRegistryIDs.isSubset(of: persistedRegistryIDs) else {
                return NostromoKeyboardRestorationResult(
                    restoredServiceCount: 0,
                    pendingServiceCount: snapshots.count,
                    failures: [
                        NostromoKeyboardServiceFailure(
                            registryID: nil,
                            stage: .recoveryStore,
                            setterReturned: nil,
                            readBackMatched: nil,
                            detail:
                                "Recovery marker не содержит активный сервис."
                        ),
                    ]
                )
            }

            let recoverableSnapshots = snapshots.filter {
                !activeRegistryIDs.contains($0.registryID)
            }
            let recoverableServices = services.filter {
                !activeRegistryIDs.contains($0.registryID)
            }
            let assignments = NostromoKeyboardRecoveryPlanner.assignments(
                snapshots: recoverableSnapshots,
                services: recoverableServices
            )

            let snapshotByID = Dictionary(
                uniqueKeysWithValues: recoverableSnapshots.map {
                    ($0.registryID, $0)
                }
            )
            var restoredSnapshotIDs: Set<UInt64> = []
            var failures: [NostromoKeyboardServiceFailure] = []
            for assignment in assignments {
                guard
                    let snapshot = snapshotByID[
                        assignment.snapshotRegistryID
                    ],
                    let property = restorationProperty(
                        for: snapshot,
                        current: serviceAccess.copyMapping(
                            registryID: assignment.serviceRegistryID
                        )
                    )
                else {
                    failures.append(
                        NostromoKeyboardServiceFailure(
                            registryID: assignment.serviceRegistryID,
                            stage: .recovery,
                            setterReturned: nil,
                            readBackMatched: nil,
                            detail:
                                "Не удалось построить mapping для восстановления."
                        )
                    )
                    continue
                }
                let result = writeAndVerify(
                    registryID: assignment.serviceRegistryID,
                    property: property
                )
                if result.succeeded {
                    restoredSnapshotIDs.insert(
                        assignment.snapshotRegistryID
                    )
                    activeSnapshots.removeValue(
                        forKey: assignment.snapshotRegistryID
                    )
                } else {
                    failures.append(
                        NostromoKeyboardServiceFailure(
                            registryID: assignment.serviceRegistryID,
                            stage: .recovery,
                            setterReturned: result.setterReturned,
                            readBackMatched: result.readBackMatched,
                            detail:
                                "Восстановление mapping не подтверждено."
                        )
                    )
                }
            }

            let remainingSnapshots = snapshots.filter {
                !restoredSnapshotIDs.contains($0.registryID)
            }
            if !restoredSnapshotIDs.isEmpty {
                guard recoveryStore.replace(with: remainingSnapshots) else {
                    failures.append(
                        NostromoKeyboardServiceFailure(
                            registryID: nil,
                            stage: .persistence,
                            setterReturned: nil,
                            readBackMatched: nil,
                            detail:
                                "Восстановление применено, но recovery marker "
                                + "не удалось обновить."
                        )
                    )
                    return NostromoKeyboardRestorationResult(
                        restoredServiceCount: restoredSnapshotIDs.count,
                        pendingServiceCount: snapshots.count,
                        failures: failures
                    )
                }
            }

            let unresolved = remainingSnapshots.filter {
                !activeRegistryIDs.contains($0.registryID)
            }
            return NostromoKeyboardRestorationResult(
                restoredServiceCount: restoredSnapshotIDs.count,
                pendingServiceCount: unresolved.count,
                failures: failures
            )
        }
    }

    private func rollback(
        snapshots: [NostromoKeyboardRecoverySnapshot]
    ) -> NostromoKeyboardRestorationResult {
        var restoredIDs: Set<UInt64> = []
        var failures: [NostromoKeyboardServiceFailure] = []
        for snapshot in snapshots {
            guard
                let property = restorationProperty(
                    for: snapshot,
                    current: serviceAccess.copyMapping(
                        registryID: snapshot.registryID
                    )
                )
            else {
                failures.append(
                    NostromoKeyboardServiceFailure(
                        registryID: snapshot.registryID,
                        stage: .rollback,
                        setterReturned: nil,
                        readBackMatched: nil,
                        detail: "Не удалось построить rollback mapping."
                    )
                )
                continue
            }
            let result = writeAndVerify(
                registryID: snapshot.registryID,
                property: property
            )
            if result.succeeded {
                restoredIDs.insert(snapshot.registryID)
                activeSnapshots.removeValue(forKey: snapshot.registryID)
            } else {
                failures.append(
                    NostromoKeyboardServiceFailure(
                        registryID: snapshot.registryID,
                        stage: .rollback,
                        setterReturned: result.setterReturned,
                        readBackMatched: result.readBackMatched,
                        detail: "Rollback mapping не подтверждён."
                    )
                )
            }
        }

        let remaining = snapshots.filter {
            !restoredIDs.contains($0.registryID)
        }
        if !recoveryStore.replace(with: remaining) {
            failures.append(
                NostromoKeyboardServiceFailure(
                    registryID: nil,
                    stage: .persistence,
                    setterReturned: nil,
                    readBackMatched: nil,
                    detail: "Не удалось обновить marker после rollback."
                )
            )
            return NostromoKeyboardRestorationResult(
                restoredServiceCount: restoredIDs.count,
                pendingServiceCount: snapshots.count,
                failures: failures
            )
        }
        return NostromoKeyboardRestorationResult(
            restoredServiceCount: restoredIDs.count,
            pendingServiceCount: remaining.count,
            failures: failures
        )
    }

    private func writeAndVerify(
        registryID: UInt64,
        property: AnyObject
    ) -> PropertyWriteResult {
        let setterReturned = serviceAccess.setMapping(
            registryID: registryID,
            property: property
        )
        let readBack = serviceAccess.copyMapping(registryID: registryID)
        return PropertyWriteResult(
            setterReturned: setterReturned,
            readBackMatched: Self.mappingsEquivalent(
                readBack,
                property
            )
        )
    }

    private func restorationProperty(
        for snapshot: NostromoKeyboardRecoverySnapshot,
        current: AnyObject?
    ) -> AnyObject? {
        guard
            !snapshot.suppressedUsages.isEmpty,
            snapshot.appliedMapping != nil
        else {
            return try? snapshot.originalMapping.restorationProperty
        }
        guard
            let currentPairs = Self.mappingDictionaries(current),
            let originalProperty = try? snapshot.originalMapping
                .restorationProperty,
            let originalPairs = Self.mappingDictionaries(originalProperty)
        else {
            return try? snapshot.originalMapping.restorationProperty
        }

        let sourceKey = kIOHIDKeyboardModifierMappingSrcKey as String
        let destinationKey =
            kIOHIDKeyboardModifierMappingDstKey as String
        let keyboardPage =
            UInt64(UInt32(kHIDPage_KeyboardOrKeypad)) << 32
        var result = currentPairs.filter { pair in
            guard
                let source = pair[sourceKey]?.uint64Value,
                let destination = pair[destinationKey]?.uint64Value
            else {
                return true
            }
            let usage = UInt32(source & 0xFFFF_FFFF)
            return !snapshot.suppressedUsages.contains(usage)
                || source >> 32
                    != UInt64(UInt32(kHIDPage_KeyboardOrKeypad))
                || destination != keyboardPage
        }
        for pair in originalPairs {
            guard let source = pair[sourceKey]?.uint64Value else {
                continue
            }
            let usage = UInt32(source & 0xFFFF_FFFF)
            guard snapshot.suppressedUsages.contains(usage) else {
                continue
            }
            let hasExternalReplacement = result.contains {
                $0[sourceKey]?.uint64Value == source
            }
            if !hasExternalReplacement {
                result.append(pair)
            }
        }
        return result as NSArray
    }

    private static func mappingsEquivalent(
        _ lhs: AnyObject?,
        _ rhs: AnyObject?
    ) -> Bool {
        guard
            let lhsPairs = mappingPairs(lhs),
            let rhsPairs = mappingPairs(rhs)
        else {
            return false
        }
        return lhsPairs.sorted(by: pairOrdering)
            == rhsPairs.sorted(by: pairOrdering)
    }

    private static func mappingDictionaries(
        _ property: AnyObject?
    ) -> [[String: NSNumber]]? {
        guard let property else { return [] }
        return property as? [[String: NSNumber]]
    }

    private static func mappingPairs(
        _ property: AnyObject?
    ) -> [MappingPair]? {
        guard let dictionaries = mappingDictionaries(property) else {
            return nil
        }
        let sourceKey = kIOHIDKeyboardModifierMappingSrcKey as String
        let destinationKey =
            kIOHIDKeyboardModifierMappingDstKey as String
        var result: [MappingPair] = []
        for pair in dictionaries {
            guard
                let source = pair[sourceKey]?.uint64Value,
                let destination = pair[destinationKey]?.uint64Value
            else {
                return nil
            }
            result.append(
                MappingPair(
                    source: source,
                    destination: destination
                )
            )
        }
        return result
    }

    private static func pairOrdering(
        _ lhs: MappingPair,
        _ rhs: MappingPair
    ) -> Bool {
        if lhs.source != rhs.source {
            return lhs.source < rhs.source
        }
        return lhs.destination < rhs.destination
    }

    private func persistenceFailure(
        _ detail: String
    ) -> NostromoInputProtectionStatus {
        .failed(
            NostromoKeyboardSuppressionFailure(
                failures: [
                    NostromoKeyboardServiceFailure(
                        registryID: nil,
                        stage: .persistence,
                        setterReturned: nil,
                        readBackMatched: nil,
                        detail: detail
                    ),
                ],
                recoveryPending: true
            )
        )
    }
}
