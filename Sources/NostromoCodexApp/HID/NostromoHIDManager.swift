import Foundation
@preconcurrency import IOKit.hid
import NostromoCodexCore

struct NostromoHIDEvent: Sendable {
    var signature: HIDSignature
    var value: Int
    var timestamp: TimeInterval
    var eligibleForAction: Bool = true
}

enum NostromoDeviceState: Equatable {
    case stopped
    case waitingForPermission
    case disconnected
    case connected(interfaceCount: Int, captureMode: HIDCaptureMode)
    case error(String)
}

enum HIDManagerOpenPolicy {
    struct Result {
        let status: IOReturn
        let seized: Bool
        let exclusiveFailure: IOReturn?
    }

    static func open(
        requestedSeize: Bool,
        attempt: (IOOptionBits) -> IOReturn,
        replacePartiallyOpenedManager: () -> Void
    ) -> Result {
        let initialStatus = attempt(
            requestedSeize
                ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
                : IOOptionBits(kIOHIDOptionsTypeNone)
        )
        guard shouldRetryWithoutSeizing(
            requestedSeize: requestedSeize,
            status: initialStatus
        ) else {
            return Result(
                status: initialStatus,
                seized: requestedSeize && initialStatus == kIOReturnSuccess,
                exclusiveFailure: nil
            )
        }

        replacePartiallyOpenedManager()
        return Result(
            status: attempt(IOOptionBits(kIOHIDOptionsTypeNone)),
            seized: false,
            exclusiveFailure: initialStatus
        )
    }

    static func shouldRetryWithoutSeizing(
        requestedSeize: Bool,
        status: IOReturn
    ) -> Bool {
        requestedSeize
            && (status == kIOReturnNotPrivileged || status == kIOReturnNotPermitted)
    }
}

enum HIDInputCallbackPolicy {
    static func shouldAccept(
        running: Bool,
        sourceDeviceIdentity: UInt?,
        currentDeviceIdentities: Set<UInt>
    ) -> Bool {
        guard running, let sourceDeviceIdentity else { return false }
        return currentDeviceIdentities.contains(sourceDeviceIdentity)
    }
}

struct NostromoLightingEffects {
    var desired: NostromoLightingSummary
    var pressStrength: Double?

    var render: NostromoLightingSummary {
        var summary = desired
        if let pressStrength {
            let strength = pressStrength.isFinite
                ? min(1, max(0, pressStrength))
                : 1
            let base = Double(summary.backlightBrightness)
            let ceiling = Double(max(summary.backlightBrightness, summary.backlightCeiling))
            summary.backlightBrightness = UInt8(
                (base + ((ceiling - base) * strength)).rounded()
            )
        }
        return summary
    }
}

private func deviceMatchedCallback(
    context: UnsafeMutableRawPointer?,
    result _: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<NostromoHIDManager>.fromOpaque(context).takeUnretainedValue()
        .deviceMatched(device, senderIdentity: UInt(bitPattern: sender))
}

private func deviceRemovedCallback(
    context: UnsafeMutableRawPointer?,
    result _: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<NostromoHIDManager>.fromOpaque(context).takeUnretainedValue()
        .deviceRemoved(device, senderIdentity: UInt(bitPattern: sender))
}

private func inputValueCallback(
    context: UnsafeMutableRawPointer?,
    result _: IOReturn,
    sender _: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let context else { return }
    Unmanaged<NostromoHIDManager>.fromOpaque(context).takeUnretainedValue()
        .inputValue(value)
}

/// `queue` owns IOHID manager/device lifecycle, report parsing and lighting
/// state. `handlerLock` protects the only callbacks accessed outside that
/// queue; IOHID callbacks immediately hand work back to the owner.
final class NostromoHIDManager: @unchecked Sendable {
    static let vendorID = 0x1532
    static let productID = 0x0111

    private let inputMonitoringPermission: any InputMonitoringPermissionControlling
    private let handlerLock = NSLock()
    private var eventHandler: (@Sendable (NostromoHIDEvent) -> Void)?
    private var stateHandler: (@Sendable (NostromoDeviceState) -> Void)?
    private var diagnosticHandler: (@Sendable (String) -> Void)?

    var onEvent: (@Sendable (NostromoHIDEvent) -> Void)? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return eventHandler
        }
        set {
            handlerLock.lock()
            eventHandler = newValue
            handlerLock.unlock()
        }
    }

    var onState: (@Sendable (NostromoDeviceState) -> Void)? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return stateHandler
        }
        set {
            handlerLock.lock()
            stateHandler = newValue
            handlerLock.unlock()
        }
    }

    var onDiagnostic: (@Sendable (String) -> Void)? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return diagnosticHandler
        }
        set {
            handlerLock.lock()
            diagnosticHandler = newValue
            handlerLock.unlock()
        }
    }

    private let queue = DispatchQueue(label: "io.nostromo-codex.hid")
    private var manager: IOHIDManager?
    private var managerIdentity: UInt = 0
    private var devices: [IOHIDDevice] = []
    private var featureDevices: [IOHIDDevice] = []
    private var seize = true
    private var running = false
    private var reconnectGate = InputReconnectGate()
    private var lightingEffects = NostromoLightingEffects(
        desired: NostromoLightingSummary(
            red: false,
            green: false,
            blue: false,
            backlightBrightness: 41
        )
    )
    private var lastLightingRender: NostromoLightingSummary?
    private var lightingRenderScheduled = false
    private var lightingRenderGeneration = 0
    private var pressGeneration = 0
    private static let pressPulseDuration: DispatchTimeInterval = .milliseconds(220)

    init(
        inputMonitoringPermission: any InputMonitoringPermissionControlling =
            MacOSInputMonitoringPermissionController()
    ) {
        self.inputMonitoringPermission = inputMonitoringPermission
    }

    func start(seize: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            self.seize = seize

            let access = self.inputMonitoringPermission.checkAccess()
            if access == kIOHIDAccessTypeDenied {
                self.onState?(.waitingForPermission)
                return
            }
            if access == kIOHIDAccessTypeUnknown {
                guard self.inputMonitoringPermission.requestAccess() else {
                    self.onState?(.waitingForPermission)
                    return
                }
            }

            self.running = true
            var manager = self.makeConfiguredManagerOnQueue()

            let openResult = HIDManagerOpenPolicy.open(
                requestedSeize: self.seize,
                attempt: { options in
                    IOHIDManagerOpen(manager, options)
                },
                replacePartiallyOpenedManager: {
                    self.closeManagerOnQueue(manager)
                    self.devices.removeAll()
                    self.featureDevices.removeAll()
                    manager = self.makeConfiguredManagerOnQueue()
                }
            )
            if let exclusiveFailure = openResult.exclusiveFailure {
                self.onDiagnostic?(
                    "macOS запретила эксклюзивный HID-захват (\(exclusiveFailure)); "
                        + "продолжаем в обычном режиме чтения."
                )
            }
            let status = openResult.status
            self.seize = openResult.seized
            if status != kIOReturnSuccess {
                self.running = false
                self.devices.removeAll()
                self.featureDevices.removeAll()
                self.closeManagerOnQueue(manager)
                self.manager = nil
                self.managerIdentity = 0
                self.onState?(.error(Self.openErrorMessage(status)))
            } else if self.devices.isEmpty {
                self.onState?(.disconnected)
            }
        }
    }

    func stop() {
        queue.sync {
            stopOnQueue()
        }
    }

    func requestInputMonitoring() {
        let access = inputMonitoringPermission.checkAccess()
        if access == kIOHIDAccessTypeDenied {
            inputMonitoringPermission.openSettings()
        } else if access == kIOHIDAccessTypeUnknown {
            _ = inputMonitoringPermission.requestAccess()
        }
    }

    private static func openErrorMessage(_ status: IOReturn) -> String {
        if status == kIOReturnNotPrivileged || status == kIOReturnNotPermitted {
            return "macOS запретила доступ к HID-устройству (\(status))."
        }
        if status == kIOReturnExclusiveAccess {
            return "Razer Nostromo уже захвачен другим приложением (\(status))."
        }
        return "Ошибка IOHIDManagerOpen: \(status)"
    }

    func applyLighting(_ summary: NostromoLightingSummary) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lightingEffects.desired = summary
            self.scheduleLightingRenderOnQueue()
        }
    }

    func pulseBacklight(strength: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pressGeneration += 1
            let generation = self.pressGeneration
            self.lightingEffects.pressStrength = strength
            self.renderLightingOnQueue()
            // Ninety milliseconds was shorter than a clearly perceivable
            // brightness pulse on the physical Nostromo. Keep the peak long
            // enough to be visible without delaying input handling.
            self.queue.asyncAfter(deadline: .now() + Self.pressPulseDuration) { [weak self] in
                guard
                    let self,
                    self.pressGeneration == generation
                else {
                    return
                }
                self.lightingEffects.pressStrength = nil
                self.renderLightingOnQueue()
            }
        }
    }

    fileprivate func deviceMatched(_ device: IOHIDDevice, senderIdentity: UInt) {
        queue.async { [weak self] in
            guard
                let self,
                self.running,
                senderIdentity == self.managerIdentity
            else { return }
            let wasDisconnected = self.devices.isEmpty
            if !self.devices.contains(where: { $0 === device }) {
                self.devices.append(device)
            }
            let now = ProcessInfo.processInfo.systemUptime
            if wasDisconnected {
                self.reconnectGate.reconnect(at: now)
            } else {
                self.reconnectGate.extendSettlingPeriod(at: now)
            }
            if let size = IOHIDDeviceGetProperty(device, kIOHIDMaxFeatureReportSizeKey as CFString) as? NSNumber,
               size.intValue >= RazerProtocol.reportLength,
               !self.featureDevices.contains(where: { $0 === device })
            {
                self.featureDevices.append(device)
                self.renderLightingOnQueue(force: true)
            }
            self.onState?(
                .connected(
                    interfaceCount: self.devices.count,
                    captureMode: self.seize ? .exclusive : .shared
                )
            )
        }
    }

    fileprivate func deviceRemoved(_ device: IOHIDDevice, senderIdentity: UInt) {
        queue.async { [weak self] in
            guard
                let self,
                self.running,
                senderIdentity == self.managerIdentity
            else { return }
            self.devices.removeAll(where: { $0 === device })
            self.featureDevices.removeAll(where: { $0 === device })
            if self.devices.isEmpty {
                self.reconnectGate.reset()
            }
            self.onState?(
                self.devices.isEmpty
                    ? .disconnected
                    : .connected(
                        interfaceCount: self.devices.count,
                        captureMode: self.seize ? .exclusive : .shared
                    )
            )
        }
    }

    fileprivate func inputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let sourceDeviceIdentity = Self.deviceIdentity(IOHIDElementGetDevice(element))
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let cookie = UInt64(IOHIDElementGetCookie(element))
        let raw = IOHIDValueGetIntegerValue(value)
        let kind: HIDEventKind = (page == kHIDPage_GenericDesktop &&
            (usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y || usage == kHIDUsage_GD_Wheel))
            ? .axis
            : .button
        let event = NostromoHIDEvent(
            signature: HIDSignature(usagePage: page, usage: usage, cookie: cookie, kind: kind),
            value: raw,
            timestamp: Self.seconds(fromMachAbsoluteTime: IOHIDValueGetTimeStamp(value))
        )
        queue.async { [weak self] in
            guard let self else { return }
            let currentDeviceIdentities = Set(self.devices.map(Self.deviceIdentity))
            guard HIDInputCallbackPolicy.shouldAccept(
                running: self.running,
                sourceDeviceIdentity: sourceDeviceIdentity,
                currentDeviceIdentities: currentDeviceIdentities
            ) else { return }
            let eligibleForAction = self.reconnectGate.shouldForward(
                signature: event.signature,
                value: event.value,
                at: ProcessInfo.processInfo.systemUptime
            )
            self.onEvent?(
                NostromoHIDEvent(
                    signature: event.signature,
                    value: event.value,
                    timestamp: event.timestamp,
                    eligibleForAction: eligibleForAction
                )
            )
        }
    }

    private static func deviceIdentity(_ device: IOHIDDevice) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }

    private func makeConfiguredManagerOnQueue() -> IOHIDManager {
        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        self.manager = manager
        managerIdentity = UInt(
            bitPattern: Unmanaged.passUnretained(manager).toOpaque()
        )
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            deviceMatchedCallback,
            pointer
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            deviceRemovedCallback,
            pointer
        )
        IOHIDManagerRegisterInputValueCallback(
            manager,
            inputValueCallback,
            pointer
        )
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        return manager
    }

    private func closeManagerOnQueue(_ manager: IOHIDManager) {
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func stopOnQueue() {
        running = false
        devices.removeAll()
        featureDevices.removeAll()
        reconnectGate.reset()
        lightingRenderGeneration += 1
        lightingRenderScheduled = false
        pressGeneration += 1
        lightingEffects.pressStrength = nil
        lastLightingRender = nil
        if let manager {
            closeManagerOnQueue(manager)
        }
        manager = nil
        managerIdentity = 0
        onState?(.stopped)
    }

    private func sendFeatureReport(_ report: Data) {
        for device in featureDevices {
            report.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                let status = IOHIDDeviceSetReport(
                    device,
                    kIOHIDReportTypeFeature,
                    CFIndex(0),
                    base,
                    report.count
                )
                if status != kIOReturnSuccess {
                    self.onDiagnostic?(
                        "Ошибка IOHIDDeviceSetReport, код IOReturn: \(status)."
                    )
                }
            }
        }
    }

    private func scheduleLightingRenderOnQueue() {
        guard !lightingRenderScheduled else { return }
        lightingRenderScheduled = true
        lightingRenderGeneration += 1
        let generation = lightingRenderGeneration
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard
                let self,
                self.lightingRenderGeneration == generation
            else {
                return
            }
            self.lightingRenderScheduled = false
            self.renderLightingOnQueue()
        }
    }

    private func renderLightingOnQueue(force: Bool = false) {
        let render = lightingEffects.render
        guard force || render != lastLightingRender else { return }
        lastLightingRender = render
        applyLightingOnQueue(render)
    }

    private func applyLightingOnQueue(_ summary: NostromoLightingSummary) {
        let reports = [
            RazerProtocol.setLED(.redProfile, enabled: summary.red),
            RazerProtocol.setLED(.greenProfile, enabled: summary.green),
            RazerProtocol.setLED(.blueProfile, enabled: summary.blue),
            RazerProtocol.setBrightness(summary.backlightBrightness),
        ]
        for report in reports {
            sendFeatureReport(report)
        }
    }

    private static func seconds(fromMachAbsoluteTime timestamp: UInt64) -> TimeInterval {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timestamp)
            * Double(timebase.numer)
            / Double(timebase.denom)
            / 1_000_000_000
    }
}
