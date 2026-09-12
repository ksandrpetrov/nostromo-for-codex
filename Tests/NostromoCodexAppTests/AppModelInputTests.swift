import Foundation
@testable import NostromoCodexApp
import NostromoCodexCore
import SwiftUI
import XCTest

@MainActor
final class AppModelInputTests: AppModelTestCase {
    func testControllerAlwaysRequestsExclusiveCapture() {
        let fixture = makeFixture()

        fixture.model.connectController()

        XCTAssertEqual(fixture.hid.startSeizeValues, [true])
    }

    func testInputTestHighlightsControlsAndNeverDispatchesAssignment() async {
        let fixture = makeFixture()
        let model = fixture.model
        model.setBinding(.codexAction("composer.submit"), for: .key01)
        model.setInputTestMode(true)

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertTrue(model.activeControls.contains(.key01))
        XCTAssertTrue(fixture.bridge.actions.isEmpty)

        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertFalse(model.activeControls.contains(.key01))
        XCTAssertTrue(fixture.bridge.actions.isEmpty)

        fixture.hid.emit(
            signature: HIDSignature(usagePage: 0x01, usage: 0x38, cookie: 90, kind: .axis),
            value: 1
        )
        fixture.hid.emitButton(.wheelPress, pressed: true, configuration: model.configuration)
        fixture.hid.emitButton(.wheelPress, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.wheelMode, .scroll)
        XCTAssertTrue(fixture.bridge.actions.isEmpty)
    }

    func testDisconnectStopsLatchedPushToTalk() async {
        let fixture = makeFixture()
        let model = fixture.model
        model.setBinding(.codexAction("pushToTalk"), for: .key01)
        let signature = try! XCTUnwrap(model.configuration.calibration.signatures[.key01])

        fixture.hid.emit(signature: signature, value: 1, timestamp: 1)
        await settle()
        fixture.hid.emit(signature: signature, value: 0, timestamp: 1.1)
        await settle()
        fixture.hid.emit(signature: signature, value: 1, timestamp: 1.25)
        await settle()
        fixture.hid.emit(signature: signature, value: 0, timestamp: 1.3)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.suffix(2).map(\.name), [
            "push-to-talk-stop",
            "push-to-talk-start",
        ])

        fixture.hid.emit(state: .disconnected)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "push-to-talk-stop")
    }

    func testBridgeDisconnectResetsPushToTalkStateBeforeReconnect() async {
        let fixture = makeFixture()
        let model = fixture.model
        model.setBinding(.codexAction("pushToTalk"), for: .key01)
        fixture.bridge.onStatus?(.connected)
        fixture.bridge.onCapabilities?(completeTestCapabilities())
        await settle()

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "push-to-talk-start")

        fixture.bridge.onStatus?(.listening)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "push-to-talk-stop")

        fixture.bridge.onStatus?(.connected)
        fixture.bridge.onCapabilities?(completeTestCapabilities())
        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertNotEqual(fixture.bridge.actions.last?.name, "push-to-talk-start")
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()
        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "push-to-talk-start")
    }

    func testCalibrationWaitsForReleaseAndRejectsRepeatedPhysicalButton() async {
        let fixture = makeFixture()
        let model = fixture.model
        let originalCalibration = model.configuration.calibration
        let first = HIDSignature(usagePage: 7, usage: 100, cookie: 41, kind: .button)
        let second = HIDSignature(usagePage: 7, usage: 101, cookie: 42, kind: .button)

        model.beginCalibration()
        fixture.hid.emit(signature: first, value: 1)
        await settle()
        XCTAssertEqual(model.calibrationTarget, .key02)
        XCTAssertEqual(model.configuration.calibration, originalCalibration)

        // Hardware auto-repeat while the first key remains held must not
        // consume the next calibration slot.
        fixture.hid.emit(signature: first, value: 1)
        await settle()
        XCTAssertEqual(model.calibrationTarget, .key02)

        fixture.hid.emit(signature: first, value: 0)
        await settle()
        fixture.hid.emit(signature: first, value: 1)
        await settle()
        XCTAssertEqual(model.calibrationTarget, .key02)
        XCTAssertNotNil(model.lastError)

        fixture.hid.emit(signature: first, value: 0)
        await settle()
        fixture.hid.emit(signature: second, value: 1)
        await settle()
        XCTAssertEqual(model.calibrationTarget, .key03)
        XCTAssertEqual(model.configuration.calibration, originalCalibration)
    }

    func testCancelCalibrationDiscardsAmbiguousDraftAndPreservesPhysicalMapping() async throws {
        let fixture = makeFixture()
        let model = fixture.model
        let originalCalibration = model.configuration.calibration
        let key02Signature = try XCTUnwrap(originalCalibration.signatures[.key02])
        let plugin = PluginPrompt(uri: "plugin://safe", displayName: "Safe")
        model.setBinding(.none, for: .key01)
        model.setBinding(.pluginPrompt(plugin), for: .key02)

        model.beginCalibration()
        // Deliberately press key02 while the wizard asks for key01. The draft
        // is temporarily ambiguous, but the live map must remain untouched.
        fixture.hid.emit(signature: key02Signature, value: 1)
        await settle()
        fixture.hid.emit(signature: key02Signature, value: 0)
        await settle()
        XCTAssertEqual(model.calibrationTarget, .key02)
        XCTAssertEqual(model.configuration.calibration, originalCalibration)

        model.cancelCalibration()
        XCTAssertEqual(model.configuration.calibration, originalCalibration)
        fixture.hid.emit(signature: key02Signature, value: 1)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "prepare-plugin-prompt")
    }

    func testCalibrationDoesNotExecuteBindings() async {
        let fixture = makeFixture()
        let model = fixture.model
        model.setBinding(.codexAction("composer.togglePlanMode"), for: .key01)
        let signature = HIDSignature(usagePage: 7, usage: 110, cookie: 50, kind: .button)
        let before = fixture.bridge.actions.count

        model.beginCalibration()
        fixture.hid.emit(signature: signature, value: 1)
        await settle()
        fixture.hid.emit(
            signature: HIDSignature(usagePage: 0x01, usage: 0x38, cookie: 101, kind: .axis),
            value: 1
        )
        await settle()
        fixture.hid.emit(signature: signature, value: 0)
        await settle()

        XCTAssertEqual(fixture.bridge.actions.count, before)
        XCTAssertEqual(model.calibrationTarget, .key02)
    }

    func testPhysicalKeyboardPageDPadExecutesDiagonalExactlyOnce() async {
        let clock = ManualRuntimeClock()
        let fixture = makeFixture(clock: clock)
        let model = fixture.model
        let originalID = model.configuration.activeProfileID
        let target = ControllerProfile(name: "Keyboard D-pad", bindings: [:])
        model.configuration.profiles.append(target)
        model.setBinding(
            .profileSwitch(profileID: target.id, behavior: .momentary),
            for: .dpadUpRight
        )
        let now = clock.now

        fixture.hid.emit(
            signature: HIDSignature(
                usagePage: 0x07,
                usage: 0x50,
                cookie: 201,
                kind: .button
            ),
            value: 1,
            timestamp: now
        )
        fixture.hid.emit(
            signature: HIDSignature(
                usagePage: 0x07,
                usage: 0x52,
                cookie: 202,
                kind: .button
            ),
            value: 1,
            timestamp: now + 0.002
        )
        await advance(clock, by: 0.025)
        XCTAssertEqual(model.configuration.activeProfileID, target.id)

        fixture.hid.emit(
            signature: HIDSignature(
                usagePage: 0x07,
                usage: 0x50,
                cookie: 201,
                kind: .button
            ),
            value: 0,
            timestamp: now + 0.050
        )
        fixture.hid.emit(
            signature: HIDSignature(
                usagePage: 0x07,
                usage: 0x52,
                cookie: 202,
                kind: .button
            ),
            value: 0,
            timestamp: now + 0.052
        )
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, originalID)
    }

    func testHIDOnlyModeRecordsInputWithoutStartingBridgeOrExecutingActions() async throws {
        let fixture = makeFixture(hidOnlyMode: true)
        let model = fixture.model
        model.setBinding(.codexAction("composer.togglePlanMode"), for: .key01)

        model.start()
        await settle()
        XCTAssertEqual(fixture.hid.startCalls, 1)
        XCTAssertEqual(fixture.bridge.startCalls, 0)
        XCTAssertFalse(model.chatGPTNeedsRestart)
        XCTAssertEqual(
            fixture.hid.lightingSummaries.last,
            NostromoLightingSummary(
                red: false,
                green: false,
                blue: false,
                backlightBrightness: 41
            )
        )

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        fixture.hid.emit(
            signature: HIDSignature(usagePage: 0x01, usage: 0x38, cookie: 90, kind: .axis),
            value: 1
        )
        await settle()

        XCTAssertTrue(fixture.bridge.actions.isEmpty)
        XCTAssertEqual(model.hidDiagnosticEvents.count, 3)
        XCTAssertEqual(model.hidDiagnosticEvents.map(\.sequence), [1, 2, 3])

        model.restartThroughNostromo()
        model.launchChatGPT()
        await settle()
        XCTAssertEqual(fixture.launcher.launchCalls, 0)
        XCTAssertEqual(fixture.launcher.terminateCalls, 0)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: model.hidDiagnosticsData()) as? [String: Any]
        )
        XCTAssertEqual(object["hidOnlyMode"] as? Bool, true)
        XCTAssertEqual((object["vendorID"] as? NSNumber)?.intValue, 0x1532)
        XCTAssertEqual((object["productID"] as? NSNumber)?.intValue, 0x0111)
        XCTAssertEqual((object["formatVersion"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual(object["architecture"] as? String, "arm64")
        XCTAssertNotNil(object["operatingSystem"] as? String)
        XCTAssertNotNil(object["deviceState"] as? String)
        XCTAssertNotNil(object["inputProtection"] as? String)
        let identity = try XCTUnwrap(
            object["applicationIdentity"] as? [String: Any]
        )
        XCTAssertFalse(
            (identity["runningBundlePath"] as? String ?? "").isEmpty
        )
        let pipeline = try XCTUnwrap(
            object["pipeline"] as? [String: Any]
        )
        XCTAssertEqual(
            (pipeline["rawEventCount"] as? NSNumber)?.intValue,
            3
        )
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 3)
        XCTAssertNotNil(events[0]["receivedAtUptime"] as? NSNumber)
        XCTAssertNotNil(events[0]["callbackLatencyMilliseconds"] as? NSNumber)
        XCTAssertNotNil(model.hidCallbackLatencyP95Milliseconds)

        model.clearHIDDiagnostics()
        XCTAssertTrue(model.hidDiagnosticEvents.isEmpty)
    }

    func testRepeatedDPadReportsRescheduleMomentaryRelease() async {
        let clock = ManualRuntimeClock()
        let fixture = makeFixture(clock: clock)
        let model = fixture.model
        let originalID = model.configuration.activeProfileID
        let target = ControllerProfile(name: "Held D-pad", bindings: [:])
        model.configuration.profiles.append(target)
        model.setBinding(
            .profileSwitch(profileID: target.id, behavior: .momentary),
            for: .dpadUp
        )

        let startedAt = clock.now
        let yAxis = HIDSignature(usagePage: 0x01, usage: 0x31, cookie: 103, kind: .axis)
        fixture.hid.emit(signature: yAxis, value: -1, timestamp: startedAt)
        await advance(clock, by: 0.03)
        XCTAssertEqual(model.configuration.activeProfileID, target.id)

        // Nostromo's relative axis repeats while the stick remains held.
        await advance(clock, by: 0.06)
        fixture.hid.emit(signature: yAxis, value: -1, timestamp: startedAt + 0.09)
        await advance(clock, by: 0.06)
        XCTAssertEqual(model.configuration.activeProfileID, target.id)

        await advance(clock, by: 0.1)
        XCTAssertEqual(model.configuration.activeProfileID, originalID)
    }

    func testDuplicateButtonEdgesDoNotRepeatActionsOrBreakMomentaryReturn() async {
        let fixture = makeFixture()
        let model = fixture.model
        let plugin = PluginPrompt(uri: "plugin://calendar", displayName: "Calendar")
        model.setBinding(.pluginPrompt(plugin), for: .key01)

        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(
            fixture.bridge.actions.filter { $0.name == "prepare-plugin-prompt" }.count,
            1
        )
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        fixture.hid.emitButton(.key01, pressed: false, configuration: model.configuration)
        await settle()

        let originalID = model.configuration.activeProfileID
        let target = ControllerProfile(name: "Momentary repeat", bindings: [:])
        model.configuration.profiles.append(target)
        model.setBinding(
            .profileSwitch(profileID: target.id, behavior: .momentary),
            for: .key02
        )
        fixture.hid.emitButton(.key02, pressed: true, configuration: model.configuration)
        fixture.hid.emitButton(.key02, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, target.id)
        fixture.hid.emitButton(.key02, pressed: false, configuration: model.configuration)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, originalID)
    }

    func testDuplicateWheelPressCannotUndoRotationClickSuppression() async throws {
        let fixture = makeFixture()
        let model = fixture.model
        let wheelPress = try XCTUnwrap(model.configuration.calibration.signatures[.wheelPress])
        let wheelAxis = HIDSignature(usagePage: 0x01, usage: 0x38, cookie: 101, kind: .axis)

        fixture.hid.emit(signature: wheelPress, value: 1, timestamp: 1)
        await settle()
        fixture.hid.emit(signature: wheelAxis, value: 1, timestamp: 1.1)
        await settle()
        fixture.hid.emit(signature: wheelPress, value: 1, timestamp: 1.2)
        await settle()
        fixture.hid.emit(signature: wheelPress, value: 0, timestamp: 1.3)
        await settle()

        fixture.hid.emit(signature: wheelAxis, value: 1, timestamp: 1.4)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "scroll-task")
    }

    func testDisconnectSuppressesCarriedDPadAndAcceptsFreshPostGateGesture() async {
        let fixture = makeFixture()
        let model = fixture.model
        let originalID = model.configuration.activeProfileID
        let target = ControllerProfile(name: "Reconnect", bindings: [:])
        model.configuration.profiles.append(target)
        model.setBinding(
            .profileSwitch(profileID: target.id, behavior: .momentary),
            for: .dpadUp
        )
        let yAxis = HIDSignature(usagePage: 0x01, usage: 0x31, cookie: 103, kind: .axis)
        let startedAt = ProcessInfo.processInfo.systemUptime

        fixture.hid.emit(signature: yAxis, value: -1, timestamp: startedAt)
        let activatedBeforeDisconnect = await waitUntil {
            model.configuration.activeProfileID == target.id
        }
        XCTAssertTrue(activatedBeforeDisconnect)

        fixture.hid.emit(state: .disconnected)
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, originalID)
        fixture.hid.emit(
            state: .connected(interfaceCount: 2, captureMode: .shared)
        )
        await settle()

        fixture.hid.emit(
            signature: yAxis,
            value: -1,
            timestamp: ProcessInfo.processInfo.systemUptime,
            eligibleForAction: false
        )
        await settle()
        XCTAssertEqual(model.configuration.activeProfileID, originalID)

        fixture.hid.emit(
            signature: yAxis,
            value: -1,
            timestamp: ProcessInfo.processInfo.systemUptime,
            eligibleForAction: true
        )
        let activatedAfterReconnect = await waitUntil {
            model.configuration.activeProfileID == target.id
        }
        XCTAssertTrue(activatedAfterReconnect)
    }

    func testPermutedDPadCalibrationReleasesMappedControlOnTransition() async {
        let clock = ManualRuntimeClock()
        let fixture = makeFixture(clock: clock)
        let model = fixture.model
        let originalID = model.configuration.activeProfileID
        let first = ControllerProfile(name: "Mapped up", bindings: [:])
        let second = ControllerProfile(name: "Mapped right", bindings: [:])
        model.configuration.profiles.append(contentsOf: [first, second])
        model.configuration.calibration.dpadDirections[.up] = .dpadRight
        model.configuration.calibration.dpadDirections[.right] = .dpadUp
        model.setBinding(
            .profileSwitch(profileID: first.id, behavior: .momentary),
            for: .dpadRight
        )
        model.setBinding(
            .profileSwitch(profileID: second.id, behavior: .momentary),
            for: .dpadUp
        )
        if let firstIndex = model.configuration.profiles.firstIndex(where: { $0.id == first.id }) {
            model.configuration.profiles[firstIndex].bindings[.dpadUp] =
                .profileSwitch(profileID: second.id, behavior: .momentary)
        }

        let startedAt = clock.now
        fixture.hid.emit(
            signature: HIDSignature(usagePage: 0x01, usage: 0x31, cookie: 103, kind: .axis),
            value: -1,
            timestamp: startedAt
        )
        await advance(clock, by: 0.03)
        XCTAssertEqual(model.configuration.activeProfileID, first.id)

        fixture.hid.emit(
            signature: HIDSignature(usagePage: 0x01, usage: 0x30, cookie: 102, kind: .axis),
            value: 1,
            timestamp: startedAt + 0.03
        )
        await advance(clock, by: 0.03)
        XCTAssertEqual(model.configuration.activeProfileID, first.id)

        await advance(clock, by: 0.14)
        XCTAssertEqual(model.configuration.activeProfileID, originalID)

        fixture.hid.emit(
            signature: HIDSignature(usagePage: 0x01, usage: 0x30, cookie: 102, kind: .axis),
            value: 1,
            timestamp: clock.now
        )
        await advance(clock, by: 0.03)
        XCTAssertEqual(model.configuration.activeProfileID, second.id)
    }

    func testCalibrationReleasesActiveInputAndDisconnectCancelsDraft() async {
        let fixture = makeFixture()
        let model = fixture.model
        model.setBinding(.codexAction("pushToTalk"), for: .key01)
        fixture.hid.emitButton(.key01, pressed: true, configuration: model.configuration)
        await settle()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "push-to-talk-start")

        model.beginCalibration()
        XCTAssertEqual(fixture.bridge.actions.last?.name, "push-to-talk-stop")

        let first = HIDSignature(usagePage: 7, usage: 120, cookie: 60, kind: .button)
        let second = HIDSignature(usagePage: 7, usage: 121, cookie: 61, kind: .button)
        fixture.hid.emit(signature: first, value: 1)
        await settle()
        XCTAssertEqual(model.calibrationTarget, .key02)
        fixture.hid.emit(state: .disconnected)
        await settle()
        fixture.hid.emit(signature: second, value: 1)
        await settle()
        XCTAssertNil(model.calibrationTarget)
        XCTAssertNotEqual(
            model.configuration.calibration.signatures[.key02]?.portableKey,
            second.portableKey
        )
    }

    func testCancelCalibrationCancelsPendingDPadResolution() async {
        let clock = ManualRuntimeClock()
        let fixture = makeFixture(clock: clock)
        let model = fixture.model
        let target = ControllerProfile(name: "Must not activate", bindings: [:])
        model.configuration.profiles.append(target)
        model.setBinding(
            .profileSwitch(profileID: target.id, behavior: .momentary),
            for: .dpadUp
        )
        model.beginCalibration()
        let actionCount = fixture.bridge.actions.count

        fixture.hid.emit(
            signature: HIDSignature(usagePage: 0x01, usage: 0x31, cookie: 103, kind: .axis),
            value: -1,
            timestamp: clock.now
        )
        await advance(clock, by: 0.005)
        model.cancelCalibration()
        await advance(clock, by: 0.03)

        XCTAssertNotEqual(model.configuration.activeProfileID, target.id)
        XCTAssertEqual(fixture.bridge.actions.count, actionCount)
    }

    func testConnectedControllerSuppressesOnlyNostromoKeyboardUsagesAndRestoresOnStop() async {
        let fixture = makeFixture()

        fixture.hid.emit(
            state: .connected(interfaceCount: 2, captureMode: .shared)
        )
        let suppressionApplied = await waitUntil {
            fixture.keyboardSuppressor.suppressedUsages.count == 1
        }
        XCTAssertTrue(suppressionApplied)

        let usages = try? XCTUnwrap(fixture.keyboardSuppressor.suppressedUsages.last)
        let expectedUsages = Set(
            CalibrationMap.nostromoFactory.signatures.values
                .filter { $0.usagePage == 0x07 && $0.kind == .button }
                .map(\.usage)
        ).union([0x4F, 0x50, 0x51, 0x52])
        XCTAssertEqual(usages, expectedUsages)
        XCTAssertEqual(
            fixture.model.inputProtectionStatus,
            .active(serviceCount: 1, usageCount: usages?.count ?? 0)
        )

        fixture.model.setControllerEnabled(false)
        XCTAssertEqual(fixture.keyboardSuppressor.restoreCalls, 1)
        XCTAssertEqual(fixture.model.inputProtectionStatus, .inactive)
    }

    func testExclusiveCaptureDispatchesWithoutApplyingUserKeyMapping() async {
        let fixture = makeFixture()
        fixture.model.setBinding(
            .codexAction("toggleSidebar"),
            for: .key01
        )
        await settle()

        XCTAssertEqual(
            fixture.model.inputProtectionStatus,
            .exclusiveCapture
        )
        XCTAssertTrue(fixture.keyboardSuppressor.suppressedUsages.isEmpty)

        fixture.hid.emitButton(
            .key01,
            pressed: true,
            configuration: fixture.model.configuration
        )
        fixture.hid.emitButton(
            .key01,
            pressed: false,
            configuration: fixture.model.configuration
        )
        await settle()

        XCTAssertEqual(fixture.bridge.actions.last?.name, "run-command")
        XCTAssertEqual(
            fixture.bridge.actions.last?.payload["commandId"] as? String,
            "toggleSidebar"
        )
        XCTAssertEqual(
            fixture.model.hidPipelineDiagnostics.rawEventCount,
            2
        )
        XCTAssertEqual(
            fixture.model.hidPipelineDiagnostics.mappedControlCount,
            2
        )
        XCTAssertEqual(
            fixture.model.hidPipelineDiagnostics.bindingExecutionCount,
            1
        )
        XCTAssertEqual(
            fixture.model.hidPipelineDiagnostics.bridgeDispatchAttemptCount,
            1
        )
        XCTAssertEqual(
            fixture.model.hidPipelineDiagnostics.bridgeDispatchSuccessCount,
            1
        )
    }

    func testFailedSharedCaptureProtectionBlocksAssignments() async {
        let fixture = makeFixture()
        let failure = NostromoKeyboardSuppressionFailure(
            failures: [
                NostromoKeyboardServiceFailure(
                    registryID: 9_004,
                    stage: .verification,
                    setterReturned: true,
                    readBackMatched: false,
                    detail: "test rejection"
                ),
            ],
            recoveryPending: false
        )
        fixture.keyboardSuppressor.forcedStatus = .failed(failure)
        fixture.model.setBinding(
            .codexAction("toggleSidebar"),
            for: .key01
        )
        fixture.hid.emit(
            state: .connected(interfaceCount: 2, captureMode: .shared)
        )
        let failurePublished = await waitUntil {
            fixture.model.inputProtectionStatus == .failed(failure)
        }
        XCTAssertTrue(failurePublished)

        fixture.hid.emitButton(
            .key01,
            pressed: true,
            configuration: fixture.model.configuration
        )
        fixture.hid.emitButton(
            .key01,
            pressed: false,
            configuration: fixture.model.configuration
        )
        await settle()

        XCTAssertTrue(fixture.bridge.actions.isEmpty)
        XCTAssertTrue(
            fixture.model.lastError?.contains(
                "Назначения приостановлены"
            ) == true
        )
        XCTAssertEqual(
            fixture.model.hidPipelineDiagnostics.blockedActionCount,
            1
        )
    }
}
