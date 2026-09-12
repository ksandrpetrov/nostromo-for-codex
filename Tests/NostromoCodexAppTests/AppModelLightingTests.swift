import Foundation
@testable import NostromoCodexApp
import NostromoCodexCore
import SwiftUI
import XCTest

@MainActor
final class AppModelLightingTests: AppModelTestCase {
    func testLightingSettingsPersistAndApplyImmediately() throws {
        let fixture = makeFixture()
        let model = fixture.model

        model.setMaximumLightingBrightness(0.5)
        model.setPressFeedbackStrength(0.4)
        model.setPressFeedbackEnabled(false)
        model.setKeypadLightingEnabled(false)

        XCTAssertFalse(model.configuration.lighting.keypadEnabled)
        XCTAssertEqual(model.configuration.lighting.maximumBrightness, 0.5)
        XCTAssertFalse(model.configuration.lighting.pressFeedbackEnabled)
        XCTAssertEqual(model.configuration.lighting.pressFeedbackStrength, 0.4)
        XCTAssertEqual(fixture.hid.lightingSummaries.last?.backlightBrightness, 0)

        let stored = try model.store.load()
        XCTAssertEqual(stored.lighting.maximumBrightness, 0.5)
        XCTAssertFalse(stored.lighting.keypadEnabled)
        XCTAssertFalse(stored.lighting.pressFeedbackEnabled)
        XCTAssertEqual(stored.lighting.pressFeedbackStrength, 0.4)
    }

    func testTaskIndicatorsStayDarkWhileIdle() {
        let fixture = makeFixture()
        let model = fixture.model

        XCTAssertFalse(model.lightingResolution.taskStatusOwnsIndicators)
        XCTAssertFalse(model.lightingResolution.summary.red)
        XCTAssertFalse(model.lightingResolution.summary.green)
        XCTAssertFalse(model.lightingResolution.summary.blue)
    }

    func testTaskIndicatorsFollowReadyRunningAttentionAndCompletionLifecycle() async {
        let fixture = makeFixture()

        fixture.bridge.onStatus?(.connected)
        fixture.bridge.onCapabilities?(completeTestCapabilities())
        await settle()
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.red ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.blue ?? false)

        func publish(_ status: CodexTaskStatus) {
            fixture.bridge.onTaskSlots?([
                CodexTaskSlot(
                    id: 0,
                    title: "Проверить индикаторы",
                    status: status,
                    selected: true
                ),
            ])
        }

        publish(.working)
        await settle()
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.red ?? true)
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.green ?? false)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.blue ?? true)

        publish(.awaitingApproval)
        await settle()
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.red ?? false)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.blue ?? true)

        publish(.awaitingResponse)
        await settle()
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.red ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.blue ?? false)

        publish(.working)
        await settle()
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.red ?? true)
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.green ?? false)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.blue ?? true)

        publish(.unread)
        await settle()
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.red ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.blue ?? false)

        publish(.idle)
        await settle()
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.red ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.blue ?? false)

        publish(.error)
        await settle()
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.red ?? false)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.blue ?? true)

        fixture.bridge.onStatus?(.listening)
        await settle()
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.red ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.blue ?? true)
    }

    func testAwaitingResponseKeepsReadyIndicatorInsteadOfRedAttention() async {
        let fixture = makeFixture()
        fixture.bridge.onStatus?(.connected)
        fixture.bridge.onCapabilities?(completeTestCapabilities())
        fixture.bridge.onTaskSlots?([
            CodexTaskSlot(
                id: 0,
                title: "Обычное обновление задачи",
                status: .awaitingResponse,
                selected: true
            ),
        ])
        await settle()

        XCTAssertFalse(fixture.hid.lightingSummaries.last?.red ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.blue ?? false)
    }

    func testTaskCompletionFlashesKeypadOnceOnTransitionToUnread() async {
        let fixture = makeFixture()

        func publish(_ status: CodexTaskStatus) {
            fixture.bridge.onTaskSlots?([
                CodexTaskSlot(
                    id: 0,
                    title: "Завершить задачу",
                    status: status,
                    selected: true
                ),
            ])
        }

        publish(.working)
        await settle()
        XCTAssertTrue(fixture.hid.backlightPulseStrengths.isEmpty)

        publish(.unread)
        await settle()
        XCTAssertEqual(fixture.hid.backlightPulseStrengths, [1])

        publish(.unread)
        await settle()
        XCTAssertEqual(fixture.hid.backlightPulseStrengths, [1])
    }

    func testInitialUnreadSnapshotDoesNotFlashStaleTaskCompletion() async {
        let fixture = makeFixture()

        fixture.bridge.onTaskSlots?([
            CodexTaskSlot(
                id: 0,
                title: "Уже завершено",
                status: .unread,
                selected: true
            ),
        ])
        await settle()

        XCTAssertTrue(fixture.hid.backlightPulseStrengths.isEmpty)
    }

    func testTaskCompletionFlashHonorsDisabledKeypadLighting() async {
        let fixture = makeFixture()
        fixture.model.setKeypadLightingEnabled(false)

        fixture.bridge.onTaskSlots?([
            CodexTaskSlot(
                id: 0,
                title: "Без вспышки",
                status: .working,
                selected: true
            ),
        ])
        await settle()
        fixture.bridge.onTaskSlots?([
            CodexTaskSlot(
                id: 0,
                title: "Без вспышки",
                status: .unread,
                selected: true
            ),
        ])
        await settle()

        XCTAssertTrue(fixture.hid.backlightPulseStrengths.isEmpty)
    }

    func testTaskIndicatorPriorityPrefersAttentionOverConcurrentWork() async {
        let fixture = makeFixture()
        fixture.bridge.onStatus?(.connected)
        fixture.bridge.onCapabilities?(completeTestCapabilities())
        fixture.bridge.onTaskSlots?([
            CodexTaskSlot(
                id: 0,
                title: "Выполняется",
                status: .working,
                selected: true
            ),
            CodexTaskSlot(
                id: 1,
                title: "Нужно подтверждение",
                status: .awaitingApproval,
                selected: false
            ),
        ])
        await settle()

        XCTAssertTrue(fixture.hid.lightingSummaries.last?.red ?? false)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.green ?? true)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.blue ?? true)
    }

    func testCodexMicroInactivityBlackoutCannotClearWorkingTaskIndicator() async throws {
        let fixture = makeFixture()
        fixture.bridge.onStatus?(.connected)
        fixture.bridge.onCapabilities?(completeTestCapabilities())
        fixture.bridge.onTaskSlots?([
            CodexTaskSlot(
                id: 0,
                title: "Длительная задача",
                status: .working,
                selected: true
            ),
        ])
        await settle()
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.green ?? false)

        let reports = try Project2077.encodeJSON([
            "method": "v.oai.thstatus",
            "params": (0 ..< 6).map { id in
                [
                    "id": id,
                    "c": 0,
                    "b": 0,
                    "e": 0,
                    "s": 0,
                ]
            },
        ])
        for report in reports {
            fixture.bridge.onHostReport?(report)
        }
        await settle()

        XCTAssertFalse(fixture.hid.lightingSummaries.last?.red ?? true)
        XCTAssertTrue(fixture.hid.lightingSummaries.last?.green ?? false)
        XCTAssertFalse(fixture.hid.lightingSummaries.last?.blue ?? true)
        XCTAssertEqual(fixture.model.taskSlot(0)?.status, .working)
    }

    func testPressFeedbackHonorsEnabledStateAndConfiguredStrength() {
        let fixture = makeFixture()
        let model = fixture.model
        model.setPressFeedbackStrength(0.35)

        model.testLightingFlash()
        XCTAssertEqual(fixture.hid.backlightPulseStrengths.last, 0.35)

        let callCount = fixture.hid.backlightPulseStrengths.count
        model.setPressFeedbackEnabled(false)
        model.testLightingFlash()
        XCTAssertEqual(fixture.hid.backlightPulseStrengths.count, callCount)
    }
}
