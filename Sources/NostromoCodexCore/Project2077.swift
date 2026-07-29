import Foundation

public enum Project2077 {
    public static let vendorID = 0x303A
    public static let productID = 0x8360
    public static let usagePage = 0xFF00
    public static let usage = 1
    public static let reportID: UInt8 = 6
    public static let channel: UInt8 = 2
    public static let reportLength = 64
    public static let maxPayloadLength = 61
    public static let firmwareVersion = "0.3.0"

    public static func decodeReport(_ report: Data) throws -> Data {
        guard report.count == reportLength else {
            throw Project2077Error.invalidReportLength(report.count)
        }
        guard report[report.startIndex] == reportID else {
            throw Project2077Error.invalidReportID(report[report.startIndex])
        }
        let payloadLength = Int(report[report.startIndex + 2])
        guard payloadLength <= maxPayloadLength else {
            throw Project2077Error.invalidPayloadLength(payloadLength)
        }
        return report.subdata(in: 3 ..< (3 + payloadLength))
    }

    public static func encodePayload(_ payload: Data) -> [Data] {
        guard !payload.isEmpty else { return [] }
        var reports: [Data] = []
        var offset = 0
        while offset < payload.count {
            let length = min(maxPayloadLength, payload.count - offset)
            var report = Data(repeating: 0, count: reportLength)
            report[0] = reportID
            report[1] = channel
            report[2] = UInt8(length)
            report.replaceSubrange(3 ..< (3 + length), with: payload[offset ..< (offset + length)])
            reports.append(report)
            offset += length
        }
        return reports
    }

    public static func encodeJSON(_ object: [String: Any]) throws -> [Data] {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return encodePayload(data)
    }
}

public enum Project2077Error: LocalizedError, Equatable {
    case invalidReportLength(Int)
    case invalidReportID(UInt8)
    case invalidPayloadLength(Int)
    case malformedJSON

    public var errorDescription: String? {
        switch self {
        case let .invalidReportLength(length):
            "Ожидался 64-байтный отчёт Project2077, получено байт: \(length)."
        case let .invalidReportID(id):
            "Неожиданный идентификатор отчёта Project2077: \(id)."
        case let .invalidPayloadLength(length):
            "Размер данных Project2077 (\(length) байт) превышает 61 байт."
        case .malformedJSON:
            "Project2077 отправил некорректный JSON."
        }
    }
}

public struct ThreadLighting: Codable, Hashable, Sendable {
    public var id: Int
    public var color: Int
    public var brightness: Double
    public var effect: Int
    public var speed: Double
    public var selected: Bool

    public init(
        id: Int,
        color: Int = 0,
        brightness: Double = 0,
        effect: Int = 0,
        speed: Double = 0,
        selected: Bool = false
    ) {
        self.id = id
        self.color = color
        self.brightness = brightness
        self.effect = effect
        self.speed = speed
        self.selected = selected
    }
}

public struct ZoneLighting: Codable, Hashable, Sendable {
    public var effect: Int
    public var brightness: Double
    public var speed: Double
    public var magic: Int
    public var color: Int

    public init(effect: Int = 0, brightness: Double = 0, speed: Double = 0, magic: Int = 0, color: Int = 0) {
        self.effect = effect
        self.brightness = brightness
        self.speed = speed
        self.magic = magic
        self.color = color
    }
}

public struct CodexLightingState: Codable, Hashable, Sendable {
    public var threads: [ThreadLighting]
    public var keys: ZoneLighting
    public var ambient: ZoneLighting

    public init(
        threads: [ThreadLighting] = (0 ..< 6).map { ThreadLighting(id: $0) },
        keys: ZoneLighting = ZoneLighting(),
        ambient: ZoneLighting = ZoneLighting()
    ) {
        self.threads = threads
        self.keys = keys
        self.ambient = ambient
    }
}

public final class Project2077Engine: @unchecked Sendable {
    public typealias ReportSender = @Sendable (Data) -> Void
    public typealias LightingHandler = @Sendable (CodexLightingState) -> Void

    private let lock = NSLock()
    private let sendReport: ReportSender
    private let onLighting: LightingHandler
    private var pending = Data()
    private var lighting = CodexLightingState()

    public init(sendReport: @escaping ReportSender, onLighting: @escaping LightingHandler) {
        self.sendReport = sendReport
        self.onLighting = onLighting
    }

    public func receiveHostReport(_ report: Data) throws {
        let payload = try Project2077.decodeReport(report)
        lock.lock()
        pending.append(payload)
        let messages = drainMessagesLocked()
        lock.unlock()

        for message in messages {
            try handle(message)
        }
    }

    public func emitKey(_ key: String, pressed: Bool, agent: Int? = nil) throws {
        var params: [String: Any] = ["k": key, "act": pressed ? 1 : 0]
        if let agent { params["ag"] = agent }
        try sendJSON(["method": "v.oai.hid", "params": params])
    }

    public func emitEncoder(delta: Int) throws {
        guard delta != 0 else { return }
        let key = delta > 0 ? "ENC_CW" : "ENC_CC"
        for _ in 0 ..< abs(delta) {
            try emitKey(key, pressed: true)
        }
    }

    public func emitJoystick(direction: DPadDirection, active: Bool) throws {
        let angle: Double
        switch direction {
        case .up: angle = 0
        case .upRight: angle = 0.125
        case .right: angle = 0.25
        case .downRight: angle = 0.375
        case .down: angle = 0.5
        case .downLeft: angle = 0.625
        case .left: angle = 0.75
        case .upLeft: angle = 0.875
        }
        try sendJSON([
            "method": "v.oai.rad",
            "params": ["a": angle, "d": active ? 1.0 : 0.0],
        ])
    }

    public func currentLighting() -> CodexLightingState {
        lock.withLock { lighting }
    }

    public func resetTransport() {
        lock.withLock {
            pending.removeAll(keepingCapacity: true)
        }
    }

    private func drainMessagesLocked() -> [Data] {
        var messages: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let message = pending[..<newline]
            pending.removeSubrange(...newline)
            if !message.isEmpty { messages.append(Data(message)) }
        }
        // Work Louder's current HID transport sends JSON-RPC requests without
        // a trailing newline. A response still needs the newline because its
        // parser is line-oriented, but waiting for one on the request side
        // leaves every control-plane call pending until the SDK times out.
        //
        // Requests are serialized one at a time by WLRPCClient, so a complete
        // top-level object is also an unambiguous frame boundary. Keep partial
        // multi-report objects buffered until JSONSerialization can decode the
        // complete request.
        if Self.isCompleteRequest(pending) {
            messages.append(pending)
            pending.removeAll(keepingCapacity: true)
        }
        if pending.count > 256 * 1024 {
            pending.removeAll(keepingCapacity: true)
        }
        return messages
    }

    private static func isCompleteRequest(_ data: Data) -> Bool {
        guard
            !data.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: data),
            let request = object as? [String: Any],
            request["method"] is String
        else {
            return false
        }
        return true
    }

    private func handle(_ data: Data) throws {
        guard
            let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let method = request["method"] as? String
        else {
            throw Project2077Error.malformedJSON
        }

        let id = request["id"]
        let result: Any?
        switch method {
        case "sys.version":
            result = ["version": Project2077.firmwareVersion]
        case "device.status":
            result = [
                "version": Project2077.firmwareVersion,
                "profile_index": 0,
                "layer_index": 0,
                "battery": 100,
                "is_charging": true,
            ]
        case "v.oai.thstatus":
            updateThreads(request["params"])
            result = true
        case "v.oai.rgbcfg":
            updateZones(request["params"])
            result = true
        default:
            if let id {
                try sendJSON([
                    "id": id,
                    "error": ["code": -32601, "message": "Метод не найден: \(method)"],
                ])
            }
            return
        }

        if let id, let result {
            try sendJSON(["id": id, "result": result])
        }
    }

    private func updateThreads(_ value: Any?) {
        guard let records = value as? [[String: Any]] else { return }
        let state = lock.withLock { () -> CodexLightingState in
            for record in records {
                guard let id = Self.integer(record["id"]), lighting.threads.indices.contains(id) else { continue }
                var thread = lighting.threads[id]
                if let color = Self.integer(record["c"]) { thread.color = color }
                if let brightness = Self.double(record["b"]) { thread.brightness = min(1, max(0, brightness)) }
                if let effect = Self.integer(record["e"]) { thread.effect = effect }
                if let speed = Self.double(record["s"]) { thread.speed = min(1, max(0, speed)) }
                thread.selected = (record["sk"] as? Bool) == true || (record["sa"] as? Bool) == true
                lighting.threads[id] = thread
            }
            return lighting
        }
        onLighting(state)
    }

    private func updateZones(_ value: Any?) {
        guard let object = value as? [String: Any] else { return }
        let state = lock.withLock { () -> CodexLightingState in
            lighting.keys = Self.zone(from: object["keys"], previous: lighting.keys)
            lighting.ambient = Self.zone(from: object["ambient"], previous: lighting.ambient)
            return lighting
        }
        onLighting(state)
    }

    private func sendJSON(_ object: [String: Any]) throws {
        for report in try Project2077.encodeJSON(object) {
            sendReport(report)
        }
    }

    private static func zone(from value: Any?, previous: ZoneLighting) -> ZoneLighting {
        guard let object = value as? [String: Any] else { return previous }
        return ZoneLighting(
            effect: integer(object["e"]) ?? previous.effect,
            brightness: double(object["b"]) ?? previous.brightness,
            speed: double(object["s"]) ?? previous.speed,
            magic: integer(object["m"]) ?? previous.magic,
            color: integer(object["c"]) ?? previous.color
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
