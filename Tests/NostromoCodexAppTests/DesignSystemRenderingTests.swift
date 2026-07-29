import AppKit
@testable import NostromoCodexApp
import SwiftUI
import Testing

@MainActor
struct DesignSystemRenderingTests {
    @Test("Design system renders in light and dark appearances")
    func rendersBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            let root = NostromoDesignSystemShowcase()
                .environment(\.colorScheme, scheme)
            let hostingView = NSHostingView(rootView: root)
            hostingView.frame = NSRect(x: 0, y: 0, width: 920, height: 620)
            hostingView.layoutSubtreeIfNeeded()

            guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
                Issue.record("Failed to allocate \(scheme) rendering surface")
                continue
            }
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

            // NSBitmapImageRep reports backing pixels here. On Retina,
            // 920×620 points is correctly represented as 1840×1240 pixels.
            #expect(bitmap.size.width == 920)
            #expect(bitmap.size.height == 620)

            if let outputDirectory = ProcessInfo.processInfo.environment["NOSTROMO_UI_SNAPSHOT_DIR"] {
                let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let name = scheme == .light ? "design-system-light.png" : "design-system-dark.png"
                let destination = directory.appendingPathComponent(name)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: destination)
            }
        }
    }
}
