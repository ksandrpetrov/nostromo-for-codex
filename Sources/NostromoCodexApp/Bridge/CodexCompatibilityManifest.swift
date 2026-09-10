import Foundation

/// Shared with the preload. Candidate adapters never become verified merely
/// because a bundle contains familiar strings.
struct CodexCompatibilityManifest: Decodable {
    struct Build: Decodable {
        let version: String
        let build: String
        let adapter: String
        let verified: Bool
    }

    let schemaVersion: Int
    let builds: [Build]
    let serviceMarkers: [String]
    let rendererMarkers: [String]

    static func load() -> Self? {
        guard let preload = AppResourceLocator.preloadURL(
            packagedURL: Bundle.main.resourceURL?.appendingPathComponent("chatgpt-preload.cjs"),
            applicationURLs: [Bundle.main.bundleURL],
            currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ) else { return nil }
        let url = preload.deletingLastPathComponent().appendingPathComponent("codex-compatibility.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Self.self, from: data),
              manifest.schemaVersion == 1,
              !manifest.serviceMarkers.isEmpty, !manifest.rendererMarkers.isEmpty
        else { return nil }
        return manifest
    }

    func entry(version: String, build: String) -> Build? {
        builds.first { $0.version == version && $0.build == build }
    }

    func serviceModule(in archive: Data) -> String? {
        // ASAR's two pickle headers precede the JSON filesystem. Never execute
        // bundle code while inspecting compatibility.
        guard archive.count >= 16 else { return nil }
        func uint32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(archive[offset + $1]) << (8 * $1)) }
        }
        let headerSize = uint32(4)
        let jsonSize = uint32(12)
        guard headerSize >= 8, headerSize <= 16_777_216,
              jsonSize > 0, jsonSize <= headerSize - 8,
              8 + headerSize <= archive.count, 16 + jsonSize <= archive.count,
              let root = try? JSONSerialization.jsonObject(with: archive.subdata(in: 16..<16 + jsonSize)) as? [String: Any],
              let files = root["files"] as? [String: Any],
              let vite = files[".vite"] as? [String: Any],
              let viteFiles = vite["files"] as? [String: Any],
              let build = viteFiles["build"] as? [String: Any],
              let modules = build["files"] as? [String: Any], modules.count <= 4096
        else { return nil }
        var matches: [String] = []
        var inspected = 0
        for (name, value) in modules.sorted(by: { $0.key < $1.key }) {
            guard name.hasSuffix(".js"), !name.contains("/"), !name.contains("\\"),
                  let entry = value as? [String: Any], entry["unpacked"] == nil,
                  let offsetString = entry["offset"] as? String, let offset = Int(offsetString), offset >= 0,
                  let size = entry["size"] as? Int, size >= 0, size <= 16_777_216,
                  inspected + size <= 67_108_864,
                  offset <= archive.count - (8 + headerSize),
                  size <= archive.count - (8 + headerSize) - offset
            else { continue }
            inspected += size
            let start = 8 + headerSize + offset
            let data = archive.subdata(in: start..<start + size)
            if serviceMarkers.allSatisfy({ data.range(of: Data($0.utf8)) != nil }) {
                matches.append(".vite/build/" + name)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
