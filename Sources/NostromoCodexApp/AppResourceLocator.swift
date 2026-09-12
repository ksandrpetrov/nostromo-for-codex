import Foundation

// MARK: Resource discovery

enum AppResourceLocator {
    private static let packagedPreloadPath =
        "Contents/Resources/chatgpt-preload.cjs"
    private static let developmentPreloadPath =
        "Sources/NostromoCodexApp/Resources/chatgpt-preload.cjs"

    static func preloadURL(
        packagedURL: URL?,
        applicationURLs: [URL],
        currentDirectoryURL: URL
    ) -> URL? {
        var candidates: [URL] = []
        if let packagedURL {
            candidates.append(packagedURL)
        }
        candidates.append(
            contentsOf: applicationURLs.map {
                $0.appendingPathComponent(packagedPreloadPath)
            }
        )
        candidates.append(
            currentDirectoryURL.appendingPathComponent(developmentPreloadPath)
        )

        return candidates.first {
            FileManager.default.isReadableFile(atPath: $0.path)
        }
    }
}
