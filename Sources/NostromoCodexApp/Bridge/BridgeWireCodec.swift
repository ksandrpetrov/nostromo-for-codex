import Foundation
import NostromoCodexCore

/// Pure protocol-v2 parsing and validation. Socket ownership, authentication
/// and callback delivery remain in UnixSocketBridge.
enum BridgeWireCodec {
    static let maximumReceiveBufferBytes = 1_024 * 1_024

    struct Envelope {
        let type: String
        let object: [String: Any]
    }

    static func decodeEnvelope(_ line: Data) -> Envelope? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            exactInteger(object["v"]) == 2,
            let type = object["type"] as? String
        else {
            return nil
        }
        return Envelope(type: type, object: object)
    }

    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return Int(exactly: number.doubleValue)
    }

    static func serialize(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        data.append(0x0A)
        return data
    }

    static func hostReport(from object: [String: Any]) -> Data? {
        guard
            let encoded = object["data"] as? String,
            let report = Data(base64Encoded: encoded),
            report.count == Project2077.reportLength
        else {
            return nil
        }
        return report
    }

    static func capabilities(
        from object: [String: Any]
    ) -> ChatGPTRuntimeCapabilities? {
        guard
            let commandIDs = object["commandIds"] as? [String],
            commandIDs.count <= 512,
            let source = object["commandRegistrySource"] as? String,
            let requiredAPIs = object["requiredApis"] as? [String: Bool],
            requiredAPIs.count <= 32,
            let unavailable = object["unavailableFeatures"] as? [String],
            unavailable.count <= 64
        else {
            return nil
        }
        return ChatGPTRuntimeCapabilities(
            commandIDs: Set(commandIDs),
            commandRegistrySource: source,
            requiredAPIs: requiredAPIs,
            unavailableFeatures: unavailable,
            chatGPTVersion: (object["chatGPTVersion"] as? String).flatMap { $0.count <= 64 ? $0 : nil },
            chatGPTBuild: (object["chatGPTBuild"] as? String).flatMap { $0.count <= 32 ? $0 : nil },
            adapterID: (object["adapterID"] as? String).flatMap { $0.count <= 64 ? $0 : nil }
        )
    }

    static func runtimeState(
        from object: [String: Any]
    ) -> ChatGPTRuntimeState? {
        let effort = object["reasoningEffort"] as? String
        guard effort == nil || effort?.count ?? 0 <= 32 else { return nil }
        return ChatGPTRuntimeState(reasoningEffort: effort)
    }

    static func taskSlots(from object: [String: Any]) -> [CodexTaskSlot]? {
        guard
            let records = object["slots"] as? [[String: Any]],
            records.count <= 6
        else {
            return nil
        }

        var identifiers = Set<Int>()
        var slots: [CodexTaskSlot] = []
        slots.reserveCapacity(records.count)

        for record in records {
            guard
                let id = exactInteger(record["id"]),
                (0 ... 5).contains(id),
                identifiers.insert(id).inserted,
                let rawStatus = record["status"] as? String,
                let status = CodexTaskStatus(rawValue: rawStatus),
                let selected = record["selected"] as? Bool
            else {
                return nil
            }

            let title: String?
            if record["title"] == nil || record["title"] is NSNull {
                title = nil
            } else if let value = record["title"] as? String, value.count <= 256 {
                title = value
            } else {
                return nil
            }
            slots.append(
                CodexTaskSlot(
                    id: id,
                    title: title,
                    status: status,
                    selected: selected
                )
            )
        }
        return slots.sorted { $0.id < $1.id }
    }
}
