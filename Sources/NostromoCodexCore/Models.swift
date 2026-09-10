import Foundation

public enum ControlID: String, Codable, CaseIterable, Identifiable, Sendable {
    case key01, key02, key03, key04, key05
    case key06, key07, key08, key09, key10
    case key11, key12, key13, key14, key15, key16
    case dpadUp, dpadUpRight, dpadRight, dpadDownRight
    case dpadDown, dpadDownLeft, dpadLeft, dpadUpLeft
    case wheelPress

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .key01: "01"
        case .key02: "02"
        case .key03: "03"
        case .key04: "04"
        case .key05: "05"
        case .key06: "06"
        case .key07: "07"
        case .key08: "08"
        case .key09: "09"
        case .key10: "10"
        case .key11: "11"
        case .key12: "12"
        case .key13: "13"
        case .key14: "14"
        case .key15: "15"
        case .key16: "16"
        case .dpadUp: "↑"
        case .dpadUpRight: "↗"
        case .dpadRight: "→"
        case .dpadDownRight: "↘"
        case .dpadDown: "↓"
        case .dpadDownLeft: "↙"
        case .dpadLeft: "←"
        case .dpadUpLeft: "↖"
        case .wheelPress: "Колесо"
        }
    }

    public static let keypad: [ControlID] = [
        .key01, .key02, .key03, .key04, .key05,
        .key06, .key07, .key08, .key09, .key10,
        .key11, .key12, .key13, .key14, .key15, .key16,
    ]

    public static let dpad: [ControlID] = [
        .dpadUp, .dpadUpRight, .dpadRight, .dpadDownRight,
        .dpadDown, .dpadDownLeft, .dpadLeft, .dpadUpLeft,
    ]
}

public enum DPadDirection: String, Codable, CaseIterable, Sendable {
    case up, upRight, right, downRight, down, downLeft, left, upLeft

    public var controlID: ControlID {
        switch self {
        case .up: .dpadUp
        case .upRight: .dpadUpRight
        case .right: .dpadRight
        case .downRight: .dpadDownRight
        case .down: .dpadDown
        case .downLeft: .dpadDownLeft
        case .left: .dpadLeft
        case .upLeft: .dpadUpLeft
        }
    }
}

public struct SkillReference: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var displayName: String
    public var path: String
    public var enabled: Bool

    public init(name: String, displayName: String, path: String, enabled: Bool = true) {
        self.name = name
        self.displayName = displayName
        self.path = path
        self.enabled = enabled
    }

    public var id: String { "\(name)|\(path)" }
}

public struct PluginPrompt: Codable, Hashable, Sendable {
    public var uri: String
    public var displayName: String
    public var template: String

    public init(uri: String, displayName: String, template: String = "") {
        self.uri = uri
        self.displayName = displayName
        self.template = template
    }

    public var composerText: String {
        let mention = "[@\(displayName)](\(uri))"
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(mention) " : "\(mention) \(trimmed)"
    }

    public var isConfigured: Bool {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURI = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty
            && trimmedURI.hasPrefix("plugin://")
            && trimmedURI.count > "plugin://".count
    }
}

public struct ShortcutBinding: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool
    public var configured: Bool?

    public init(
        keyCode: UInt16 = 0,
        command: Bool = false,
        option: Bool = false,
        control: Bool = false,
        shift: Bool = false,
        configured: Bool? = nil
    ) {
        self.keyCode = keyCode
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
        self.configured = configured
    }

    public var isConfigured: Bool {
        configured ?? true
    }
}

public enum ProfileSwitchBehavior: String, Codable, CaseIterable, Sendable {
    case toggle
    case momentary
}

public enum BindingAction: Codable, Hashable, Sendable {
    case taskSlot(Int)
    case codexAction(String)
    case skill(SkillReference)
    case pluginPrompt(PluginPrompt)
    case shortcut(ShortcutBinding)
    case profileSwitch(profileID: UUID?, behavior: ProfileSwitchBehavior)
    case none

    public var kind: BindingKind {
        switch self {
        case .taskSlot: .taskSlot
        case .codexAction: .codexAction
        case .skill: .skill
        case .pluginPrompt: .pluginPrompt
        case .shortcut: .shortcut
        case .profileSwitch: .profileSwitch
        case .none: .none
        }
    }
}

public enum BindingKind: String, CaseIterable, Identifiable, Sendable {
    case taskSlot
    case codexAction
    case skill
    case pluginPrompt
    case shortcut
    case profileSwitch
    case none

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .taskSlot: "Задача"
        case .codexAction: "Команда Codex"
        case .skill: "Навык"
        case .pluginPrompt: "Запрос к плагину"
        case .shortcut: "Сочетание клавиш macOS"
        case .profileSwitch: "Смена профиля"
        case .none: "Нет"
        }
    }
}

public struct LightingSettings: Codable, Hashable, Sendable {
    public var keypadEnabled: Bool
    public var maximumBrightness: Double
    public var pressFeedbackEnabled: Bool
    public var pressFeedbackStrength: Double

    public init(
        keypadEnabled: Bool = true,
        maximumBrightness: Double = 1,
        pressFeedbackEnabled: Bool = true,
        pressFeedbackStrength: Double = 1
    ) {
        self.keypadEnabled = keypadEnabled
        self.maximumBrightness = Self.normalized(maximumBrightness, fallback: 1)
        self.pressFeedbackEnabled = pressFeedbackEnabled
        self.pressFeedbackStrength = Self.normalized(pressFeedbackStrength, fallback: 1)
    }

    public static let defaults = LightingSettings()

    private enum CodingKeys: String, CodingKey {
        case keypadEnabled
        case maximumBrightness
        case pressFeedbackEnabled
        case pressFeedbackStrength
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            keypadEnabled: try container.decodeIfPresent(Bool.self, forKey: .keypadEnabled) ?? true,
            maximumBrightness: try container.decodeIfPresent(Double.self, forKey: .maximumBrightness) ?? 1,
            pressFeedbackEnabled: try container.decodeIfPresent(Bool.self, forKey: .pressFeedbackEnabled) ?? true,
            pressFeedbackStrength: try container.decodeIfPresent(Double.self, forKey: .pressFeedbackStrength) ?? 1
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keypadEnabled, forKey: .keypadEnabled)
        try container.encode(maximumBrightness, forKey: .maximumBrightness)
        try container.encode(pressFeedbackEnabled, forKey: .pressFeedbackEnabled)
        try container.encode(pressFeedbackStrength, forKey: .pressFeedbackStrength)
    }

    private static func normalized(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(1, max(0, value))
    }
}

public struct ControllerProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var bindings: [ControlID: BindingAction]

    public init(
        id: UUID = UUID(),
        name: String,
        bindings: [ControlID: BindingAction]
    ) {
        self.id = id
        self.name = name
        self.bindings = bindings
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case bindings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        bindings = try container.decode([ControlID: BindingAction].self, forKey: .bindings)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(bindings, forKey: .bindings)
    }
}

public enum HIDEventKind: String, Codable, Sendable {
    case button
    case axis
}

public struct HIDSignature: Codable, Hashable, CustomStringConvertible, Sendable {
    public var usagePage: UInt32
    public var usage: UInt32
    public var cookie: UInt64
    public var kind: HIDEventKind

    public init(usagePage: UInt32, usage: UInt32, cookie: UInt64, kind: HIDEventKind) {
        self.usagePage = usagePage
        self.usage = usage
        self.cookie = cookie
        self.kind = kind
    }

    public var description: String {
        String(format: "%04X:%04X · %llu", usagePage, usage, cookie)
    }

    public var portableKey: String {
        "\(usagePage):\(usage):\(kind.rawValue)"
    }
}

public struct CalibrationMap: Codable, Hashable, Sendable {
    public var signatures: [ControlID: HIDSignature]
    public var dpadDirections: [DPadDirection: ControlID]

    public init(
        signatures: [ControlID: HIDSignature] = [:],
        dpadDirections: [DPadDirection: ControlID] = Dictionary(
            uniqueKeysWithValues: DPadDirection.allCases.map { ($0, $0.controlID) }
        )
    ) {
        self.signatures = signatures
        self.dpadDirections = dpadDirections
    }

    private enum CodingKeys: String, CodingKey {
        case signatures
        case dpadDirections
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        signatures = try container.decodeIfPresent([ControlID: HIDSignature].self, forKey: .signatures) ?? [:]
        dpadDirections = try container.decodeIfPresent(
            [DPadDirection: ControlID].self,
            forKey: .dpadDirections
        ) ?? Dictionary(uniqueKeysWithValues: DPadDirection.allCases.map { ($0, $0.controlID) })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(signatures, forKey: .signatures)
        try container.encode(dpadDirections, forKey: .dpadDirections)
    }

    public func control(for signature: HIDSignature) -> ControlID? {
        signatures.first(where: {
            $0.value.usagePage == signature.usagePage &&
                $0.value.usage == signature.usage &&
                $0.value.kind == signature.kind
        })?.key
    }

    public func control(for direction: DPadDirection) -> ControlID? {
        dpadDirections[direction]
    }

    public static let nostromoFactory = CalibrationMap(signatures: [
        .key01: HIDSignature(usagePage: 0x07, usage: 0x2B, cookie: 0, kind: .button),
        .key02: HIDSignature(usagePage: 0x07, usage: 0x14, cookie: 0, kind: .button),
        .key03: HIDSignature(usagePage: 0x07, usage: 0x1A, cookie: 0, kind: .button),
        .key04: HIDSignature(usagePage: 0x07, usage: 0x08, cookie: 0, kind: .button),
        .key05: HIDSignature(usagePage: 0x07, usage: 0x15, cookie: 0, kind: .button),
        .key06: HIDSignature(usagePage: 0x07, usage: 0x39, cookie: 0, kind: .button),
        .key07: HIDSignature(usagePage: 0x07, usage: 0x04, cookie: 0, kind: .button),
        .key08: HIDSignature(usagePage: 0x07, usage: 0x16, cookie: 0, kind: .button),
        .key09: HIDSignature(usagePage: 0x07, usage: 0x07, cookie: 0, kind: .button),
        .key10: HIDSignature(usagePage: 0x07, usage: 0x09, cookie: 0, kind: .button),
        .key11: HIDSignature(usagePage: 0x07, usage: 0xE1, cookie: 0, kind: .button),
        .key12: HIDSignature(usagePage: 0x07, usage: 0x1D, cookie: 0, kind: .button),
        .key13: HIDSignature(usagePage: 0x07, usage: 0x1B, cookie: 0, kind: .button),
        .key14: HIDSignature(usagePage: 0x07, usage: 0x06, cookie: 0, kind: .button),
        .key15: HIDSignature(usagePage: 0x07, usage: 0x2C, cookie: 0, kind: .button),
        .key16: HIDSignature(usagePage: 0x07, usage: 0xE2, cookie: 0, kind: .button),
        .wheelPress: HIDSignature(usagePage: 0x09, usage: 0x03, cookie: 0, kind: .button),
    ])
}

public struct AppConfiguration: Codable, Sendable {
    public var version: Int
    public var activeProfileID: UUID
    public var profiles: [ControllerProfile]
    public var calibration: CalibrationMap
    public var lighting: LightingSettings
    public var forceUnsupportedChatGPT: Bool

    public init(
        version: Int = 1,
        activeProfileID: UUID,
        profiles: [ControllerProfile],
        calibration: CalibrationMap = .nostromoFactory,
        lighting: LightingSettings = .defaults,
        forceUnsupportedChatGPT: Bool = false
    ) {
        self.version = version
        self.activeProfileID = activeProfileID
        self.profiles = profiles
        self.calibration = calibration
        self.lighting = lighting
        self.forceUnsupportedChatGPT = forceUnsupportedChatGPT
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case activeProfileID
        case profiles
        case calibration
        case lighting
        case forceUnsupportedChatGPT
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        activeProfileID = try container.decode(UUID.self, forKey: .activeProfileID)
        profiles = try container.decode([ControllerProfile].self, forKey: .profiles)
        calibration = try container.decode(CalibrationMap.self, forKey: .calibration)
        lighting = try container.decodeIfPresent(LightingSettings.self, forKey: .lighting) ?? .defaults
        forceUnsupportedChatGPT = try container.decodeIfPresent(
            Bool.self,
            forKey: .forceUnsupportedChatGPT
        ) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(activeProfileID, forKey: .activeProfileID)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(calibration, forKey: .calibration)
        try container.encode(lighting, forKey: .lighting)
        try container.encode(forceUnsupportedChatGPT, forKey: .forceUnsupportedChatGPT)
    }

    public static func defaults() -> AppConfiguration {
        let profile = ControllerProfile(name: "Codex", bindings: [
            .key01: .taskSlot(3),
            .key02: .taskSlot(2),
            .key03: .taskSlot(1),
            .key04: .taskSlot(0),
            .key05: .codexAction("newTask"),
            .key06: .taskSlot(4),
            .key07: .taskSlot(5),
            .key08: .codexAction("previousThread"),
            .key09: .codexAction("nextThread"),
            .key10: .codexAction("composer.toggleChatWorkMode"),
            .key11: .codexAction("composer.togglePlanMode"),
            .key12: .codexAction("composer.stop"),
            .key13: .codexAction("approval.approve"),
            .key14: .codexAction("composer.submit"),
            .key15: .codexAction("pushToTalk"),
            .key16: .codexAction("focusChatGPT"),
            .dpadUp: .none,
            .dpadRight: .none,
            .dpadDown: .none,
            .dpadLeft: .none,
            .dpadUpRight: .none,
            .dpadDownRight: .none,
            .dpadDownLeft: .none,
            .dpadUpLeft: .none,
            .wheelPress: .none,
        ])
        return AppConfiguration(activeProfileID: profile.id, profiles: [profile])
    }
}

public struct CodexActionDescriptor: Identifiable, Hashable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case chat = "Чат"
        case mode = "Режим"
        case navigation = "Навигация"
        case panels = "Панели"
        case context = "Контекст"
        case workspace = "Рабочая область"
        case settings = "Настройки"
    }

    public var id: String
    public var title: String
    public var detail: String
    public var category: Category
    public var available: Bool
    public var execution: CodexActionExecution
    public var consequential: Bool
    public var requiresRuntimeRegistration: Bool

    public init(
        id: String,
        title: String,
        detail: String,
        category: Category,
        available: Bool = true,
        execution: CodexActionExecution = .runtimeCommand,
        consequential: Bool = false,
        requiresRuntimeRegistration: Bool = true
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.category = category
        self.available = available
        self.execution = execution
        self.consequential = consequential
        self.requiresRuntimeRegistration = requiresRuntimeRegistration
    }
}

public enum CodexActionExecution: Hashable, Sendable {
    case runtimeCommand
    case focusChatGPT
    case pushToTalk
    case stopActive
    case submitActiveComposer
    case toggleChatWorkMode
    case insertComposerText(String)
    case clearComposerProject
}

public enum CodexActionCatalog {
    public static let verified: [CodexActionDescriptor] = [
        .init(id: "composer.togglePlanMode", title: "Режим планирования", detail: "Включить или выключить планирование для активной задачи", category: .mode),
        .init(id: "composer.toggleFastMode", title: "Быстрый режим", detail: "Включить или выключить тариф Fast", category: .mode),
        .init(id: "composer.increaseReasoningEffort", title: "Рассуждение +", detail: "Увеличить глубину рассуждения", category: .mode),
        .init(id: "composer.decreaseReasoningEffort", title: "Рассуждение −", detail: "Уменьшить глубину рассуждения", category: .mode),
        .init(id: "composer.cycleReasoningEffort", title: "Сменить глубину рассуждения", detail: "Выбрать следующую поддерживаемую глубину рассуждения", category: .mode),
        .init(id: "composer.openModelPicker", title: "Выбрать модель", detail: "Открыть выбор модели", category: .mode),
        .init(
            id: "composer.toggleChatWorkMode",
            title: "Chat / Work",
            detail: "Переключить верхний режим композитора Chat ↔ Work; режим Codex не затрагивается",
            category: .mode,
            execution: .toggleChatWorkMode,
            requiresRuntimeRegistration: false
        ),
        .init(
            id: "composer.openPermissions",
            title: "Разрешения",
            detail: "В проверенных сборках нет идентификатора команды для этого окна",
            category: .mode,
            available: false
        ),
        .init(id: "composer.toggleWorktreeMode", title: "Локально / worktree", detail: "Переключить режим worktree, если его поддерживает активная задача", category: .mode),
        .init(id: "approval.approve", title: "Подтвердить", detail: "Подтвердить текущий запрос", category: .chat, consequential: true),
        .init(id: "approval.decline", title: "Отклонить", detail: "Отклонить текущий запрос", category: .chat, consequential: true),
        .init(id: "composer.stop", title: "Остановить", detail: "Остановить текущий ответ", category: .chat, execution: .stopActive, consequential: true, requiresRuntimeRegistration: false),
        .init(id: "composer.submit", title: "Отправить", detail: "Отправить содержимое поля ввода", category: .chat, execution: .submitActiveComposer, consequential: true),
        .init(id: "pushToTalk", title: "Диктовка", detail: "Удерживайте для диктовки; двойное нажатие фиксирует микрофон", category: .chat, execution: .pushToTalk, requiresRuntimeRegistration: false),
        .init(id: "newTask", title: "Новая задача", detail: "Открыть новую локальную задачу", category: .chat),
        .init(id: "forkThread", title: "Ответвить задачу", detail: "Продолжить в новой задаче", category: .chat),
        .init(id: "openSideChat", title: "Боковой чат", detail: "Открыть временный боковой чат", category: .chat),
        .init(id: "previousThread", title: "Предыдущая задача", detail: "Перейти назад", category: .navigation),
        .init(id: "nextThread", title: "Следующая задача", detail: "Перейти вперёд", category: .navigation),
        .init(id: "toggleSidebar", title: "Боковая панель", detail: "Показать или скрыть боковую панель", category: .panels),
        .init(id: "toggleTerminal", title: "Терминал", detail: "Показать или скрыть терминал", category: .panels),
        .init(id: "toggleReviewTab", title: "Панель проверки", detail: "Показать или скрыть проверку", category: .panels),
        .init(id: "openBrowserTab", title: "Браузер", detail: "Открыть браузер Codex", category: .panels),
        .init(id: "composer.addFiles", title: "Прикрепить файлы", detail: "Открыть выбор файлов", category: .context),
        .init(id: "composer.addPhotos", title: "Прикрепить фото", detail: "Открыть выбор фотографий", category: .context),
        .init(
            id: "composer.openSkillPicker",
            title: "Список навыков",
            detail: "Вставить $ и открыть список доступных навыков",
            category: .context,
            execution: .insertComposerText("$"),
            requiresRuntimeRegistration: false
        ),
        .init(id: "openFolder", title: "Открыть папку", detail: "Выбрать папку рабочей области", category: .workspace),
        .init(
            id: "composer.clearProject",
            title: "Работать без проекта",
            detail: "Убрать выбранный проект из нового чата",
            category: .workspace,
            execution: .clearComposerProject,
            requiresRuntimeRegistration: false
        ),
        .init(id: "environmentAction1", title: "Запустить действие среды", detail: "Запустить основное действие проекта", category: .workspace),
        .init(id: "git.commit", title: "Коммит", detail: "Открыть действие создания коммита", category: .workspace, consequential: true),
        .init(id: "git.createPullRequest", title: "Создать PR", detail: "Создать запрос на слияние", category: .workspace, consequential: true),
        .init(id: "openSkills", title: "Навыки", detail: "Открыть навыки", category: .settings),
        .init(id: "mcpSettings", title: "Плагины и MCP", detail: "Открыть настройки плагинов и MCP", category: .settings),
        .init(id: "manageTasks", title: "Расписание", detail: "Открыть запланированные задачи", category: .settings),
        .init(id: "settings", title: "Настройки", detail: "Открыть настройки ChatGPT", category: .settings),
        .init(
            id: "focusChatGPT",
            title: "Перейти к ChatGPT",
            detail: "Показать ChatGPT; повторным нажатием свернуть",
            category: .navigation,
            execution: .focusChatGPT,
            requiresRuntimeRegistration: false
        ),
    ]

    public static func descriptor(for id: String) -> CodexActionDescriptor? {
        verified.first(where: { $0.id == id })
    }

    public static func runtimeCatalog(commandIDs: Set<String>?) -> [CodexActionDescriptor] {
        guard let commandIDs else { return verified }
        return verified.map { descriptor in
            guard descriptor.requiresRuntimeRegistration else {
                return descriptor
            }
            var runtime = descriptor
            runtime.available = descriptor.available && commandIDs.contains(descriptor.id)
            if !runtime.available, descriptor.available {
                runtime.detail = "Не зарегистрировано в запущенной сборке ChatGPT"
            }
            return runtime
        }
    }
}
