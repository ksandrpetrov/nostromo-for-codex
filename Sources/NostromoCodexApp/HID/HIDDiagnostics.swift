import AppKit
import Foundation
import NostromoCodexCore
import Security

struct HIDDiagnosticEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let sequence: Int
    let recordedAt: Date
    let uptime: TimeInterval
    let receivedAtUptime: TimeInterval
    let callbackLatencyMilliseconds: Double
    let usagePage: UInt32
    let usage: UInt32
    let cookie: UInt64
    let kind: HIDEventKind
    let value: Int
    let eligibleForAction: Bool

    init(
        sequence: Int,
        event: NostromoHIDEvent,
        receivedAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        id = UUID()
        self.sequence = sequence
        recordedAt = Date()
        uptime = event.timestamp
        self.receivedAtUptime = receivedAtUptime
        callbackLatencyMilliseconds = max(0, receivedAtUptime - event.timestamp) * 1_000
        usagePage = event.signature.usagePage
        usage = event.signature.usage
        cookie = event.signature.cookie
        kind = event.signature.kind
        value = event.value
        eligibleForAction = event.eligibleForAction
    }

    var summary: String {
        String(
            format: "#%04d · %04X:%04X · %@ · %d · %.2f мс",
            sequence,
            usagePage,
            usage,
            kind.rawValue,
            value,
            callbackLatencyMilliseconds
        )
    }
}

struct HIDPipelineDiagnostics: Codable, Equatable, Sendable {
    var rawEventCount = 0
    var eligibleEventCount = 0
    var mappedControlCount = 0
    var blockedActionCount = 0
    var bindingExecutionCount = 0
    var bridgeDispatchAttemptCount = 0
    var bridgeDispatchSuccessCount = 0
    var bridgeDispatchFailureCount = 0
    var lastMappedControl: String?
    var lastBinding: String?
    var lastBridgeAction: String?
    var lastDispatchOutcome: String?
}

struct ApplicationIdentityDiagnostics: Codable, Equatable, Sendable {
    let bundleIdentifier: String?
    let runningBundlePath: String
    let registeredBundlePath: String?
    let codeIdentifier: String?
    let teamIdentifier: String?
    let cdHash: String?
    let signatureValidationStatus: Int32?
}

struct HIDDiagnosticExport: Codable {
    let formatVersion: Int
    let generatedAt: Date
    let vendorID: Int
    let productID: Int
    let hidOnlyMode: Bool
    let applicationVersion: String
    let applicationBuild: String
    let applicationBundlePath: String
    let executablePath: String?
    let operatingSystem: String
    let architecture: String
    let applicationIdentity: ApplicationIdentityDiagnostics
    let chatGPTVersion: String
    let chatGPTBuild: String
    let deviceState: String
    let inputProtection: String
    let bridgeStatus: String
    let pipeline: HIDPipelineDiagnostics
    let diagnosticMessages: [String]
    let events: [HIDDiagnosticEntry]
}

enum ApplicationDiagnostics {
    static var runtimeArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    @MainActor
    static var current:
        ApplicationIdentityDiagnostics
    {
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let registeredURL = bundleIdentifier.flatMap {
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: $0
            )
        }
        var dynamicCode: SecCode?
        var staticCode: SecStaticCode?
        var signingInfo: CFDictionary?
        var validationStatus: OSStatus?
        if SecCodeCopySelf([], &dynamicCode) == errSecSuccess,
           let dynamicCode,
           SecCodeCopyStaticCode(dynamicCode, [], &staticCode)
            == errSecSuccess,
           let staticCode
        {
            validationStatus = SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                nil
            )
            _ = SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &signingInfo
            )
        }
        let dictionary = signingInfo as? [String: Any]
        let unique = dictionary?[
            kSecCodeInfoUnique as String
        ] as? Data
        return ApplicationIdentityDiagnostics(
            bundleIdentifier: bundleIdentifier,
            runningBundlePath: Bundle.main.bundleURL.path,
            registeredBundlePath: registeredURL?.path,
            codeIdentifier:
                dictionary?[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier:
                dictionary?[kSecCodeInfoTeamIdentifier as String] as? String,
            cdHash: unique?.map {
                String(format: "%02x", $0)
            }.joined(),
            signatureValidationStatus: validationStatus
        )
    }

}


struct HIDDiagnostics {
    private(set) var events: [HIDDiagnosticEntry] = []
    var messages: [String] = []
    var pipeline = HIDPipelineDiagnostics()
    private var nextSequence = 1

    mutating func record(_ event: NostromoHIDEvent, limit: Int) {
        pipeline.rawEventCount += 1
        events.append(HIDDiagnosticEntry(sequence: nextSequence, event: event))
        nextSequence += 1
        if events.count > limit { events.removeFirst(events.count - limit) }
        if event.eligibleForAction { pipeline.eligibleEventCount += 1 }
    }

    mutating func clear() {
        events.removeAll(keepingCapacity: true)
        pipeline = HIDPipelineDiagnostics()
        nextSequence = 1
    }

    var latencyP95Milliseconds: Double? {
        guard !events.isEmpty else { return nil }
        let sorted = events.map(\.callbackLatencyMilliseconds).sorted()
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1))
        return sorted[index]
    }
}

extension HIDDiagnosticExport {
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
