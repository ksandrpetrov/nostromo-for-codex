import AppKit
import SwiftUI

@MainActor
final class NostromoApplicationDelegate: NSObject, NSApplicationDelegate {
    static var terminationHandler: (() -> Void)?
    static var didBecomeActiveHandler: (() -> Void)?
    static var statusItemController: NostromoStatusItemController?
    private static var didFinishLaunchingHandler: (() -> Void)?
    private static var hasFinishedLaunching = false
    private static var dashboardOpenHandler: ((DashboardSection?) -> Void)?
    private static var dashboardOpenPending = false
    private static var pendingDashboardSection: DashboardSection?

    static func installDidFinishLaunchingHandler(
        _ handler: @escaping () -> Void
    ) {
        didFinishLaunchingHandler = handler
        if hasFinishedLaunching {
            handler()
        }
    }

    static func requestDashboardOpen(_ section: DashboardSection? = nil) {
        guard let dashboardOpenHandler else {
            dashboardOpenPending = true
            if let section {
                pendingDashboardSection = section
            }
            return
        }
        dashboardOpenHandler(section)
    }

    static func installDashboardOpenHandler(
        _ handler: @escaping (DashboardSection?) -> Void
    ) {
        dashboardOpenHandler = handler
        guard dashboardOpenPending else { return }

        let section = pendingDashboardSection
        dashboardOpenPending = false
        pendingDashboardSection = nil
        handler(section)
    }

    static func resetDashboardOpeningForTesting() {
        dashboardOpenHandler = nil
        dashboardOpenPending = false
        pendingDashboardSection = nil
    }

    static func resetLaunchHandlingForTesting() {
        didFinishLaunchingHandler = nil
        hasFinishedLaunching = false
    }

    func applicationWillTerminate(_: Notification) {
        Self.terminationHandler?()
    }

    func applicationDidFinishLaunching(_: Notification) {
        Self.hasFinishedLaunching = true
        Self.didFinishLaunchingHandler?()
    }

    func applicationDidBecomeActive(_: Notification) {
        Self.didBecomeActiveHandler?()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ application: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        guard !hasVisibleWindows else {
            application.activate(ignoringOtherApps: true)
            return false
        }

        if let dashboard = application.windows.first(where: {
            $0.canBecomeMain
                && ($0.title == "Nostromo Codex"
                    || $0.identifier?.rawValue.contains("dashboard") == true)
        }) {
            dashboard.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: true)
        } else {
            Self.requestDashboardOpen()
        }
        // The dashboard has been restored explicitly. Returning true would
        // also ask SwiftUI to create its default Window scene, producing a
        // duplicate dashboard on a second `open` of the running app.
        return false
    }
}

@main
struct NostromoCodexApp: App {
    @NSApplicationDelegateAdaptor(NostromoApplicationDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        let model = AppModel(preferences: AppPreferences())
        _model = StateObject(wrappedValue: model)
        NostromoApplicationDelegate.terminationHandler = { [weak model] in
            model?.shutdown()
        }
        NostromoApplicationDelegate.didBecomeActiveHandler = { [weak model] in
            model?.refreshInputMonitoringAfterSettings()
        }
        NostromoApplicationDelegate.installDidFinishLaunchingHandler { [weak model] in
            guard let model else { return }
            model.synchronizeApplicationPresentation()
            let controller = NostromoStatusItemController(model: model)
            NostromoApplicationDelegate.statusItemController = controller
            NostromoApplicationDelegate.installDashboardOpenHandler { [weak controller] section in
                controller?.openDashboard(section)
            }
        }
    }

    var body: some Scene {
        Window("Nostromo Codex", id: "dashboard") {
            DashboardView()
                .environmentObject(model)
        }
        .defaultLaunchBehavior(.presented)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Настройки Nostromo Codex…") {
                    NostromoApplicationDelegate.requestDashboardOpen(.connection)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

    }
}
