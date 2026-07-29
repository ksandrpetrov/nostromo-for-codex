import Foundation

public enum RazerLED: UInt8, CaseIterable, Sendable {
    case redProfile = 0x0C
    case greenProfile = 0x0D
    case blueProfile = 0x0E
}

public enum RazerProtocol {
    public static let reportLength = 90
    private static let backlightLED: UInt8 = 0x05

    public static func setLED(_ led: RazerLED, enabled: Bool) -> Data {
        makeReport(
            commandClass: 0x03,
            commandID: 0x00,
            arguments: [0x01, led.rawValue, enabled ? 0x01 : 0x00]
        )
    }

    public static func setBrightness(_ brightness: UInt8) -> Data {
        makeReport(
            commandClass: 0x03,
            commandID: 0x03,
            arguments: [0x01, backlightLED, brightness]
        )
    }

    public static func makeReport(
        commandClass: UInt8,
        commandID: UInt8,
        arguments: [UInt8],
        transactionID: UInt8 = 0xFF
    ) -> Data {
        precondition(arguments.count <= 80)
        var report = Data(repeating: 0, count: reportLength)
        report[0] = 0x00
        report[1] = transactionID
        report[4] = 0x00
        report[5] = UInt8(arguments.count)
        report[6] = commandClass
        report[7] = commandID
        report.replaceSubrange(8 ..< (8 + arguments.count), with: arguments)
        report[88] = checksum(report)
        return report
    }

    public static func checksum(_ report: Data) -> UInt8 {
        guard report.count >= 88 else { return 0 }
        return report[2 ..< 88].reduce(0, ^)
    }
}

public struct NostromoLightingSummary: Equatable, Sendable {
    public var red: Bool
    public var green: Bool
    public var blue: Bool
    public var backlightBrightness: UInt8
    public var backlightCeiling: UInt8

    public init(
        red: Bool,
        green: Bool,
        blue: Bool,
        backlightBrightness: UInt8,
        backlightCeiling: UInt8 = 0xFF
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.backlightBrightness = backlightBrightness
        self.backlightCeiling = backlightCeiling
    }

}

/// The aggregate Codex lifecycle state rendered by the three fixed profile
/// LEDs. It is intentionally independent from Codex Micro's own per-slot
/// lighting, which can be turned off by the device inactivity timer while a
/// task is still running.
public enum NostromoCodexIndicatorState: Equatable, Sendable {
    case unavailable
    case ready
    case running
    case needsAttention
}

/// The pure, hardware-ready result of combining Codex state, user lighting
/// settings, and the aggregate Codex lifecycle indicator.
public struct NostromoLightingResolution: Equatable, Sendable {
    public var requestedBrightness: Double
    public var maximumBrightness: Double
    public var appliedBrightness: UInt8
    public var summary: NostromoLightingSummary

    public var taskStatusOwnsIndicators: Bool {
        summary.red || summary.green || summary.blue
    }

    public init(
        requestedBrightness: Double,
        maximumBrightness: Double,
        appliedBrightness: UInt8,
        summary: NostromoLightingSummary
    ) {
        self.requestedBrightness = requestedBrightness
        self.maximumBrightness = maximumBrightness
        self.appliedBrightness = appliedBrightness
        self.summary = summary
    }

    public static func resolve(
        from state: CodexLightingState,
        indicatorState: NostromoCodexIndicatorState,
        settings: LightingSettings
    ) -> NostromoLightingResolution {
        let activeThreadBrightness = state.threads
            .filter { $0.brightness > 0.01 && $0.color != 0 }
            .map(\.brightness)
        let brightnessValues =
            activeThreadBrightness
                + [state.keys.brightness, state.ambient.brightness]
        let dynamicMaximum = brightnessValues.reduce(0) {
            max($0, normalized($1, fallback: 0))
        }
        let requestedBrightness = max(0.16, dynamicMaximum)
        let maximumBrightness = normalized(settings.maximumBrightness, fallback: 1)
        let appliedBrightness = settings.keypadEnabled
            ? byte(from: requestedBrightness * maximumBrightness)
            : 0
        let backlightCeiling = settings.keypadEnabled
            ? byte(from: maximumBrightness)
            : 0

        let indicators: (red: Bool, green: Bool, blue: Bool)
        switch indicatorState {
        case .unavailable:
            indicators = (false, false, false)
        case .ready:
            indicators = (false, false, true)
        case .running:
            indicators = (false, true, false)
        case .needsAttention:
            indicators = (true, false, false)
        }
        let summary = NostromoLightingSummary(
            red: indicators.red,
            green: indicators.green,
            blue: indicators.blue,
            backlightBrightness: appliedBrightness,
            backlightCeiling: backlightCeiling
        )

        return NostromoLightingResolution(
            requestedBrightness: requestedBrightness,
            maximumBrightness: maximumBrightness,
            appliedBrightness: appliedBrightness,
            summary: summary
        )
    }

    private static func normalized(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(1, max(0, value))
    }

    private static func byte(from normalized: Double) -> UInt8 {
        UInt8((min(1, max(0, normalized)) * 255).rounded())
    }
}

public enum NostromoLightingPolicy {
    public static func resolve(
        from state: CodexLightingState,
        indicatorState: NostromoCodexIndicatorState,
        settings: LightingSettings
    ) -> NostromoLightingResolution {
        NostromoLightingResolution.resolve(
            from: state,
            indicatorState: indicatorState,
            settings: settings
        )
    }
}
