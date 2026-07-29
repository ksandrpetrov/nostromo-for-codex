import Foundation

enum SetupPhase: Int, CaseIterable, Identifiable {
    case welcome
    case connect
    case keymap
    case test

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: "Познакомьтесь с контроллером Codex"
        case .connect: "Подключите Nostromo"
        case .keymap: "Выберите начальную раскладку"
        case .test: "Освойте управление"
        }
    }
}

enum StarterKeymap: String, CaseIterable, Identifiable {
    case codexEssentials
    case blank

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codexEssentials: "Основные действия Codex"
        case .blank: "Пустая раскладка"
        }
    }

    var detail: String {
        switch self {
        case .codexEssentials:
            "Шесть задач, подтверждения, диктовка, вложения, навигация и управление режимами."
        case .blank:
            "Отключить все элементы управления и настроить раскладку самостоятельно."
        }
    }
}

enum ReadinessState: Equatable {
    case ready
    case setupRequired
    case controllerOff
    case permissionRequired
    case deviceDisconnected
    case unsupportedChatGPT
    case launchChatGPT
    case restartChatGPT
    case bridgeUnavailable

    var title: String {
        switch self {
        case .ready: "Готово"
        case .setupRequired: "Завершите настройку"
        case .controllerOff: "Контроллер выключен"
        case .permissionRequired: "Нужен доступ к вводу"
        case .deviceDisconnected: "Nostromo не подключён"
        case .unsupportedChatGPT: "Требуется проверка ChatGPT"
        case .launchChatGPT: "Запустить ChatGPT"
        case .restartChatGPT: "Перезапустить ChatGPT"
        case .bridgeUnavailable: "Подключение к Codex недоступно"
        }
    }

    var detail: String {
        switch self {
        case .ready: "Nostromo подключён к Codex."
        case .setupRequired: "Завершите пошаговую настройку перед использованием назначений."
        case .controllerOff: "Включите контроллер, чтобы использовать физические назначения."
        case .permissionRequired: "Разрешите мониторинг ввода, чтобы Nostromo Codex мог читать данные устройства."
        case .deviceDisconnected: "Подключите Razer Nostromo к этому Mac."
        case .unsupportedChatGPT: "Установленная сборка ChatGPT не прошла проверку совместимости."
        case .launchChatGPT: "Запустите ChatGPT через Nostromo, чтобы подключить Codex."
        case .restartChatGPT: "Один раз перезапустите ChatGPT через Nostromo, чтобы подключить Codex."
        case .bridgeUnavailable: "Не удалось запустить приватное локальное подключение."
        }
    }

    var systemImage: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .setupRequired: "sparkles"
        case .controllerOff: "pause.circle.fill"
        case .permissionRequired: "hand.raised.fill"
        case .deviceDisconnected: "cable.connector.slash"
        case .unsupportedChatGPT: "exclamationmark.shield.fill"
        case .launchChatGPT: "play.circle.fill"
        case .restartChatGPT: "arrow.clockwise.circle.fill"
        case .bridgeUnavailable: "exclamationmark.triangle.fill"
        }
    }
}

enum RuntimeFeedbackKind: Equatable {
    case action
    case mode
    case voice
    case error
}

struct RuntimeFeedback: Equatable {
    var message: String
    var symbol: String
    var kind: RuntimeFeedbackKind
    var persistent: Bool
}
