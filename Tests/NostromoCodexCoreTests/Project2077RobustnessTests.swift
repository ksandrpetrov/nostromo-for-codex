import Foundation
@testable import NostromoCodexCore
import XCTest

final class Project2077RobustnessTests: XCTestCase {
    func testCodecBoundariesAndDeterministicPayloadsRoundTrip() throws {
        let boundaryLengths = [0, 1, 2, 60, 61, 62, 121, 122, 123, 255, 256, 4_096, 10_000]

        for length in boundaryLengths {
            let payload = deterministicData(count: length, seed: UInt64(length + 1))
            let reports = Project2077.encodePayload(payload)
            let expectedCount = length == 0
                ? 0
                : (length + Project2077.maxPayloadLength - 1) / Project2077.maxPayloadLength

            XCTAssertEqual(reports.count, expectedCount, "length \(length)")
            XCTAssertTrue(reports.allSatisfy { $0.count == Project2077.reportLength }, "length \(length)")
            XCTAssertTrue(reports.allSatisfy { $0[0] == Project2077.reportID }, "length \(length)")
            XCTAssertTrue(reports.allSatisfy { $0[1] == Project2077.channel }, "length \(length)")
            XCTAssertTrue(
                reports.allSatisfy { Int($0[2]) <= Project2077.maxPayloadLength },
                "length \(length)"
            )

            let decoded = try reports.reduce(into: Data()) {
                $0.append(try Project2077.decodeReport($1))
            }
            XCTAssertEqual(decoded, payload, "length \(length)")
        }

        var generator = DeterministicGenerator(seed: 0x2077_C0DE)
        for iteration in 0 ..< 500 {
            let length = Int(generator.next() % 2_049)
            let payload = deterministicData(count: length, seed: generator.next())
            let decoded = try Project2077.encodePayload(payload).reduce(into: Data()) {
                $0.append(try Project2077.decodeReport($1))
            }
            XCTAssertEqual(decoded, payload, "iteration \(iteration), length \(length)")
        }
    }

    func testDecodeRejectsMalformedReportEnvelope() {
        XCTAssertThrowsError(try Project2077.decodeReport(Data())) {
            XCTAssertEqual($0 as? Project2077Error, .invalidReportLength(0))
        }
        XCTAssertThrowsError(
            try Project2077.decodeReport(Data(repeating: 0, count: Project2077.reportLength - 1))
        ) {
            XCTAssertEqual($0 as? Project2077Error, .invalidReportLength(Project2077.reportLength - 1))
        }
        XCTAssertThrowsError(
            try Project2077.decodeReport(Data(repeating: 0, count: Project2077.reportLength + 1))
        ) {
            XCTAssertEqual($0 as? Project2077Error, .invalidReportLength(Project2077.reportLength + 1))
        }

        var wrongID = Data(repeating: 0, count: Project2077.reportLength)
        wrongID[0] = Project2077.reportID &+ 1
        XCTAssertThrowsError(try Project2077.decodeReport(wrongID)) {
            XCTAssertEqual($0 as? Project2077Error, .invalidReportID(Project2077.reportID &+ 1))
        }

        var oversized = Data(repeating: 0, count: Project2077.reportLength)
        oversized[0] = Project2077.reportID
        oversized[2] = UInt8(Project2077.maxPayloadLength + 1)
        XCTAssertThrowsError(try Project2077.decodeReport(oversized)) {
            XCTAssertEqual(
                $0 as? Project2077Error,
                .invalidPayloadLength(Project2077.maxPayloadLength + 1)
            )
        }
    }

    func testEngineAcceptsJSONFragmentedOneBytePerReport() throws {
        let output = RobustLockedReports()
        let engine = Project2077Engine(sendReport: output.append, onLighting: { _ in })
        let request = try JSONSerialization.data(withJSONObject: ["id": 42, "method": "sys.version"])

        for (index, byte) in request.enumerated() {
            try engine.receiveHostReport(hostReport(payload: Data([byte])))
            if index < request.count - 1 {
                XCTAssertTrue(output.values.isEmpty, "responded before the JSON request was complete at byte \(index)")
            }
        }

        let messages = try decodeOutputMessages(output.values)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual((messages[0]["id"] as? NSNumber)?.intValue, 42)
        let result = try XCTUnwrap(messages[0]["result"] as? [String: Any])
        XCTAssertEqual(result["version"] as? String, Project2077.firmwareVersion)
    }

    func testTransportResetDropsPartialFrameBeforeNewClientData() throws {
        let output = RobustLockedReports()
        let engine = Project2077Engine(sendReport: output.append, onLighting: { _ in })
        try engine.receiveHostReport(
            hostReport(payload: Data(#"{"id":1,"method":"sys."#.utf8))
        )
        XCTAssertTrue(output.values.isEmpty)

        engine.resetTransport()
        for report in try Project2077.encodeJSON(["id": 2, "method": "sys.version"]) {
            try engine.receiveHostReport(report)
        }

        let messages = try decodeOutputMessages(output.values)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual((messages[0]["id"] as? NSNumber)?.intValue, 2)
        XCTAssertNotNil(messages[0]["result"])
    }

    func testEngineDrainsMultipleMessagesFromOneInputStream() throws {
        let output = RobustLockedReports()
        let engine = Project2077Engine(sendReport: output.append, onLighting: { _ in })
        let requests: [[String: Any]] = [
            ["id": 1, "method": "sys.version"],
            ["id": 2, "method": "device.status"],
            ["id": 3, "method": "sys.version"],
        ]
        var stream = Data()
        for request in requests {
            stream.append(try JSONSerialization.data(withJSONObject: request))
            stream.append(0x0A)
        }

        for report in Project2077.encodePayload(stream) {
            try engine.receiveHostReport(report)
        }

        let messages = try decodeOutputMessages(output.values)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages.compactMap { ($0["id"] as? NSNumber)?.intValue }, [1, 2, 3])
        let status = try XCTUnwrap(messages[1]["result"] as? [String: Any])
        XCTAssertEqual((status["battery"] as? NSNumber)?.intValue, 100)
        XCTAssertEqual(status["is_charging"] as? Bool, true)
        XCTAssertEqual((status["profile_index"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((status["layer_index"] as? NSNumber)?.intValue, 0)
    }

    func testMalformedJSONAndMissingMethodAreRejectedAfterCompleteFrame() throws {
        let engine = Project2077Engine(sendReport: { _ in }, onLighting: { _ in })

        XCTAssertThrowsError(
            try engine.receiveHostReport(hostReport(payload: Data("{broken}\n".utf8)))
        ) {
            XCTAssertEqual($0 as? Project2077Error, .malformedJSON)
        }
        XCTAssertThrowsError(
            try engine.receiveHostReport(hostReport(payload: Data(#"{"id":1}"#.utf8) + Data([0x0A])))
        ) {
            XCTAssertEqual($0 as? Project2077Error, .malformedJSON)
        }
        XCTAssertThrowsError(
            try engine.receiveHostReport(hostReport(payload: Data(#"[1,2,3]"#.utf8) + Data([0x0A])))
        ) {
            XCTAssertEqual($0 as? Project2077Error, .malformedJSON)
        }
    }

    func testUnknownRPCWithIDReturnsMethodNotFoundAndNotificationIsSilent() throws {
        let output = RobustLockedReports()
        let engine = Project2077Engine(sendReport: output.append, onLighting: { _ in })

        for report in try Project2077.encodeJSON(["id": 91, "method": "missing.method"]) {
            try engine.receiveHostReport(report)
        }
        var messages = try decodeOutputMessages(output.values)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual((messages[0]["id"] as? NSNumber)?.intValue, 91)
        let error = try XCTUnwrap(messages[0]["error"] as? [String: Any])
        XCTAssertEqual((error["code"] as? NSNumber)?.intValue, -32601)
        XCTAssertEqual(error["message"] as? String, "Метод не найден: missing.method")

        output.removeAll()
        for report in try Project2077.encodeJSON(["method": "missing.notification"]) {
            try engine.receiveHostReport(report)
        }
        messages = try decodeOutputMessages(output.values)
        XCTAssertTrue(messages.isEmpty)
    }

    func testOversizedUnterminatedAccumulatorIsDroppedAndEngineRecovers() throws {
        let output = RobustLockedReports()
        let engine = Project2077Engine(sendReport: output.append, onLighting: { _ in })
        let fullPayload = Data(repeating: 0x78, count: Project2077.maxPayloadLength)
        let reportsToCrossLimit = (256 * 1_024) / Project2077.maxPayloadLength + 1

        for _ in 0 ..< reportsToCrossLimit {
            try engine.receiveHostReport(hostReport(payload: fullPayload))
        }
        XCTAssertTrue(output.values.isEmpty)

        for report in try Project2077.encodeJSON(["id": 7, "method": "sys.version"]) {
            try engine.receiveHostReport(report)
        }
        let messages = try decodeOutputMessages(output.values)
        XCTAssertEqual((messages.first?["id"] as? NSNumber)?.intValue, 7)
    }

    func testLightingUpdatesClampThreadsIgnoreInvalidIDsAndPreservePreviousFields() throws {
        let lighting = RobustLockedLighting()
        let engine = Project2077Engine(sendReport: { _ in }, onLighting: lighting.set)

        try feed(
            [
                "method": "v.oai.thstatus",
                "params": [
                    ["id": 0, "c": 0x102030, "b": 5.0, "e": 4, "s": -2.0, "sa": true],
                    ["id": 5, "c": 0xABCDEF, "b": -1.0],
                    ["id": -1, "c": 0xFFFFFF],
                    ["id": 6, "c": 0xFFFFFF],
                    ["id": "not-a-number", "c": 0xFFFFFF],
                ],
            ],
            to: engine
        )

        var state = engine.currentLighting()
        XCTAssertEqual(state.threads[0].color, 0x102030)
        XCTAssertEqual(state.threads[0].brightness, 1)
        XCTAssertEqual(state.threads[0].speed, 0)
        XCTAssertTrue(state.threads[0].selected)
        XCTAssertEqual(state.threads[5].brightness, 0)
        XCTAssertEqual(state.threads.count, 6)

        try feed(
            [
                "method": "v.oai.thstatus",
                "params": [["id": 0, "b": 0.25]],
            ],
            to: engine
        )
        state = engine.currentLighting()
        XCTAssertEqual(state.threads[0].color, 0x102030)
        XCTAssertEqual(state.threads[0].brightness, 0.25)
        XCTAssertFalse(state.threads[0].selected)
        XCTAssertEqual(lighting.value, state)
    }

    func testZoneUpdatesPreserveUnspecifiedFields() throws {
        let lighting = RobustLockedLighting()
        let engine = Project2077Engine(sendReport: { _ in }, onLighting: lighting.set)

        try feed(
            [
                "method": "v.oai.rgbcfg",
                "params": [
                    "keys": ["e": 2, "b": 0.4, "s": 0.8, "m": 11, "c": 0xAA5500],
                    "ambient": ["e": 1, "b": 0.2, "c": 0x010203],
                ],
            ],
            to: engine
        )
        try feed(
            [
                "method": "v.oai.rgbcfg",
                "params": ["keys": ["b": 0.9]],
            ],
            to: engine
        )

        let state = engine.currentLighting()
        XCTAssertEqual(state.keys.effect, 2)
        XCTAssertEqual(state.keys.brightness, 0.9)
        XCTAssertEqual(state.keys.speed, 0.8)
        XCTAssertEqual(state.keys.magic, 11)
        XCTAssertEqual(state.keys.color, 0xAA5500)
        XCTAssertEqual(state.ambient.color, 0x010203)
        XCTAssertEqual(lighting.value, state)
    }

    func testTenThousandKeyEventsRetainOrderAndPayload() throws {
        let output = RobustLockedReports()
        let engine = Project2077Engine(sendReport: output.append, onLighting: { _ in })
        let eventCount = 10_000

        for index in 0 ..< eventCount {
            try engine.emitKey(
                "KEY_\(index % 16)",
                pressed: index.isMultiple(of: 2),
                agent: index % 6
            )
        }

        let messages = try decodeOutputMessages(output.values)
        XCTAssertEqual(messages.count, eventCount)
        for index in 0 ..< eventCount {
            XCTAssertEqual(messages[index]["method"] as? String, "v.oai.hid", "event \(index)")
            let params = try XCTUnwrap(messages[index]["params"] as? [String: Any])
            XCTAssertEqual(params["k"] as? String, "KEY_\(index % 16)", "event \(index)")
            XCTAssertEqual((params["act"] as? NSNumber)?.intValue, index.isMultiple(of: 2) ? 1 : 0)
            XCTAssertEqual((params["ag"] as? NSNumber)?.intValue, index % 6)
        }
    }

    func testEncoderAndJoystickEmission() throws {
        let output = RobustLockedReports()
        let engine = Project2077Engine(sendReport: output.append, onLighting: { _ in })

        try engine.emitEncoder(delta: 0)
        XCTAssertTrue(output.values.isEmpty)
        try engine.emitEncoder(delta: 3)
        try engine.emitEncoder(delta: -2)
        for direction in DPadDirection.allCases {
            try engine.emitJoystick(direction: direction, active: true)
            try engine.emitJoystick(direction: direction, active: false)
        }

        let messages = try decodeOutputMessages(output.values)
        XCTAssertEqual(messages.count, 5 + DPadDirection.allCases.count * 2)
        let encoderKeys = try messages.prefix(5).map {
            try XCTUnwrap(($0["params"] as? [String: Any])?["k"] as? String)
        }
        XCTAssertEqual(encoderKeys, ["ENC_CW", "ENC_CW", "ENC_CW", "ENC_CC", "ENC_CC"])

        let expectedAngles = [0.0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875]
        for (directionIndex, expectedAngle) in expectedAngles.enumerated() {
            for activeIndex in 0 ..< 2 {
                let message = messages[5 + directionIndex * 2 + activeIndex]
                XCTAssertEqual(message["method"] as? String, "v.oai.rad")
                let params = try XCTUnwrap(message["params"] as? [String: Any])
                let angle = try XCTUnwrap((params["a"] as? NSNumber)?.doubleValue)
                let distance = try XCTUnwrap((params["d"] as? NSNumber)?.doubleValue)
                XCTAssertEqual(angle, expectedAngle, accuracy: 0.000_001)
                XCTAssertEqual(distance, activeIndex == 0 ? 1 : 0)
            }
        }
    }

    private func feed(_ object: [String: Any], to engine: Project2077Engine) throws {
        for report in try Project2077.encodeJSON(object) {
            try engine.receiveHostReport(report)
        }
    }

    private func hostReport(payload: Data) -> Data {
        precondition(payload.count <= Project2077.maxPayloadLength)
        var report = Data(repeating: 0, count: Project2077.reportLength)
        report[0] = Project2077.reportID
        report[1] = Project2077.channel
        report[2] = UInt8(payload.count)
        report.replaceSubrange(3 ..< (3 + payload.count), with: payload)
        return report
    }

    private func decodeOutputMessages(_ reports: [Data]) throws -> [[String: Any]] {
        var stream = Data()
        for report in reports {
            stream.append(try Project2077.decodeReport(report))
        }
        return try stream.split(separator: 0x0A).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
    }

    private func deterministicData(count: Int, seed: UInt64) -> Data {
        var generator = DeterministicGenerator(seed: seed)
        return Data((0 ..< count).map { _ in UInt8(truncatingIfNeeded: generator.next()) })
    }
}

private struct DeterministicGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

private final class RobustLockedReports: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var values: [Data] {
        lock.withLock { storage }
    }

    func append(_ report: Data) {
        lock.withLock { storage.append(report) }
    }

    func removeAll() {
        lock.withLock { storage.removeAll() }
    }
}

private final class RobustLockedLighting: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: CodexLightingState?

    var value: CodexLightingState? {
        lock.withLock { storage }
    }

    func set(_ value: CodexLightingState) {
        lock.withLock { storage = value }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
