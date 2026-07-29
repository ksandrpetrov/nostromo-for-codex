@testable import NostromoCodexCore
import XCTest

final class RazerProtocolTests: XCTestCase {
    func testGoldenRedLEDReport() {
        let report = RazerProtocol.setLED(.redProfile, enabled: true)

        XCTAssertEqual(report.count, 90)
        XCTAssertEqual(report[0], 0x00)
        XCTAssertEqual(report[1], 0xFF)
        XCTAssertEqual(report[5], 0x03)
        XCTAssertEqual(report[6], 0x03)
        XCTAssertEqual(report[7], 0x00)
        XCTAssertEqual(Array(report[8 ..< 11]), [0x01, 0x0C, 0x01])
        XCTAssertEqual(report[88], 0x0C)
        XCTAssertEqual(report[89], 0x00)
        XCTAssertEqual(report[88], RazerProtocol.checksum(report))
    }

    func testGoldenBacklightBrightnessReport() {
        let report = RazerProtocol.setBrightness(0x80)
        XCTAssertEqual(Array(report[5 ..< 11]), [0x03, 0x03, 0x03, 0x01, 0x05, 0x80])
        XCTAssertEqual(report[88], RazerProtocol.checksum(report))
    }
}
