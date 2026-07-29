import AppKit
import SwiftUI

@MainActor
final class RuntimeHUDWindowController: RuntimeHUDPresenting {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func present(_ feedback: RuntimeFeedback) {
        dismissTask?.cancel()

        let content = RuntimeHUDView(feedback: feedback)
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 286, height: 64)

        let panel = panel ?? makePanel()
        panel.contentView = hostingView
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        guard !feedback.persistent else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_450))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 286, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.setAccessibilityLabel("Статус Nostromo Codex")
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        let x = visibleFrame.midX - panel.frame.width / 2
        let y = visibleFrame.maxY - panel.frame.height - 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct RuntimeHUDView: View {
    let feedback: RuntimeFeedback

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: NostromoSpace.sm) {
            Image(systemName: feedback.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: NostromoRadius.small))

            Text(feedback.message)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, NostromoSpace.sm)
        .frame(width: 286, height: 64)
        .background(
            NostromoTheme.popover.opacity(0.97),
            in: RoundedRectangle(cornerRadius: NostromoRadius.large, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: NostromoRadius.large, style: .continuous)
                .strokeBorder(NostromoTheme.border)
        }
        .shadow(color: .black.opacity(0.20), radius: 20, y: 10)
        .transition(reduceMotion ? .opacity : .scale(scale: 0.97).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(feedback.message)
    }

    private var tint: Color {
        switch feedback.kind {
        case .action: NostromoTheme.accent
        case .mode: NostromoTheme.signal
        case .voice: NostromoTheme.success
        case .error: NostromoTheme.danger
        }
    }
}
