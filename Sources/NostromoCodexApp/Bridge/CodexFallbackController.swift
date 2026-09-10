import AppKit
import ApplicationServices
import NostromoCodexCore

@MainActor
protocol CodexFallbackControlling {
    var hasAccess: Bool { get }
    func perform(_ action: CodexFallbackAction) async throws
}

enum CodexFallbackError: LocalizedError {
    case permission, unavailable, focus, command, ambiguous

    var errorDescription: String? {
        switch self {
        case .permission: "Для базовых команд разрешите Nostromo Codex универсальный доступ в настройках macOS."
        case .unavailable: "Сначала запустите Codex обычным способом."
        case .focus: "Не удалось активировать окно Codex. Команда не выполнена."
        case .command: "Команда недоступна в системном меню Codex. Нажатие не отправлено."
        case .ambiguous: "Команда в меню Codex неоднозначна. Нажатие не отправлено."
        }
    }
}

/// Public macOS menu actions keep custom keyboard bindings and layouts intact.
/// No private IPC, guessed coordinates or global keyboard events are used.
@MainActor
struct CodexFallbackController: CodexFallbackControlling {
    var hasAccess: Bool { AXIsProcessTrusted() }

    static func matches(_ title: String, action: CodexFallbackAction) -> Bool {
        let normalized = title.replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let titles: [String]
        switch action {
        case .newTask: titles = ["New Chat", "New Task", "Новый чат", "Новая задача"]
        case .previousThread: titles = ["Previous Chat", "Previous Thread", "Предыдущий чат", "Предыдущая задача"]
        case .nextThread: titles = ["Next Chat", "Next Thread", "Следующий чат", "Следующая задача"]
        case .toggleSidebar: titles = ["Toggle Sidebar", "Show Sidebar", "Hide Sidebar", "Боковая панель", "Показать боковую панель", "Скрыть боковую панель", "Переключить боковую панель"]
        case .settings: titles = ["Settings", "Настройки"]
        }
        return titles.contains(normalized)
    }

    func perform(_ action: CodexFallbackAction) async throws {
        guard hasAccess else { throw CodexFallbackError.permission }
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: ChatGPTLauncher.bundleIdentifier)
            .filter { $0.bundleURL?.resolvingSymlinksInPath() == ChatGPTLauncher.bundleURL.resolvingSymlinksInPath() }
        guard candidates.count == 1, let application = candidates.first else { throw CodexFallbackError.unavailable }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        application.unhide()
        if let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement], let window = windows.first {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        guard application.activate(options: [.activateAllWindows]) else { throw CodexFallbackError.focus }
        for _ in 0..<10 {
            if application.isActive { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        guard application.isActive, !application.isTerminated else { throw CodexFallbackError.focus }
        guard let menuValue = attribute(app, kAXMenuBarAttribute),
              CFGetTypeID(menuValue) == AXUIElementGetTypeID()
        else { throw CodexFallbackError.command }
        let menu = unsafeDowncast(menuValue, to: AXUIElement.self)
        var remaining = 400
        var matches: [AXUIElement] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        collect(menu, action: action, depth: 0, deadline: deadline, remaining: &remaining, matches: &matches)
        guard remaining > 0, matches.count == 1 else {
            throw matches.isEmpty ? CodexFallbackError.command : CodexFallbackError.ambiguous
        }
        try Task.checkCancellation()
        guard application.isActive, !application.isTerminated else { throw CodexFallbackError.focus }
        guard AXUIElementPerformAction(matches[0], kAXPressAction as CFString) == .success else {
            throw CodexFallbackError.command
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func collect(_ element: AXUIElement, action: CodexFallbackAction, depth: Int, deadline: TimeInterval,
                         remaining: inout Int, matches: inout [AXUIElement]) {
        guard remaining > 0 else { return }
        guard depth < 8, ProcessInfo.processInfo.systemUptime < deadline else {
            remaining = 0
            return
        }
        remaining -= 1
        if attribute(element, kAXRoleAttribute) as? String == kAXMenuItemRole,
           let title = attribute(element, kAXTitleAttribute) as? String,
           Self.matches(title, action: action),
           attribute(element, kAXEnabledAttribute) as? Bool == true {
            matches.append(element)
        }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            collect(child, action: action, depth: depth + 1, deadline: deadline, remaining: &remaining, matches: &matches)
        }
    }
}
