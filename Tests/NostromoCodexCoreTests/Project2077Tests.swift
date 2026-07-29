import Foundation
@testable import NostromoCodexCore
import XCTest

final class Project2077Tests: XCTestCase {
    func testPayloadIsChunkedAndRoundTrips() throws {
        let payload = Data((0 ..< 160).map { UInt8($0 % 251) })
        let reports = Project2077.encodePayload(payload)

        XCTAssertEqual(reports.count, 3)
        XCTAssertTrue(reports.allSatisfy { $0.count == Project2077.reportLength })
        XCTAssertTrue(reports.allSatisfy { $0[0] == Project2077.reportID && $0[1] == Project2077.channel })

        let decoded = try reports.reduce(into: Data()) { result, report in
            result.append(try Project2077.decodeReport(report))
        }
        XCTAssertEqual(decoded, payload)
    }

    func testVersionRPCProducesResult() throws {
        let reports = LockedReports()
        let engine = Project2077Engine(
            sendReport: { reports.append($0) },
            onLighting: { _ in }
        )
        let request = try Project2077.encodeJSON(["id": 17, "method": "sys.version"])
        for report in request {
            try engine.receiveHostReport(report)
        }

        let object = try decodeJSONReports(reports.values)
        XCTAssertEqual((object["id"] as? NSNumber)?.intValue, 17)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["version"] as? String, Project2077.firmwareVersion)
    }

    func testThreadStatusUpdatesLighting() throws {
        let lighting = LockedLighting()
        let engine = Project2077Engine(
            sendReport: { _ in },
            onLighting: { lighting.set($0) }
        )
        let request = try Project2077.encodeJSON([
            "method": "v.oai.thstatus",
            "params": [
                ["id": 2, "c": 0x20A0FF, "b": 0.8, "e": 1, "s": 0.4, "sk": true],
            ],
        ])
        for report in request {
            try engine.receiveHostReport(report)
        }

        let thread = try XCTUnwrap(lighting.value?.threads[2])
        XCTAssertEqual(thread.color, 0x20A0FF)
        XCTAssertEqual(thread.brightness, 0.8, accuracy: 0.001)
        XCTAssertTrue(thread.selected)
    }

    func testWorkLouderRequestWithoutNewlineProducesImmediateResponse() throws {
        let reports = LockedReports()
        let lighting = LockedLighting()
        let engine = Project2077Engine(
            sendReport: { reports.append($0) },
            onLighting: { lighting.set($0) }
        )
        let requestObject: [String: Any] = [
            "method": "v.oai.rgbcfg",
            "params": [
                "ambient": ["e": 1, "b": 0.75, "s": 0.5, "m": 0, "c": 0x20A0FF],
                "keys": ["e": 2, "b": 1.0, "s": 0.25, "m": 1, "c": 0xFF6D00],
            ],
            "id": 928,
        ]
        let request = try JSONSerialization.data(withJSONObject: requestObject)
        XCTAssertNotEqual(request.last, 0x0A, "The real Work Louder request has no delimiter")

        let hostReports = Project2077.encodePayload(request)
        XCTAssertGreaterThan(hostReports.count, 1, "Exercise a fragmented HID request")
        for report in hostReports {
            try engine.receiveHostReport(report)
        }

        let response = try decodeJSONReports(reports.values)
        XCTAssertEqual((response["id"] as? NSNumber)?.intValue, 928)
        XCTAssertEqual(response["result"] as? Bool, true)
        XCTAssertEqual(lighting.value?.ambient.color, 0x20A0FF)
        XCTAssertEqual(lighting.value?.keys.color, 0xFF6D00)
    }

    private func decodeJSONReports(_ reports: [Data]) throws -> [String: Any] {
        var payload = Data()
        for report in reports {
            payload.append(try Project2077.decodeReport(report))
        }
        if payload.last == 0x0A { payload.removeLast() }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    }
}

private final class LockedReports: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var values: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ report: Data) {
        lock.lock()
        storage.append(report)
        lock.unlock()
    }
}

private final class LockedLighting: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: CodexLightingState?

    var value: CodexLightingState? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: CodexLightingState) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}
