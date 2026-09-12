import Foundation
@testable import NostromoCodexApp
import NostromoCodexCore
import SwiftUI
import XCTest

@MainActor
final class AppModelPresentationTests: AppModelTestCase {
    func testMappingWorkspaceRendersAllBindingKindsAtMinimumWindowSize() throws {
        let fixture = makeFixture()
        fixture.model.preferences.markSetupCompleted(autoLaunch: false)
        fixture.model.dashboardSection = .mappings
        fixture.model.setBinding(.taskSlot(0), for: .key01)
        fixture.model.setBinding(.codexAction("approval.approve"), for: .key02)
        fixture.model.setBinding(
            .skill(
                SkillReference(
                    name: "release-readiness",
                    displayName: "Очень длинное имя навыка",
                    path: "/tmp/SKILL.md"
                )
            ),
            for: .key03
        )
        fixture.model.setBinding(
            .pluginPrompt(
                PluginPrompt(
                    uri: "plugin://release-readiness",
                    displayName: "Очень длинное имя плагина"
                )
            ),
            for: .key04
        )
        fixture.model.setBinding(
            .shortcut(
                ShortcutBinding(
                    keyCode: 1,
                    command: true,
                    option: true,
                    shift: true
                )
            ),
            for: .key05
        )
        fixture.model.setBinding(
            .profileSwitch(
                profileID: fixture.model.activeProfile.id,
                behavior: .momentary
            ),
            for: .key06
        )
        fixture.model.setBinding(.none, for: .key07)

        let renderer = ImageRenderer(
            content: HStack(spacing: 0) {
                Color(nsColor: .underPageBackgroundColor)
                    .frame(width: 190)
                HStack(alignment: .top, spacing: 16) {
                    DeviceMapView()
                        .environmentObject(fixture.model)
                        .frame(width: 520)
                    AssignmentInspector()
                        .environmentObject(fixture.model)
                        .frame(width: 300, height: 510, alignment: .top)
                }
                .padding(20)
                .frame(width: 910, height: 700, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .frame(width: 1_100, height: 700)
        )
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 1_100, height: 700)
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 1_100)
        XCTAssertEqual(image.height, 700)

        if let path = ProcessInfo.processInfo.environment[
            "NOSTROMO_LAYOUT_SNAPSHOT_PATH"
        ] {
            let representation = NSBitmapImageRep(cgImage: image)
            let data = try XCTUnwrap(
                representation.representation(
                    using: .png,
                    properties: [:]
                )
            )
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testTaskSlotMetadataReplacesGenericLabelAndClearsOnDisconnect() async {
        let fixture = makeFixture()
        let model = fixture.model
        model.setBinding(.taskSlot(3), for: .key01)

        fixture.bridge.onStatus?(.connected)
        fixture.bridge.onCapabilities?(completeTestCapabilities())
        fixture.bridge.onTaskSlots?([
            CodexTaskSlot(
                id: 3,
                title: "Исправить меню дока",
                status: .working,
                selected: true
            ),
        ])
        await settle()

        XCTAssertEqual(model.compactBindingSummary(for: .key01), "Исправить меню дока")
        XCTAssertEqual(
            model.bindingSummary(for: .key01),
            "Задача 4 · Исправить меню дока"
        )
        XCTAssertEqual(model.taskSlot(3)?.status, .working)

        fixture.bridge.onStatus?(.listening)
        await settle()

        XCTAssertTrue(model.taskSlots.isEmpty)
        XCTAssertEqual(model.compactBindingSummary(for: .key01), "Задача 4")
    }
}
