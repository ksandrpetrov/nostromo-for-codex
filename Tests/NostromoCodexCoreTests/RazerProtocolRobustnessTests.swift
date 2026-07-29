import Foundation
@testable import NostromoCodexCore
import XCTest

final class RazerProtocolRobustnessTests: XCTestCase {
    func testGoldenLEDReportsForEveryLEDAndState() {
        for led in RazerLED.allCases {
            for enabled in [false, true] {
                let report = RazerProtocol.setLED(led, enabled: enabled)
                let expectedArguments: [UInt8] = [0x01, led.rawValue, enabled ? 0x01 : 0x00]
                let expectedChecksum = independentChecksum(
                    dataSize: 3,
                    commandClass: 0x03,
                    commandID: 0x00,
                    arguments: expectedArguments
                )

                assertCommonEnvelope(report)
                XCTAssertEqual(Array(report[5 ..< 11]), [0x03, 0x03, 0x00] + expectedArguments)
                XCTAssertEqual(report[88], expectedChecksum)
                XCTAssertEqual(report[89], 0)
                XCTAssertTrue(report[11 ..< 88].allSatisfy { $0 == 0 })
            }
        }
    }

    func testGoldenBrightnessReportsAtBoundaries() {
        for brightness: UInt8 in [0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF] {
            let report = RazerProtocol.setBrightness(brightness)
            let arguments: [UInt8] = [0x01, 0x05, brightness]
            let expectedChecksum = independentChecksum(
                dataSize: 3,
                commandClass: 0x03,
                commandID: 0x03,
                arguments: arguments
            )

            assertCommonEnvelope(report)
            XCTAssertEqual(Array(report[5 ..< 11]), [0x03, 0x03, 0x03] + arguments)
            XCTAssertEqual(report[88], expectedChecksum)
            XCTAssertEqual(report[88], UInt8(0x07) ^ brightness)
            XCTAssertTrue(report[11 ..< 88].allSatisfy { $0 == 0 })
        }
    }

    func testMaximumArgumentReportUsesEntireArgumentArea() {
        let arguments = (0 ..< 80).map { UInt8($0) }
        let report = RazerProtocol.makeReport(
            commandClass: 0xAB,
            commandID: 0xCD,
            arguments: arguments,
            transactionID: 0x42
        )

        XCTAssertEqual(report.count, RazerProtocol.reportLength)
        XCTAssertEqual(report[0], 0)
        XCTAssertEqual(report[1], 0x42)
        XCTAssertEqual(report[5], 80)
        XCTAssertEqual(report[6], 0xAB)
        XCTAssertEqual(report[7], 0xCD)
        XCTAssertEqual(Array(report[8 ..< 88]), arguments)
        XCTAssertEqual(
            report[88],
            independentChecksum(
                dataSize: 80,
                commandClass: 0xAB,
                commandID: 0xCD,
                arguments: arguments
            )
        )
        XCTAssertEqual(report[89], 0)
    }

    func testEmptyArgumentReportHasGoldenLayout() {
        let report = RazerProtocol.makeReport(
            commandClass: 0x10,
            commandID: 0x20,
            arguments: [],
            transactionID: 0x33
        )

        XCTAssertEqual(report.count, 90)
        XCTAssertEqual(Array(report[0 ..< 8]), [0, 0x33, 0, 0, 0, 0, 0x10, 0x20])
        XCTAssertTrue(report[8 ..< 88].allSatisfy { $0 == 0 })
        XCTAssertEqual(report[88], 0x30)
        XCTAssertEqual(report[89], 0)
    }

    func testChecksumCoversOnlyProtocolBytesTwoThroughEightySeven() {
        var report = RazerProtocol.makeReport(
            commandClass: 3,
            commandID: 4,
            arguments: [1, 2, 3, 4]
        )
        let original = RazerProtocol.checksum(report)

        report[0] ^= 0xFF
        report[1] ^= 0xFF
        report[88] ^= 0xFF
        report[89] ^= 0xFF
        XCTAssertEqual(RazerProtocol.checksum(report), original)

        report[40] ^= 0xA5
        XCTAssertEqual(RazerProtocol.checksum(report), original ^ 0xA5)
        XCTAssertEqual(RazerProtocol.checksum(Data()), 0)
        XCTAssertEqual(RazerProtocol.checksum(Data(repeating: 0xFF, count: 87)), 0)
    }

    func testTenThousandDeterministicReportsHaveValidLayoutAndChecksum() {
        var generator = RazerDeterministicGenerator(seed: 0x1532_0111)

        for iteration in 0 ..< 10_000 {
            let argumentCount = Int(generator.next() % 81)
            let arguments = (0 ..< argumentCount).map { _ in
                UInt8(truncatingIfNeeded: generator.next())
            }
            let commandClass = UInt8(truncatingIfNeeded: generator.next())
            let commandID = UInt8(truncatingIfNeeded: generator.next())
            let transactionID = UInt8(truncatingIfNeeded: generator.next())
            let report = RazerProtocol.makeReport(
                commandClass: commandClass,
                commandID: commandID,
                arguments: arguments,
                transactionID: transactionID
            )

            XCTAssertEqual(report.count, 90, "iteration \(iteration)")
            XCTAssertEqual(report[0], 0, "iteration \(iteration)")
            XCTAssertEqual(report[1], transactionID, "iteration \(iteration)")
            XCTAssertEqual(report[5], UInt8(argumentCount), "iteration \(iteration)")
            XCTAssertEqual(report[6], commandClass, "iteration \(iteration)")
            XCTAssertEqual(report[7], commandID, "iteration \(iteration)")
            XCTAssertEqual(Array(report[8 ..< (8 + argumentCount)]), arguments, "iteration \(iteration)")
            XCTAssertTrue(report[(8 + argumentCount) ..< 88].allSatisfy { $0 == 0 })
            XCTAssertEqual(
                report[88],
                independentChecksum(
                    dataSize: UInt8(argumentCount),
                    commandClass: commandClass,
                    commandID: commandID,
                    arguments: arguments
                ),
                "iteration \(iteration)"
            )
            XCTAssertEqual(report[89], 0, "iteration \(iteration)")
        }
    }

    private func assertCommonEnvelope(
        _ report: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(report.count, RazerProtocol.reportLength, file: file, line: line)
        XCTAssertEqual(report[0], 0, file: file, line: line)
        XCTAssertEqual(report[1], 0xFF, file: file, line: line)
        XCTAssertEqual(report[2], 0, file: file, line: line)
        XCTAssertEqual(report[3], 0, file: file, line: line)
        XCTAssertEqual(report[4], 0, file: file, line: line)
        XCTAssertEqual(report[89], 0, file: file, line: line)
        XCTAssertEqual(report[88], RazerProtocol.checksum(report), file: file, line: line)
    }

    private func independentChecksum(
        dataSize: UInt8,
        commandClass: UInt8,
        commandID: UInt8,
        arguments: [UInt8]
    ) -> UInt8 {
        ([0, 0, 0, dataSize, commandClass, commandID] + arguments).reduce(0, ^)
    }
}

private struct RazerDeterministicGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
        return state
    }
}
