import Darwin
import Foundation
@testable import NostromoCodexApp
import NostromoCodexCore
import XCTest

final class UnixSocketBridgeTests: XCTestCase {
    func testInitializationRemovesRuntimeOwnedByDeadProcess() throws {
        let runtimeRoot = try makeTemporaryRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        let staleRuntime = try makeRuntimeCandidate(
            in: runtimeRoot,
            ownerPID: 2_001
        )

        let bridge = try UnixSocketBridge(
            runtimeRoot: runtimeRoot,
            currentPID: 1_001,
            processLiveness: { pid in pid == 2_001 ? .dead : .unknown }
        )
        defer { bridge.stop() }

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRuntime.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridge.runtimeDirectory.path))
    }

    func testInitializationPreservesLiveAndAmbiguousOwners() throws {
        let runtimeRoot = try makeTemporaryRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        let liveRuntime = try makeRuntimeCandidate(
            in: runtimeRoot,
            ownerPID: 2_002
        )
        let ambiguousRuntime = try makeRuntimeCandidate(
            in: runtimeRoot,
            ownerPID: 2_003
        )

        let bridge = try UnixSocketBridge(
            runtimeRoot: runtimeRoot,
            currentPID: 1_002,
            processLiveness: { pid in pid == 2_002 ? .alive : .unknown }
        )
        defer { bridge.stop() }

        XCTAssertTrue(FileManager.default.fileExists(atPath: liveRuntime.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ambiguousRuntime.path))
    }

    func testInitializationPreservesInvalidLegacyAndCacheDirectories() throws {
        let runtimeRoot = try makeTemporaryRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        let invalidMarker = try makeRuntimeCandidate(
            in: runtimeRoot,
            ownerPID: 2_004,
            markerContents: Data("not an owner marker".utf8)
        )
        let missingMarker = try makeRuntimeCandidate(
            in: runtimeRoot,
            ownerPID: 2_005
        )
        try FileManager.default.removeItem(
            at: missingMarker.appendingPathComponent(UnixSocketBridge.ownerMarkerFileName)
        )

        let preservedNames = [
            "nostromo-codex-\(UUID().uuidString)",
            "nostromo-codex-swiftpm-cache",
            "nostromo-codex-test-cache",
            "\(UnixSocketBridge.runtimeDirectoryPrefix)not-a-uuid",
        ]
        let preservedDirectories = try preservedNames.map { name in
            let directory = runtimeRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            return directory
        }

        let bridge = try UnixSocketBridge(
            runtimeRoot: runtimeRoot,
            currentPID: 1_003,
            processLiveness: { _ in .dead }
        )
        defer { bridge.stop() }

        XCTAssertTrue(FileManager.default.fileExists(atPath: invalidMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: missingMarker.path))
        for directory in preservedDirectories {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: directory.path),
                "Unexpectedly removed \(directory.lastPathComponent)"
            )
        }
    }

    func testOwnerMarkerHasPrivatePermissionsAndInjectedPID() throws {
        let runtimeRoot = try makeTemporaryRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        let bridge = try UnixSocketBridge(
            runtimeRoot: runtimeRoot,
            currentPID: 4_242,
            processLiveness: { _ in .unknown }
        )
        defer { bridge.stop() }

        let markerURL = bridge.runtimeDirectory.appendingPathComponent(
            UnixSocketBridge.ownerMarkerFileName
        )
        XCTAssertEqual(try posixMode(markerURL.path) & 0o777, 0o600)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
        )
        XCTAssertEqual((object["pid"] as? NSNumber)?.int32Value, 4_242)
    }

    func testStopRemovesInjectedRuntimeDirectoryAndIsIdempotent() throws {
        let runtimeRoot = try makeTemporaryRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        let bridge = try UnixSocketBridge(
            runtimeRoot: runtimeRoot,
            currentPID: 4_243,
            processLiveness: { _ in .unknown }
        )
        let bridgeRuntime = bridge.runtimeDirectory

        bridge.stop()
        bridge.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: bridgeRuntime.path))
    }

    func testImmediateStartStopIsTerminalAndSuppressesLateStatuses() throws {
        for iteration in 0 ..< 25 {
            let runtimeRoot = try makeTemporaryRuntimeRoot()
            defer { try? FileManager.default.removeItem(at: runtimeRoot) }
            let bridge = try UnixSocketBridge(runtimeRoot: runtimeRoot)
            let statuses = LockedStatuses()
            let stopped = expectation(description: "terminal stop \(iteration)")
            bridge.onStatus = { status in
                statuses.append(status)
                if status == .stopped {
                    stopped.fulfill()
                }
            }

            bridge.start()
            bridge.stop()
            bridge.start()
            bridge.stop()
            wait(for: [stopped], timeout: 2)
            Thread.sleep(forTimeInterval: 0.01)

            let snapshot = statuses.value
            let terminalIndex = try XCTUnwrap(
                snapshot.firstIndex(of: .stopped),
                "A terminal status must be delivered"
            )
            XCTAssertTrue(
                snapshot.suffix(from: terminalIndex).allSatisfy { $0 == .stopped },
                "No active or failure status may be delivered after stop: \(snapshot)"
            )
            XCTAssertEqual(snapshot.filter { $0 == .stopped }.count, 1)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: bridge.runtimeDirectory.path)
            )
        }
    }

    func testBindFailureRemovesOwnRuntimeDirectory() throws {
        let runtimeRoot = try makeTemporaryRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        let bridge = try UnixSocketBridge(
            runtimeRoot: runtimeRoot,
            currentPID: 4_244,
            processLiveness: { _ in .unknown }
        )
        defer { bridge.stop() }
        try Data("occupied".utf8).write(to: URL(fileURLWithPath: bridge.socketPath))

        let failed = expectation(description: "bridge bind failed")
        bridge.onStatus = { status in
            if case .failed = status {
                failed.fulfill()
            }
        }
        bridge.start()
        wait(for: [failed], timeout: 2)

        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.runtimeDirectory.path))
    }

    func testSocketPermissionsAuthenticationAndActionRoundTrip() throws {
        let bridge = try UnixSocketBridge()
        defer { bridge.stop() }
        let listening = expectation(description: "bridge listening")
        listening.assertForOverFulfill = false
        bridge.onStatus = { status in
            if status == .listening { listening.fulfill() }
        }
        bridge.start()
        wait(for: [listening], timeout: 2)

        let directoryMode = try posixMode(bridge.runtimeDirectory.path)
        let socketMode = try posixMode(bridge.socketPath)
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(socketMode & 0o777, 0o600)

        let client = try UnixTestClient(path: bridge.socketPath)
        defer { client.close() }
        try client.send([
            "v": 2,
            "type": "hello",
            "role": "node-hid-shim",
            "token": bridge.token,
        ])
        let acknowledgement = try XCTUnwrap(client.receive())
        XCTAssertEqual(acknowledgement["type"] as? String, "hello-ack")

        let completed = expectation(description: "action completion")
        bridge.dispatch(.focusChatGPT) { result in
            if case let .failure(error) = result {
                XCTFail("Action failed: \(error)")
            }
            completed.fulfill()
        }

        let action = try XCTUnwrap(client.receive())
        XCTAssertEqual(action["type"] as? String, "app-action")
        XCTAssertEqual(action["action"] as? String, "focus-chatgpt")
        let id = try XCTUnwrap((action["id"] as? NSNumber)?.intValue)
        try client.send([
            "v": 2,
            "type": "app-action-result",
            "id": id,
            "ok": true,
        ])
        wait(for: [completed], timeout: 2)
    }

    func testWrongTokenTerminatesConnectionAndAllowsFreshClient() throws {
        let bridge = try UnixSocketBridge()
        defer { bridge.stop() }
        let listening = expectation(description: "bridge listening")
        listening.assertForOverFulfill = false
        bridge.onStatus = { status in
            if status == .listening { listening.fulfill() }
        }
        bridge.start()
        wait(for: [listening], timeout: 2)

        let rejected = try UnixTestClient(path: bridge.socketPath)
        try rejected.send([
            "v": 2,
            "type": "hello",
            "role": "node-hid-shim",
            "token": "wrong-token",
        ])
        let error = try XCTUnwrap(rejected.receive())
        XCTAssertEqual(error["type"] as? String, "error")
        XCTAssertNil(try rejected.receive())
        rejected.close()

        let accepted = try UnixTestClient(path: bridge.socketPath)
        defer { accepted.close() }
        try accepted.send([
            "v": 2,
            "type": "hello",
            "role": "node-hid-shim",
            "token": bridge.token,
        ])
        XCTAssertEqual(try accepted.receive()?["type"] as? String, "hello-ack")
    }

    func testTenSequentialAuthenticatedReconnectsLeaveBridgeReusable() throws {
        let bridge = try UnixSocketBridge()
        let runtimeDirectory = bridge.runtimeDirectory
        defer { bridge.stop() }
        let listening = expectation(description: "bridge listening")
        listening.assertForOverFulfill = false
        bridge.onStatus = { status in
            if status == .listening { listening.fulfill() }
        }
        bridge.start()
        wait(for: [listening], timeout: 2)

        for cycle in 1 ... 10 {
            let client = try UnixTestClient(path: bridge.socketPath)
            try client.send([
                "v": 2,
                "type": "hello",
                "role": "node-hid-shim",
                "token": bridge.token,
            ])
            XCTAssertEqual(
                try client.receive()?["type"] as? String,
                "hello-ack",
                "Reconnect \(cycle) did not authenticate"
            )
            client.close()

            let deadline = Date().addingTimeInterval(2)
            while bridge.isAuthenticated, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTAssertFalse(
                bridge.isAuthenticated,
                "Reconnect \(cycle) did not return to listening state"
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: runtimeDirectory.path))
        bridge.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeDirectory.path))
    }

    func testDispatchWithoutClientFailsImmediately() throws {
        let bridge = try UnixSocketBridge()
        defer { bridge.stop() }
        let result = LockedResult()
        bridge.dispatch(.focusChatGPT) {
            result.set($0)
        }
        guard case .failure = result.value else {
            return XCTFail("Expected a disconnected error")
        }
    }

    func testUnauthenticatedClientCannotReceiveActionsAndFragmentedHelloWorks() throws {
        let bridge = try UnixSocketBridge()
        defer { bridge.stop() }
        let listening = expectation(description: "bridge listening")
        bridge.onStatus = { status in
            if status == .listening { listening.fulfill() }
        }
        bridge.start()
        wait(for: [listening], timeout: 2)

        let client = try UnixTestClient(path: bridge.socketPath)
        defer { client.close() }
        let preAuthentication = LockedResult()
        bridge.dispatch(.focusChatGPT) { preAuthentication.set($0) }
        guard case .failure = preAuthentication.value else {
            return XCTFail("An unauthenticated socket must not be considered connected")
        }
        bridge.sendDeviceReport(Data(repeating: 0xAB, count: Project2077.reportLength))

        try client.sendFragmented([
            "v": 2,
            "type": "hello",
            "role": "node-hid-shim",
            "token": bridge.token,
        ], chunkSize: 1)
        // A device report before hello-ack would make the preload reject the
        // bridge during its strict handshake.
        XCTAssertEqual(try client.receive()?["type"] as? String, "hello-ack")
    }

    func testMalformedFirstMessageClosesConnectionAndServerRecovers() throws {
        let bridge = try UnixSocketBridge()
        defer { bridge.stop() }
        let listening = expectation(description: "bridge listening")
        listening.assertForOverFulfill = false
        bridge.onStatus = { status in
            if status == .listening { listening.fulfill() }
        }
        bridge.start()
        wait(for: [listening], timeout: 2)

        let malformed = try UnixTestClient(path: bridge.socketPath)
        try malformed.sendBytes(Data("{broken}\n".utf8))
        XCTAssertEqual(try malformed.receive()?["type"] as? String, "error")
        XCTAssertNil(try malformed.receive())
        malformed.close()

        let recovered = try UnixTestClient(path: bridge.socketPath)
        defer { recovered.close() }
        try recovered.send([
            "v": 2,
            "type": "hello",
            "role": "node-hid-shim",
            "token": bridge.token,
        ])
        XCTAssertEqual(try recovered.receive()?["type"] as? String, "hello-ack")
    }

    func testOversizedUnauthenticatedMessageIsRejectedAndServerRecovers() throws {
        let bridge = try UnixSocketBridge()
        defer { bridge.stop() }
        let listening = expectation(description: "bridge listening")
        listening.assertForOverFulfill = false
        bridge.onStatus = { status in
            if status == .listening { listening.fulfill() }
        }
        bridge.start()
        wait(for: [listening], timeout: 2)

        let oversized = try UnixTestClient(path: bridge.socketPath)
        try oversized.sendBytes(Data(repeating: 0x41, count: 1024 * 1024 + 1))
        let error = try oversized.receive()
        XCTAssertEqual(error?["type"] as? String, "error")
        XCTAssertEqual(error?["message"] as? String, "Буфер приёма моста превысил 1 МиБ.")
        XCTAssertNil(try oversized.receive())
        oversized.close()

        let recovered = try UnixTestClient(path: bridge.socketPath)
        defer { recovered.close() }
        try recovered.send([
            "v": 2,
            "type": "hello",
            "role": "node-hid-shim",
            "token": bridge.token,
        ])
        XCTAssertEqual(try recovered.receive()?["type"] as? String, "hello-ack")
    }

    func testHostReportAndRejectedActionRoundTrip() throws {
        let bridge = try UnixSocketBridge()
        defer { bridge.stop() }
        let listening = expectation(description: "bridge listening")
        bridge.onStatus = { status in
            if status == .listening { listening.fulfill() }
        }
        let hostReport = expectation(description: "host report")
        let expectedReport = Data((0 ..< Project2077.reportLength).map(UInt8.init))
        bridge.onHostReport = { report in
            XCTAssertEqual(report, expectedReport)
            hostReport.fulfill()
        }
        bridge.start()
        wait(for: [listening], timeout: 2)

        let client = try authenticatedClient(for: bridge)
        defer { client.close() }
        try client.send([
            "v": 2,
            "type": "host-report",
            "data": expectedReport.base64EncodedString(),
        ])
        wait(for: [hostReport], timeout: 2)

        let completed = expectation(description: "rejected action")
        let result = LockedResult()
        bridge.dispatch(.runCommand(id: "settings")) {
            result.set($0)
            completed.fulfill()
        }
        let action = try XCTUnwrap(client.receive())
        let id = try XCTUnwrap((action["id"] as? NSNumber)?.intValue)
        try client.send([
            "v": 2,
            "type": "app-action-result",
            "id": id,
            "ok": false,
            "error": "denied by adapter",
        ])
        wait(for: [completed], timeout: 2)
        guard case let .failure(error) = result.value else {
            return XCTFail("Expected a rejected action")
        }
        XCTAssertEqual(error.localizedDescription, "denied by adapter")
    }

    func testCapabilityManifestAndRuntimeStateAreValidatedAndDelivered() throws {
        let bridge = try UnixSocketBridge()
        defer { bridge.stop() }
        let listening = expectation(description: "bridge listening")
        bridge.onStatus = { status in
            if status == .listening { listening.fulfill() }
        }
        let capabilitiesReceived = expectation(description: "capabilities")
        let runtimeStateReceived = expectation(description: "runtime state")
        bridge.onCapabilities = { capabilities in
            XCTAssertEqual(capabilities.commandIDs, ["composer.submit", "newTask"])
            XCTAssertEqual(capabilities.commandRegistrySource, "runtime-app-asar")
            XCTAssertEqual(capabilities.requiredAPIs["rendererMessaging"], true)
            XCTAssertEqual(capabilities.unavailableFeatures, ["compact unavailable"])
            capabilitiesReceived.fulfill()
        }
        bridge.onRuntimeState = { state in
            XCTAssertEqual(state.reasoningEffort, "high")
            runtimeStateReceived.fulfill()
        }
        bridge.start()
        wait(for: [listening], timeout: 2)

        let client = try authenticatedClient(for: bridge)
        defer { client.close() }
        try client.send([
            "v": 2,
            "type": "capabilities",
            "commandIds": ["composer.submit", "newTask"],
            "commandRegistrySource": "runtime-app-asar",
            "requiredApis": ["rendererMessaging": true],
            "unavailableFeatures": ["compact unavailable"],
        ])
        try client.send([
            "v": 2,
            "type": "runtime-state",
            "reasoningEffort": "high",
        ])
        wait(for: [capabilitiesReceived, runtimeStateReceived], timeout: 2)
    }

    func testTaskSlotMetadataIsValidatedSortedAndDelivered() throws {
        let bridge = try UnixSocketBridge()
        defer { bridge.stop() }
        let listening = expectation(description: "bridge listening")
        bridge.onStatus = { status in
            if status == .listening { listening.fulfill() }
        }
        let taskSlotsReceived = expectation(description: "task slots")
        bridge.onTaskSlots = { slots in
            XCTAssertEqual(slots, [
                CodexTaskSlot(
                    id: 0,
                    title: "Добавить переключение",
                    status: .unread,
                    selected: true
                ),
                CodexTaskSlot(
                    id: 3,
                    title: "Исправить меню дока",
                    status: .working,
                    selected: false
                ),
            ])
            taskSlotsReceived.fulfill()
        }
        bridge.start()
        wait(for: [listening], timeout: 2)

        let client = try authenticatedClient(for: bridge)
        defer { client.close() }
        try client.send([
            "v": 2,
            "type": "task-slots",
            "slots": [
                [
                    "id": 3,
                    "title": "Исправить меню дока",
                    "status": "working",
                    "selected": false,
                ],
                [
                    "id": 0,
                    "title": "Добавить переключение",
                    "status": "unread",
                    "selected": true,
                ],
            ],
        ])
        wait(for: [taskSlotsReceived], timeout: 2)

        try client.send([
            "v": 2,
            "type": "task-slots",
            "slots": [
                [
                    "id": 0,
                    "title": "Первая",
                    "status": "idle",
                    "selected": false,
                ],
                [
                    "id": 0,
                    "title": "Дубликат",
                    "status": "idle",
                    "selected": false,
                ],
            ],
        ])
        let response = try XCTUnwrap(client.receive())
        XCTAssertEqual(response["type"] as? String, "error")
        XCTAssertEqual(response["message"] as? String, "Некорректное состояние задач Codex.")
    }

    func testConcurrentActionsHaveUniqueIDsAndAllComplete() throws {
        let bridge = try UnixSocketBridge()
        defer { bridge.stop() }
        let listening = expectation(description: "bridge listening")
        bridge.onStatus = { status in
            if status == .listening { listening.fulfill() }
        }
        bridge.start()
        wait(for: [listening], timeout: 2)
        let client = try authenticatedClient(for: bridge)
        defer { client.close() }

        let actionCount = 250
        let completions = expectation(description: "all action completions")
        completions.expectedFulfillmentCount = actionCount
        for index in 0 ..< actionCount {
            DispatchQueue.global(qos: .userInitiated).async {
                bridge.dispatch(
                    .runCommand(id: "stress.\(index)")
                ) { result in
                    if case let .failure(error) = result {
                        XCTFail("Action failed: \(error)")
                    }
                    completions.fulfill()
                }
            }
        }

        var identifiers = Set<Int>()
        for _ in 0 ..< actionCount {
            let action = try XCTUnwrap(client.receive())
            let id = try XCTUnwrap((action["id"] as? NSNumber)?.intValue)
            XCTAssertTrue(identifiers.insert(id).inserted, "Duplicate action id \(id)")
            try client.send([
                "v": 2,
                "type": "app-action-result",
                "id": id,
                "ok": true,
            ])
        }
        wait(for: [completions], timeout: 5)
        XCTAssertEqual(identifiers.count, actionCount)
    }

    func testStopWithConnectedClientFailsPendingActionAndRemovesRuntime() throws {
        let bridge = try UnixSocketBridge()
        let listening = expectation(description: "bridge listening")
        bridge.onStatus = { status in
            if status == .listening { listening.fulfill() }
        }
        bridge.start()
        wait(for: [listening], timeout: 2)
        let client = try authenticatedClient(for: bridge)
        defer { client.close() }

        let failed = expectation(description: "pending action failed")
        let result = LockedResult()
        bridge.dispatch(.focusChatGPT) {
            result.set($0)
            failed.fulfill()
        }
        XCTAssertEqual(try client.receive()?["type"] as? String, "app-action")

        bridge.stop()
        wait(for: [failed], timeout: 2)
        guard case .failure = result.value else {
            return XCTFail("Stopping the bridge must fail every pending action")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.runtimeDirectory.path))
        XCTAssertNil(try client.receive())
    }

    func testBackpressuredPeerDoesNotBlockDispatchOrStop() throws {
        let bridge = try UnixSocketBridge()
        let listening = expectation(description: "bridge listening")
        bridge.onStatus = { status in
            if status == .listening { listening.fulfill() }
        }
        bridge.start()
        wait(for: [listening], timeout: 2)
        let client = try authenticatedClient(for: bridge)
        defer { client.close() }
        client.setReceiveBufferSize(1_024)

        let failed = expectation(description: "pending action failed on stop")
        let largePayload = String(repeating: "x", count: 8 * 1_024 * 1_024)
        let dispatchStarted = Date()
        bridge.dispatch(
            .runCommand(id: largePayload)
        ) { result in
            guard case .failure = result else {
                return XCTFail("Stopping a backpressured bridge must fail the action")
            }
            failed.fulfill()
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(dispatchStarted),
            1,
            "dispatch must serialize and enqueue without waiting for the peer to read"
        )

        Thread.sleep(forTimeInterval: 0.03)
        let stopStarted = Date()
        bridge.stop()
        XCTAssertLessThan(
            Date().timeIntervalSince(stopStarted),
            0.5,
            "stop must not wait for a blocked socket writer"
        )
        wait(for: [failed], timeout: 2)
    }

    func testHandlersCanBeReplacedWhileAuthenticatedTrafficIsArriving() throws {
        let bridge = try UnixSocketBridge()
        defer { bridge.stop() }
        let listening = expectation(description: "bridge listening")
        bridge.onStatus = { status in
            if status == .listening { listening.fulfill() }
        }
        bridge.start()
        wait(for: [listening], timeout: 2)
        let client = try authenticatedClient(for: bridge)
        defer { client.close() }

        let mutations = DispatchGroup()
        mutations.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            for index in 0 ..< 5_000 {
                if index.isMultiple(of: 2) {
                    bridge.onHostReport = { _ in }
                } else {
                    bridge.onHostReport = nil
                }
                if index.isMultiple(of: 3) {
                    bridge.onStatus = { _ in }
                } else {
                    bridge.onStatus = nil
                }
            }
            mutations.leave()
        }

        let report = Data(repeating: 0xA5, count: Project2077.reportLength)
        for _ in 0 ..< 1_000 {
            try client.send([
                "v": 2,
                "type": "host-report",
                "data": report.base64EncodedString(),
            ])
        }
        XCTAssertEqual(mutations.wait(timeout: .now() + 2), .success)
    }

    private func authenticatedClient(for bridge: UnixSocketBridge) throws -> UnixTestClient {
        let client = try UnixTestClient(path: bridge.socketPath)
        try client.send([
            "v": 2,
            "type": "hello",
            "role": "node-hid-shim",
            "token": bridge.token,
        ])
        XCTAssertEqual(try client.receive()?["type"] as? String, "hello-ack")
        return client
    }

    private func posixMode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    private func makeTemporaryRuntimeRoot() throws -> URL {
        let suffix = UUID().uuidString.prefix(8)
        let runtimeRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("nc-ut-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtimeRoot,
            withIntermediateDirectories: false
        )
        return runtimeRoot
    }

    private func makeRuntimeCandidate(
        in runtimeRoot: URL,
        ownerPID: Int32,
        markerContents: Data? = nil
    ) throws -> URL {
        let runtimeID = UUID()
        let directory = runtimeRoot.appendingPathComponent(
            "\(UnixSocketBridge.runtimeDirectoryPrefix)\(runtimeID.uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let marker: Data
        if let markerContents {
            marker = markerContents
        } else {
            marker = try JSONSerialization.data(
                withJSONObject: [
                    "version": 1,
                    "pid": ownerPID,
                    "runtimeID": runtimeID.uuidString,
                ],
                options: [.sortedKeys]
            )
        }
        let markerURL = directory.appendingPathComponent(
            UnixSocketBridge.ownerMarkerFileName
        )
        try marker.write(to: markerURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerURL.path
        )
        return directory
    }
}

private final class LockedResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Void, Error>?

    var value: Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ result: Result<Void, Error>) {
        lock.lock()
        storage = result
        lock.unlock()
    }
}

private final class LockedStatuses: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BridgeStatus] = []

    var value: [BridgeStatus] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ status: BridgeStatus) {
        lock.lock()
        storage.append(status)
        lock.unlock()
    }
}

private final class UnixTestClient {
    private var fd: Int32

    init(path: String) throws {
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXTestError("socket") }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var suppressSIGPIPE: Int32 = 1
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &suppressSIGPIPE,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        address.sun_len = UInt8(
            MemoryLayout.size(ofValue: address.sun_len)
                + MemoryLayout.size(ofValue: address.sun_family)
                + bytes.count
                + 1
        )
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in bytes.enumerated() {
                destination[index] = byte
            }
        }

        let addressLength = socklen_t(address.sun_len)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength)
            }
        }
        guard connected == 0 else {
            close()
            throw POSIXTestError("connect")
        }
    }

    deinit {
        close()
    }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try sendBytes(data)
    }

    func sendFragmented(_ object: [String: Any], chunkSize: Int) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            try sendBytes(data.subdata(in: offset ..< end))
            offset = end
        }
    }

    func sendBytes(_ data: Data) throws {
        let sent = data.withUnsafeBytes { buffer -> Int in
            guard var pointer = buffer.baseAddress else { return 0 }
            var total = 0
            while total < buffer.count {
                let count = Darwin.write(fd, pointer, buffer.count - total)
                guard count > 0 else { return total }
                pointer = pointer.advanced(by: count)
                total += count
            }
            return total
        }
        guard sent == data.count else { throw POSIXTestError("write") }
    }

    func receive() throws -> [String: Any]? {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 { return nil }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return nil }
                throw POSIXTestError("read")
            }
            if byte == 0x0A { break }
            data.append(byte)
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        fd = -1
    }

    func setReceiveBufferSize(_ bytes: Int32) {
        var size = bytes
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVBUF,
            &size,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }
}

private struct POSIXTestError: LocalizedError {
    let operation: String

    init(_ operation: String) {
        self.operation = operation
    }

    var errorDescription: String? {
        "\(operation) failed: \(String(cString: strerror(errno)))"
    }
}
