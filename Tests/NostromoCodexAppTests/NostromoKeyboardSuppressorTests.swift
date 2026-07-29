import Foundation
@testable import NostromoCodexApp
import XCTest

@MainActor
final class NostromoKeyboardSuppressorTests: XCTestCase {
    func testMergedMappingPreservesUnrelatedPairsAndReplacesSuppressedSource() throws {
        let sourceKey = "HIDKeyboardModifierMappingSrc"
        let destinationKey = "HIDKeyboardModifierMappingDst"
        let existing: [[String: NSNumber]] = [
            [
                sourceKey: NSNumber(value: UInt64(0x0000_0007_0000_0028)),
                destinationKey: NSNumber(value: UInt64(0x0000_0007_0000_0029)),
            ],
            [
                sourceKey: NSNumber(value: UInt64(0x0000_0007_0000_0014)),
                destinationKey: NSNumber(value: UInt64(0x0000_0007_0000_0004)),
            ],
        ]

        let merged = NostromoKeyboardSuppressor.mergedMapping(
            existing: existing as NSArray,
            suppressedUsages: [0x14, 0x4F]
        )

        XCTAssertEqual(merged.count, 3)
        XCTAssertTrue(merged.contains { pair in
            pair[sourceKey]?.uint64Value == 0x0000_0007_0000_0028
                && pair[destinationKey]?.uint64Value == 0x0000_0007_0000_0029
        })
        for usage: UInt64 in [0x14, 0x4F] {
            let source = 0x0000_0007_0000_0000 | usage
            let pair = try XCTUnwrap(
                merged.first { $0[sourceKey]?.uint64Value == source }
            )
            XCTAssertEqual(
                pair[destinationKey]?.uint64Value,
                0x0000_0007_0000_0000
            )
        }
    }

    func testRecoveryStoreDistinguishesMissingFromEmptyAcrossProcesses() throws {
        try withRecoveryDefaults { defaults in
            let missing = NostromoKeyboardRecoverySnapshot(
                registryID: 11,
                originalMapping: .missing
            )
            let empty = NostromoKeyboardRecoverySnapshot(
                registryID: 12,
                originalMapping: try NostromoKeyMappingSnapshot(
                    property: NSArray()
                )
            )
            let processA = UserDefaultsNostromoKeyboardRecoveryStore(
                defaults: defaults
            )
            XCTAssertTrue(processA.replace(with: [missing, empty]))

            let processB = UserDefaultsNostromoKeyboardRecoveryStore(
                defaults: defaults
            )
            let loaded = try loadedSnapshots(from: processB)
            XCTAssertEqual(loaded, [missing, empty])
            XCTAssertEqual(loaded[0].originalMapping, .missing)
            guard case .value = loaded[1].originalMapping else {
                return XCTFail("An empty mapping must remain a present value.")
            }
            let restoredEmpty = try loaded[1].originalMapping
                .restorationProperty
            XCTAssertEqual((restoredEmpty as? NSArray)?.count, 0)
        }
    }

    func testProcessBRestoresExactMappingAndConsumesMarker() throws {
        try withRecoveryDefaults { defaults in
            let sourceKey = "HIDKeyboardModifierMappingSrc"
            let destinationKey = "HIDKeyboardModifierMappingDst"
            let original: [[String: NSNumber]] = [
                [
                    sourceKey: NSNumber(
                        value: UInt64(0x0000_0007_0000_0028)
                    ),
                    destinationKey: NSNumber(
                        value: UInt64(0x0000_0007_0000_0029)
                    ),
                ],
                [
                    sourceKey: NSNumber(
                        value: UInt64(0x0000_0007_0000_0014)
                    ),
                    destinationKey: NSNumber(
                        value: UInt64(0x0000_0007_0000_0004)
                    ),
                ],
            ]
            let snapshot = NostromoKeyboardRecoverySnapshot(
                registryID: 41,
                originalMapping: try NostromoKeyMappingSnapshot(
                    property: original as NSArray
                )
            )
            let processA = UserDefaultsNostromoKeyboardRecoveryStore(
                defaults: defaults
            )
            XCTAssertTrue(processA.replace(with: [snapshot]))

            let processB = UserDefaultsNostromoKeyboardRecoveryStore(
                defaults: defaults
            )
            let loaded = try loadedSnapshots(from: processB)
            var restored: NSArray?
            let attempt = NostromoKeyboardRecoveryPlanner.attemptRecovery(
                snapshots: loaded,
                services: [targetService(registryID: 41)]
            ) { pending, _ in
                do {
                    restored = try pending.originalMapping
                        .restorationProperty as? NSArray
                    return restored != nil
                } catch {
                    return false
                }
            }

            XCTAssertEqual(attempt.restoredSnapshotRegistryIDs, [41])
            XCTAssertTrue(attempt.remainingSnapshots.isEmpty)
            XCTAssertTrue(restored?.isEqual(to: original) == true)
            XCTAssertTrue(processB.replace(with: attempt.remainingSnapshots))

            let processC = UserDefaultsNostromoKeyboardRecoveryStore(
                defaults: defaults
            )
            XCTAssertEqual(processC.load(), .absent)
        }
    }

    func testRecoveryMarkerIsRetainedWhenDeviceIsAbsentOrRestoreFails() throws {
        try withRecoveryDefaults { defaults in
            let snapshot = NostromoKeyboardRecoverySnapshot(
                registryID: 51,
                originalMapping: .missing
            )
            let processA = UserDefaultsNostromoKeyboardRecoveryStore(
                defaults: defaults
            )
            XCTAssertTrue(processA.replace(with: [snapshot]))

            let processB = UserDefaultsNostromoKeyboardRecoveryStore(
                defaults: defaults
            )
            let loaded = try loadedSnapshots(from: processB)
            let absentAttempt =
                NostromoKeyboardRecoveryPlanner.attemptRecovery(
                    snapshots: loaded,
                    services: []
                ) { _, _ in
                    XCTFail("No restore should be attempted without hardware.")
                    return true
                }
            XCTAssertTrue(
                absentAttempt.restoredSnapshotRegistryIDs.isEmpty
            )
            XCTAssertEqual(absentAttempt.remainingSnapshots, [snapshot])
            XCTAssertEqual(processB.load(), .snapshots([snapshot]))

            var restoreCalls = 0
            let failedAttempt =
                NostromoKeyboardRecoveryPlanner.attemptRecovery(
                    snapshots: loaded,
                    services: [targetService(registryID: 51)]
                ) { _, _ in
                    restoreCalls += 1
                    return false
                }
            XCTAssertEqual(restoreCalls, 1)
            XCTAssertTrue(
                failedAttempt.restoredSnapshotRegistryIDs.isEmpty
            )
            XCTAssertEqual(failedAttempt.remainingSnapshots, [snapshot])
            XCTAssertEqual(processB.load(), .snapshots([snapshot]))
        }
    }

    func testRegistryIDFallbackIsScopedAndRequiresUnambiguousMatch() {
        let snapshot = NostromoKeyboardRecoverySnapshot(
            registryID: 61,
            originalMapping: .missing
        )
        let foreignExactID = NostromoKeyboardServiceIdentity(
            registryID: 61,
            vendorID: 0x05AC,
            productID: 0x024F,
            isKeyboard: true
        )
        let nostromoNonKeyboard = NostromoKeyboardServiceIdentity(
            registryID: 62,
            vendorID: 0x1532,
            productID: 0x0111,
            isKeyboard: false
        )
        let reenumeratedNostromo = targetService(registryID: 63)

        XCTAssertEqual(
            NostromoKeyboardRecoveryPlanner.assignments(
                snapshots: [snapshot],
                services: [
                    foreignExactID,
                    nostromoNonKeyboard,
                    reenumeratedNostromo,
                ]
            ),
            [
                NostromoKeyboardRecoveryAssignment(
                    snapshotRegistryID: 61,
                    serviceRegistryID: 63
                ),
            ]
        )

        XCTAssertTrue(
            NostromoKeyboardRecoveryPlanner.assignments(
                snapshots: [snapshot],
                services: [
                    reenumeratedNostromo,
                    targetService(registryID: 64),
                ]
            ).isEmpty
        )
        XCTAssertTrue(
            NostromoKeyboardRecoveryPlanner.assignments(
                snapshots: [
                    snapshot,
                    NostromoKeyboardRecoverySnapshot(
                        registryID: 65,
                        originalMapping: .missing
                    ),
                ],
                services: [reenumeratedNostromo]
            ).isEmpty
        )
    }

    func testSetterFalseIsAcceptedOnlyWhenReadBackMatches() throws {
        let service = FakeKeyboardServiceAccess(
            services: [targetService(registryID: 101)],
            mappings: [101: mapping(sourceUsage: 0x14, destinationUsage: 0x04)]
        )
        service.setBehaviors[101] = [
            .init(appliesProperty: true, returnValue: false),
        ]
        let store = FakeKeyboardRecoveryStore()
        let suppressor = NostromoKeyboardSuppressor(
            serviceAccess: service,
            recoveryStore: store
        )

        XCTAssertEqual(
            suppressor.suppress(usages: [0x14]),
            .active(serviceCount: 1, usageCount: 1)
        )
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(service.setCalls.count, 1)

        let restoration = suppressor.restore()
        XCTAssertTrue(restoration.isComplete)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(
            mappingsEqual(
                service.mappings[101],
                mapping(sourceUsage: 0x14, destinationUsage: 0x04)
            )
        )
    }

    func testPartialApplyRollsBackEveryServiceAndConsumesMarker() {
        let originalOne = mapping(
            sourceUsage: 0x14,
            destinationUsage: 0x04
        )
        let originalTwo = mapping(
            sourceUsage: 0x15,
            destinationUsage: 0x05
        )
        let service = FakeKeyboardServiceAccess(
            services: [
                targetService(registryID: 111),
                targetService(registryID: 112),
            ],
            mappings: [111: originalOne, 112: originalTwo]
        )
        service.setBehaviors[111] = [
            .init(appliesProperty: true, returnValue: true),
            .init(appliesProperty: true, returnValue: true),
        ]
        service.setBehaviors[112] = [
            .init(appliesProperty: false, returnValue: false),
            .init(appliesProperty: true, returnValue: true),
        ]
        let store = FakeKeyboardRecoveryStore()
        let suppressor = NostromoKeyboardSuppressor(
            serviceAccess: service,
            recoveryStore: store
        )

        guard case let .failed(failure) =
            suppressor.suppress(usages: [0x14, 0x15])
        else {
            return XCTFail("A rejected service must fail the transaction.")
        }
        XCTAssertFalse(failure.recoveryPending)
        XCTAssertEqual(failure.failures.first?.registryID, 112)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(mappingsEqual(service.mappings[111], originalOne))
        XCTAssertTrue(mappingsEqual(service.mappings[112], originalTwo))
    }

    func testFailedRollbackRemainsRecoverableByNextProcess() {
        let originalOne = mapping(
            sourceUsage: 0x14,
            destinationUsage: 0x04
        )
        let originalTwo = mapping(
            sourceUsage: 0x15,
            destinationUsage: 0x05
        )
        let service = FakeKeyboardServiceAccess(
            services: [
                targetService(registryID: 121),
                targetService(registryID: 122),
            ],
            mappings: [121: originalOne, 122: originalTwo]
        )
        service.setBehaviors[121] = [
            .init(appliesProperty: true, returnValue: true),
            .init(appliesProperty: false, returnValue: false),
        ]
        service.setBehaviors[122] = [
            .init(appliesProperty: false, returnValue: false),
            .init(appliesProperty: true, returnValue: true),
        ]
        let store = FakeKeyboardRecoveryStore()
        let processA = NostromoKeyboardSuppressor(
            serviceAccess: service,
            recoveryStore: store
        )

        guard case let .failed(failure) =
            processA.suppress(usages: [0x14, 0x15])
        else {
            return XCTFail("Expected apply and rollback failure.")
        }
        XCTAssertTrue(failure.recoveryPending)
        XCTAssertEqual(store.snapshots.map(\.registryID), [121])

        let processB = NostromoKeyboardSuppressor(
            serviceAccess: service,
            recoveryStore: store
        )
        let recovery = processB.recover()

        XCTAssertTrue(recovery.isComplete)
        XCTAssertEqual(recovery.restoredServiceCount, 1)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(mappingsEqual(service.mappings[121], originalOne))
    }

    func testRestorePreservesExternalReplacementForOwnedSource() {
        let original = mapping(
            sourceUsage: 0x14,
            destinationUsage: 0x04
        )
        let external = mapping(
            sourceUsage: 0x14,
            destinationUsage: 0x2C
        )
        let service = FakeKeyboardServiceAccess(
            services: [targetService(registryID: 131)],
            mappings: [131: original]
        )
        let store = FakeKeyboardRecoveryStore()
        let suppressor = NostromoKeyboardSuppressor(
            serviceAccess: service,
            recoveryStore: store
        )
        XCTAssertEqual(
            suppressor.suppress(usages: [0x14]),
            .active(serviceCount: 1, usageCount: 1)
        )

        service.mappings[131] = external
        XCTAssertTrue(suppressor.restore().isComplete)
        XCTAssertTrue(mappingsEqual(service.mappings[131], external))
    }

    func testAtomicStorePersistsAndDeletesRecoveryBatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = root.appendingPathComponent("recovery.plist")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = NostromoKeyboardRecoverySnapshot(
            registryID: 141,
            originalMapping: .missing,
            suppressedUsages: [0x14],
            appliedMapping: try NostromoKeyMappingSnapshot(
                property: mapping(
                    sourceUsage: 0x14,
                    destinationUsage: 0
                )
            )
        )
        let processA = AtomicNostromoKeyboardRecoveryStore(
            fileURL: fileURL,
            legacyStore: nil
        )
        XCTAssertTrue(processA.replace(with: [snapshot]))

        let processB = AtomicNostromoKeyboardRecoveryStore(
            fileURL: fileURL,
            legacyStore: nil
        )
        XCTAssertEqual(processB.load(), .snapshots([snapshot]))
        XCTAssertTrue(processB.replace(with: []))
        XCTAssertEqual(processB.load(), .absent)
    }

    private func targetService(
        registryID: UInt64
    ) -> NostromoKeyboardServiceIdentity {
        NostromoKeyboardServiceIdentity(
            registryID: registryID,
            vendorID: 0x1532,
            productID: 0x0111,
            isKeyboard: true
        )
    }

    private func mapping(
        sourceUsage: UInt64,
        destinationUsage: UInt64
    ) -> NSArray {
        [
            [
                "HIDKeyboardModifierMappingSrc": NSNumber(
                    value: 0x0000_0007_0000_0000 | sourceUsage
                ),
                "HIDKeyboardModifierMappingDst": NSNumber(
                    value: 0x0000_0007_0000_0000 | destinationUsage
                ),
            ],
        ] as NSArray
    }

    private func mappingsEqual(_ lhs: NSArray?, _ rhs: NSArray) -> Bool {
        lhs?.isEqual(to: rhs as! [Any]) == true
    }

    private func loadedSnapshots(
        from store: UserDefaultsNostromoKeyboardRecoveryStore
    ) throws -> [NostromoKeyboardRecoverySnapshot] {
        let snapshots: [NostromoKeyboardRecoverySnapshot]?
        switch store.load() {
        case let .snapshots(loaded):
            snapshots = loaded
        case .absent, .invalid:
            snapshots = nil
        }
        return try XCTUnwrap(snapshots, "Expected persisted snapshots.")
    }

    private func withRecoveryDefaults(
        _ body: (UserDefaults) throws -> Void
    ) throws {
        let suiteName =
            "NostromoKeyboardSuppressorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try body(defaults)
    }
}

@MainActor
private final class FakeKeyboardServiceAccess:
    NostromoKeyboardServicePropertyAccessing
{
    struct SetBehavior {
        let appliesProperty: Bool
        let returnValue: Bool
    }

    let services: [NostromoKeyboardServiceIdentity]
    var mappings: [UInt64: NSArray]
    var setBehaviors: [UInt64: [SetBehavior]] = [:]
    private(set) var setCalls: [(registryID: UInt64, property: AnyObject)] = []

    init(
        services: [NostromoKeyboardServiceIdentity],
        mappings: [UInt64: NSArray]
    ) {
        self.services = services
        self.mappings = mappings
    }

    func targetKeyboardServices() -> [NostromoKeyboardServiceIdentity] {
        services
    }

    func copyMapping(registryID: UInt64) -> AnyObject? {
        mappings[registryID]
    }

    func setMapping(
        registryID: UInt64,
        property: AnyObject
    ) -> Bool {
        setCalls.append((registryID, property))
        let behavior: SetBehavior
        if var queued = setBehaviors[registryID], !queued.isEmpty {
            behavior = queued.removeFirst()
            setBehaviors[registryID] = queued
        } else {
            behavior = SetBehavior(
                appliesProperty: true,
                returnValue: true
            )
        }
        if behavior.appliesProperty, let mapping = property as? NSArray {
            mappings[registryID] = mapping
        }
        return behavior.returnValue
    }
}

private final class FakeKeyboardRecoveryStore:
    NostromoKeyboardRecoveryStoring
{
    var snapshots: [NostromoKeyboardRecoverySnapshot] = []
    var invalid = false
    var failNextReplace = false
    private(set) var replaceHistory:
        [[NostromoKeyboardRecoverySnapshot]] = []

    func load() -> NostromoKeyboardRecoveryLoadResult {
        if invalid { return .invalid }
        return snapshots.isEmpty ? .absent : .snapshots(snapshots)
    }

    func replace(
        with snapshots: [NostromoKeyboardRecoverySnapshot]
    ) -> Bool {
        replaceHistory.append(snapshots)
        if failNextReplace {
            failNextReplace = false
            return false
        }
        self.snapshots = snapshots
        return true
    }
}
