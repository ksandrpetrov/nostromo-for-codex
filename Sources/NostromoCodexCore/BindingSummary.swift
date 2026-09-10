import Foundation

public enum BindingSummary {
    public static func text(for action: BindingAction) -> String {
        switch action {
        case let .taskSlot(index):
            "Задача \(index + 1)"
        case let .codexAction(id):
            CodexActionCatalog.descriptor(for: id)?.title ?? id
        case let .skill(skill):
            "$\(skill.displayName)"
        case let .pluginPrompt(plugin):
            plugin.isConfigured ? "@\(plugin.displayName)" : "Настроить плагин"
        case let .shortcut(shortcut):
            shortcutText(shortcut)
        case let .profileSwitch(profileID, _):
            profileID == nil ? "Следующий профиль" : "Профиль"
        case .none:
            "Не назначено"
        }
    }

    /// A deliberately short label for the 72-point physical keycaps.
    ///
    /// The full, localized summary remains available to inspectors,
    /// accessibility and pointer help. Keeping this separate prevents the
    /// spatial map from silently truncating the most important distinction
    /// between adjacent controls.
    public static func compactText(for action: BindingAction) -> String {
        switch action {
        case let .taskSlot(index):
            "Задача \(index + 1)"
        case let .codexAction(id):
            compactActionTitles[id] ?? "Команда"
        case let .skill(skill):
            compactReference(prefix: "$", value: skill.displayName, fallback: "Навык")
        case let .pluginPrompt(plugin):
            plugin.isConfigured
                ? compactReference(prefix: "@", value: plugin.displayName, fallback: "Плагин")
                : "Плагин"
        case let .shortcut(shortcut):
            shortcut.isConfigured ? compactShortcutText(shortcut) : "Хоткей"
        case let .profileSwitch(profileID, _):
            profileID == nil ? "След.пр." : "Профиль"
        case .none:
            "—"
        }
    }

    private static let compactActionTitles: [String: String] = [
        "composer.togglePlanMode": "План",
        "composer.toggleFastMode": "Fast",
        "composer.increaseReasoningEffort": "Разум +",
        "composer.decreaseReasoningEffort": "Разум −",
        "composer.cycleReasoningEffort": "Глубина",
        "composer.openModelPicker": "Модель",
        "composer.toggleChatWorkMode": "Чат/Work",
        "composer.openPermissions": "Доступ",
        "composer.toggleWorktreeMode": "Worktree",
        "approval.approve": "Принять",
        "approval.decline": "Отказ",
        "composer.stop": "Стоп",
        "composer.submit": "Отправ.",
        "pushToTalk": "Диктовка",
        "newTask": "Новая",
        "forkThread": "Ветка",
        "openSideChat": "Side",
        "previousThread": "Пред.",
        "nextThread": "След.",
        "toggleSidebar": "Sidebar",
        "toggleTerminal": "Терминал",
        "toggleReviewTab": "Review",
        "openBrowserTab": "Браузер",
        "composer.addFiles": "Файлы",
        "composer.addPhotos": "Фото",
        "composer.openSkillPicker": "Навыки $",
        "openFolder": "Папка",
        "composer.clearProject": "Без пр.",
        "environmentAction1": "Действие",
        "git.commit": "Коммит",
        "git.createPullRequest": "PR",
        "openSkills": "Навыки",
        "mcpSettings": "MCP",
        "manageTasks": "Планы",
        "settings": "Настр.",
        "focusChatGPT": "ChatGPT",
    ]

    private static func compactReference(
        prefix: String,
        value: String,
        fallback: String
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return prefix + String(trimmed.prefix(5))
    }

    private static func shortcutText(_ shortcut: ShortcutBinding) -> String {
        guard shortcut.isConfigured else { return "Записать сочетание" }
        var parts: [String] = []
        if shortcut.control { parts.append("⌃") }
        if shortcut.option { parts.append("⌥") }
        if shortcut.shift { parts.append("⇧") }
        if shortcut.command { parts.append("⌘") }
        parts.append(keyName(for: shortcut.keyCode))
        return parts.joined()
    }

    private static func compactShortcutText(_ shortcut: ShortcutBinding) -> String {
        String(shortcutText(shortcut).prefix(8))
    }

    private static func keyName(for code: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 25: "9", 26: "7", 28: "8", 29: "0", 31: "O", 32: "U",
            34: "I", 35: "P", 36: "Ввод", 37: "L", 38: "J", 40: "K",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab",
            49: "Пробел", 51: "Удалить", 53: "Esc", 123: "←", 124: "→",
            125: "↓", 126: "↑",
        ]
        return names[code] ?? "Клавиша \(code)"
    }
}
