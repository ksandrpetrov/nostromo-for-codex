import Foundation

public enum CodexSkillCatalogError: LocalizedError {
    case executableMissing
    case invalidResponse
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .executableMissing:
            "Исполняемый файл Codex app-server недоступен."
        case .invalidResponse:
            "Codex вернул некорректный ответ skills/list."
        case let .requestFailed(message):
            "Ошибка Codex skills/list: \(message)"
        }
    }
}

public struct CodexSkillCatalog: Sendable {
    public var executableURL: URL
    public var workspace: URL
    public var responseTimeout: TimeInterval

    public init(
        executableURL: URL = URL(
            fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"
        ),
        workspace: URL,
        responseTimeout: TimeInterval = 3
    ) {
        self.executableURL = executableURL
        self.workspace = workspace
        self.responseTimeout = responseTimeout
    }

    public func load() throws -> [SkillReference] {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CodexSkillCatalogError.executableMissing
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()
        let requests: [[String: Any]] = [
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": ["name": "nostromo-codex", "version": "1"],
                    "capabilities": ["experimentalApi": true],
                ],
            ],
            ["method": "initialized"],
            [
                "id": 2,
                "method": "skills/list",
                "params": [
                    "cwds": [workspace.standardizedFileURL.path],
                    "forceReload": true,
                ],
            ],
        ]
        for request in requests {
            let data = try JSONSerialization.data(withJSONObject: request)
            input.fileHandleForWriting.write(data)
            input.fileHandleForWriting.write(Data([0x0A]))
        }

        let responseState = CodexSkillResponseState()
        let responseReady = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                responseReady.signal()
                return
            }
            if responseState.append(chunk) {
                responseReady.signal()
            }
        }
        _ = responseReady.wait(timeout: .now() + max(0.1, responseTimeout))
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        return try responseState.result()
    }

    public static func parseSkillsListResponse(_ data: Data) throws -> [SkillReference] {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            (object["id"] as? NSNumber)?.intValue == 2
        else {
            throw CodexSkillCatalogError.invalidResponse
        }
        if let error = object["error"] as? [String: Any] {
            throw CodexSkillCatalogError.requestFailed(
                error["message"] as? String ?? "Неизвестная ошибка app-server."
            )
        }
        guard
            let result = object["result"] as? [String: Any],
            let entries = result["data"] as? [[String: Any]]
        else {
            throw CodexSkillCatalogError.invalidResponse
        }

        var found: [String: SkillReference] = [:]
        for entry in entries {
            for skill in entry["skills"] as? [[String: Any]] ?? [] {
                guard
                    let name = skill["name"] as? String,
                    let path = skill["path"] as? String,
                    let enabled = skill["enabled"] as? Bool
                else { continue }
                let interface = skill["interface"] as? [String: Any]
                let displayName = (interface?["displayName"] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 }
                    ?? name.replacingOccurrences(of: "-", with: " ")
                let reference = SkillReference(
                    name: name,
                    displayName: displayName,
                    path: path,
                    enabled: enabled
                )
                found[reference.id] = reference
            }
        }
        return found.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    fileprivate static func skillsResponse(in buffer: Data) throws -> [SkillReference]? {
        for line in buffer.split(separator: 0x0A) where !line.isEmpty {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                (object["id"] as? NSNumber)?.intValue == 2
            else { continue }
            return try parseSkillsListResponse(Data(line))
        }
        return nil
    }
}

private final class CodexSkillResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var response: Result<[SkillReference], Error>?

    func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard response == nil else { return true }
        buffer.append(data)
        do {
            if let skills = try CodexSkillCatalog.skillsResponse(in: buffer) {
                response = .success(skills)
                return true
            }
        } catch {
            response = .failure(error)
            return true
        }
        return false
    }

    func result() throws -> [SkillReference] {
        lock.lock()
        defer { lock.unlock() }
        guard let response else {
            throw CodexSkillCatalogError.invalidResponse
        }
        return try response.get()
    }
}
