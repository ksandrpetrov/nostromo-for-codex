import Foundation

public struct SkillScanner: Sendable {
    public var roots: [URL]

    public init(roots: [URL]) {
        self.roots = roots
    }

    public static func standard(workspace: URL? = nil) -> SkillScanner {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [
            home.appendingPathComponent(".codex/skills", isDirectory: true),
            home.appendingPathComponent(".agents/skills", isDirectory: true),
            home.appendingPathComponent(".codex/plugins/cache", isDirectory: true),
        ]
        if let workspace {
            roots.append(workspace.appendingPathComponent(".agents/skills", isDirectory: true))
            roots.append(workspace.appendingPathComponent(".codex/skills", isDirectory: true))
        }
        return SkillScanner(roots: roots)
    }

    public func scan() -> [SkillReference] {
        var found: [String: SkillReference] = [:]
        let manager = FileManager.default

        for root in roots where manager.fileExists(atPath: root.path) {
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                guard url.lastPathComponent.caseInsensitiveCompare("SKILL.md") == .orderedSame else { continue }
                guard let skill = parse(url: url) else { continue }
                found[skill.id] = skill
            }
        }

        return found.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func parse(url: URL) -> SkillReference? {
        guard
            let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
            data.count <= 2 * 1024 * 1024,
            let text = String(data: data, encoding: .utf8)
        else { return nil }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            let fallback = url.deletingLastPathComponent().lastPathComponent
            return SkillReference(name: fallback, displayName: fallback, path: url.path)
        }

        var name: String?
        var description: String?
        for line in lines.dropFirst() {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value == "---" { break }
            if value.hasPrefix("name:") {
                name = cleanYAMLValue(String(value.dropFirst(5)))
            } else if value.hasPrefix("description:") {
                description = cleanYAMLValue(String(value.dropFirst(12)))
            }
        }

        let fallback = url.deletingLastPathComponent().lastPathComponent
        let resolvedName = name?.isEmpty == false ? name! : fallback
        let display = resolvedName.replacingOccurrences(of: "-", with: " ")
        _ = description
        return SkillReference(name: resolvedName, displayName: display, path: url.path)
    }

    private func cleanYAMLValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return trimmed }
        if (trimmed.first == "\"" && trimmed.last == "\"") ||
            (trimmed.first == "'" && trimmed.last == "'")
        {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}
