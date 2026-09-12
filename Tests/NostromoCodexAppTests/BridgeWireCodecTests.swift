import Foundation
@testable import NostromoCodexApp
import XCTest

final class BridgeWireCodecTests: XCTestCase {
    func testVersionMustBeAnExactProtocolNumber() {
        for version in ["2.5", "2.0001", "true", "null", "\"2\"", "18446744073709551618"] {
            let frame = Data("{\"v\":\(version),\"type\":\"hello\"}".utf8)
            XCTAssertNil(BridgeWireCodec.decodeEnvelope(frame), "Accepted version \(version)")
        }
        XCTAssertNotNil(BridgeWireCodec.decodeEnvelope(Data(#"{"v":2,"type":"hello"}"#.utf8)))
    }

    func testTaskSlotIdentifierCannotBeTruncatedOrCoercedFromBoolean() throws {
        for id in ["1.5", "true", "false", "1e100", "-0.5", "null", "\"1\""] {
            let data = Data("{\"slots\":[{\"id\":\(id),\"status\":\"idle\",\"selected\":false}]}".utf8)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(BridgeWireCodec.taskSlots(from: object), "Accepted slot ID \(id)")
        }
        for id in 0...5 {
            let slots = BridgeWireCodec.taskSlots(from: ["slots": [["id": id, "status": "idle", "selected": false]]])
            XCTAssertEqual(slots?.first?.id, id)
        }
    }
}
