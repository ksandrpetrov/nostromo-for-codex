import Foundation
@testable import NostromoCodexApp
import NostromoCodexCore
import XCTest

final class CodexCompatibilityTests: XCTestCase {
    func testRenamedServiceIsFoundByContractAndAmbiguityFailsClosed() throws {
        let manifest = try XCTUnwrap(CodexCompatibilityManifest.load())
        let source = manifest.serviceMarkers.joined(separator: ";")
        XCTAssertEqual(manifest.serviceModule(in: archive(["service-future.js": source])), ".vite/build/service-future.js")
        XCTAssertNil(manifest.serviceModule(in: archive(["service-a.js": source, "service-b.js": source])))
        XCTAssertNil(manifest.serviceModule(in: archive(["service-a.js": "exports.CodexMicroService=stub"])))
        XCTAssertNil(manifest.serviceModule(in: Data(repeating: 255, count: 32)))
    }

    func testVersionBuildPairAndCandidateRemainExplicit() throws {
        let manifest = try XCTUnwrap(CodexCompatibilityManifest.load())
        XCTAssertEqual(manifest.entry(version: "26.721.41059", build: "5848")?.verified, true)
        XCTAssertEqual(manifest.entry(version: "26.903.61454", build: "8378")?.verified, false)
        XCTAssertNil(manifest.entry(version: "future", build: "5848"))
        XCTAssertFalse(ChatGPTLauncher.supportedBuilds.contains("8378"))
    }

    func testCapabilitiesRequireEverySurfaceAndCurrentInstallation() {
        let compatibility = ChatGPTCompatibility(version: "version", build: "42", supported: true)
        var capabilities = ChatGPTRuntimeCapabilities(
            commandIDs: ["newTask"], commandRegistrySource: "runtime-app-asar",
            requiredAPIs: ["browserWindow": true, "rendererMessaging": true, "rendererEvaluation": true, "scopedHidHook": true, "microServiceHook": true],
            unavailableFeatures: [], chatGPTVersion: "version", chatGPTBuild: "42", adapterID: "micro-v1"
        )
        XCTAssertTrue(capabilities.matches(compatibility))
        capabilities.chatGPTBuild = "41"
        XCTAssertFalse(capabilities.matches(compatibility))
        capabilities.chatGPTBuild = "42"
        capabilities.requiredAPIs["microServiceHook"] = false
        XCTAssertFalse(capabilities.matches(compatibility))
    }

    func testFallbackNeverIncludesConsequentialOrUnmappedActions() {
        let catalog = CodexActionCatalog.fallbackCatalog
        XCTAssertEqual(Set(catalog.filter(\.available).map(\.id)), Set(CodexFallbackAction.allCases.map(\.rawValue)))
        XCTAssertFalse(catalog.contains { $0.available && $0.consequential })
    }

    @MainActor
    func testFallbackMenuMatchingDoesNotGuessSimilarOrDestructiveTitles() {
        XCTAssertTrue(CodexFallbackController.matches("Settings…", action: .settings))
        XCTAssertTrue(CodexFallbackController.matches("Новый чат", action: .newTask))
        XCTAssertFalse(CodexFallbackController.matches("New Temporary Chat", action: .newTask))
        XCTAssertFalse(CodexFallbackController.matches("Reset Settings…", action: .settings))
        XCTAssertFalse(CodexFallbackController.matches("Archive Chat", action: .newTask))
    }

    private func archive(_ sources: [String: String]) -> Data {
        var body = Data()
        var entries: [String: Any] = [:]
        for (name, source) in sources.sorted(by: { $0.key < $1.key }) {
            let data = Data(source.utf8)
            entries[name] = ["offset": String(body.count), "size": data.count]
            body.append(data)
        }
        let json = try! JSONSerialization.data(withJSONObject: ["files": [".vite": ["files": ["build": ["files": entries]]]]])
        var result = Data()
        for number in [4, json.count + 8, json.count + 4, json.count] {
            var value = UInt32(number).littleEndian
            withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        result.append(json)
        result.append(body)
        return result
    }
}
