import AppKit
import Combine
import SwiftUI

@MainActor
final class NostromoStatusItemController: NSObject {
    private static let statusItemAutosaveName =
        "dev.aleksandr.nostromo-codex.status"

    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var dashboardWindowController: NSWindowController?
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        super.init()

        Self.configureVisibility(of: statusItem)
        if let button = statusItem.button {
            button.toolTip = "Nostromo Codex"
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 340, height: 430)
        popover.contentViewController = NSHostingController(
            rootView: MenuContentView { [weak self] section in
                self?.openDashboard(section)
            }
            .environmentObject(model)
        )

        model.$bridgeStatus
            .sink { [weak self] status in
                self?.updateIcon(for: status)
            }
            .store(in: &cancellables)
    }

    private static func configureVisibility(of statusItem: NSStatusItem) {
        // macOS persists visibility for status items. Earlier versions used an
        // anonymous item whose saved `VisibleCC` value can keep a newly created
        // replacement hidden even while the process is healthy.
        statusItem.autosaveName = statusItemAutosaveName
        statusItem.isVisible = true
    }

    func openDashboard(_ section: DashboardSection? = nil) {
        if let section {
            model.dashboardSection = section
        }
        popover.performClose(nil)

        if let dashboard = NSApplication.shared.windows.first(where: {
            $0.canBecomeMain
                && ($0.title == "Nostromo Codex"
                    || $0.identifier?.rawValue.contains("dashboard") == true)
        }) {
            dashboard.makeKeyAndOrderFront(nil)
        } else {
            let controller = dashboardWindowController ?? makeDashboardWindow()
            dashboardWindowController = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc
    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
        }
    }

    private func updateIcon(for status: BridgeStatus) {
        let symbol = switch status {
        case .connected: "command.square.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped, .listening: "command.square"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Nostromo Codex")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func makeDashboardWindow() -> NSWindowController {
        let content = DashboardView()
            .environmentObject(model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Nostromo Codex"
        window.identifier = NSUserInterfaceItemIdentifier("dashboard-fallback")
        window.contentMinSize = NSSize(width: 1100, height: 700)
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.isReleasedWhenClosed = false
        return NSWindowController(window: window)
    }
}
