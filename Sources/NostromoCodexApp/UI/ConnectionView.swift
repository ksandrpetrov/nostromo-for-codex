import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showRestartConfirmation = false
    @State private var showCompatibilityOverrideConfirmation = false
    @State private var showExpertOptions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NostromoSpace.lg) {
                HStack(alignment: .center, spacing: 18) {
                    Image(systemName: model.readiness.systemImage)
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(readinessColor)
                        .frame(width: 54, height: 54)
                        .background(readinessColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))

                    NostromoSectionHeader(model.readiness.title, detail: model.readiness.detail)
                    Spacer()
                }

                VStack(spacing: 0) {
                    ConnectionRow(
                        symbol: "keyboard",
                        title: "Razer Nostromo",
                        value: deviceValue,
                        detail: "USB · VID 1532 · PID 0111",
                        state: deviceState
                    ) {
                        if case .stopped = model.deviceState {
                            Button("Включить") { model.connectController() }
                                .accessibilityValue("Включить контроллер Nostromo")
                        } else if case .waitingForPermission = model.deviceState {
                            Button("Разрешить доступ к вводу") { model.requestInputMonitoring() }
                                .buttonStyle(NostromoButtonStyle(variant: .primary, compact: true))
                                .accessibilityValue("Разрешить доступ к вводу")
                        }
                    }

                    Divider().padding(.leading, 72)

                    ConnectionRow(
                        symbol: "bubble.left.and.bubble.right",
                        title: "ChatGPT",
                        value: "\(model.compatibility.version) (\(model.compatibility.build))",
                        detail: chatGPTDetail,
                        state: model.compatibility.supported ? .ready : .error
                    ) {
                        if model.chatGPTNeedsRestart {
                            Button("Перезапустить ChatGPT…") {
                                showRestartConfirmation = true
                            }
                            .buttonStyle(NostromoButtonStyle(variant: .primary, compact: true))
                            .accessibilityValue("Перезапустить ChatGPT")
                            .accessibilityHint("Показывает предупреждение перед закрытием ChatGPT")
                        } else if !model.launcher.isRunning() {
                            Button("Запустить ChatGPT") {
                                model.launchChatGPT()
                            }
                            .accessibilityValue("Запустить ChatGPT")
                        }
                    }

                    Divider().padding(.leading, 72)

                    ConnectionRow(
                        symbol: "lock.shield",
                        title: "Приватное подключение к Codex",
                        value: bridgeValue,
                        detail: "Защищённый локальный сокет · ChatGPT.app не изменяется",
                        state: bridgeState
                    ) {
                        EmptyView()
                    }
                }
                .nostromoPanel()

                VStack(alignment: .leading, spacing: NostromoSpace.md) {
                    Text("Поведение")
                        .font(.headline)

                    Label("Nostromo Codex находится в строке меню", systemImage: "menubar.rectangle")
                        .accessibilityLabel("Nostromo Codex находится в строке меню")
                    Text("Значок в верхней строке меню остаётся доступным, а приложение не занимает место в Dock.")
                    .font(.caption)
                    .foregroundStyle(NostromoTheme.mutedForeground)

                    Divider()

                    Toggle(
                        "Запускать ChatGPT автоматически",
                        isOn: Binding(
                            get: { model.preferences.autoLaunchChatGPT },
                            set: { model.setAutoLaunchChatGPT($0) }
                        )
                    )
                    .help("Запускать ChatGPT автоматически")
                    .accessibilityLabel("Запускать ChatGPT автоматически")
                    .accessibilityValue(
                        model.preferences.autoLaunchChatGPT ? "Включено" : "Выключено"
                    )
                    Text("Действует только после настройки и не завершает уже запущенный ChatGPT.")
                        .font(.caption)
                        .foregroundStyle(NostromoTheme.mutedForeground)
                }
                .padding(NostromoSpace.lg)
                .nostromoPanel()

                DisclosureGroup("Экспертные настройки", isExpanded: $showExpertOptions) {
                    VStack(alignment: .leading, spacing: 14) {
                        Divider()

                        Toggle(
                            "Разрешить эту непроверенную сборку ChatGPT",
                            isOn: Binding(
                                get: { model.configuration.forceUnsupportedChatGPT },
                                set: { enabled in
                                    if enabled {
                                        showCompatibilityOverrideConfirmation = true
                                    } else {
                                        model.setForceUnsupported(false)
                                    }
                                }
                            )
                        )
                        .tint(NostromoTheme.danger)
                        .help("Разрешить эту непроверенную сборку ChatGPT")
                        .accessibilityLabel("Разрешить эту непроверенную сборку ChatGPT")
                        .accessibilityValue(
                            model.configuration.forceUnsupportedChatGPT ? "Включено" : "Выключено"
                        )
                        .accessibilityHint("Требует подтверждения и не обходит проверку обязательных модулей")

                        Text(
                            "Это отключает только проверку списка разрешённых сборок. Отсутствующие приватные "
                                + "модули и несовместимые идентификаторы команд по-прежнему вызовут ошибку."
                        )
                        .font(.caption)
                        .foregroundStyle(NostromoTheme.signal)

                        HStack {
                            Button("Повторить настройку") {
                                model.restartSetup()
                            }
                            Spacer()
                            Text("Параметры настройки остаются на этом Mac и не экспортируются.")
                                .font(.caption)
                                .foregroundStyle(NostromoTheme.mutedForeground)
                        }
                    }
                    .padding(.top, 10)
                }
                .padding(NostromoSpace.lg)
                .nostromoPanel()
                .accessibilityLabel("Экспертные настройки")
            }
            .frame(maxWidth: 880)
        }
        .confirmationDialog(
            "Перезапустить ChatGPT через Nostromo?",
            isPresented: $showRestartConfirmation
        ) {
            Button("Перезапустить ChatGPT", role: .destructive) {
                model.restartThroughNostromo()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(
                "ChatGPT будет закрыт. Перед продолжением сохраните или скопируйте незавершённый текст. "
                    + "Затем Nostromo перезапустит проверенную сборку с приватным локальным подключением."
            )
        }
        .confirmationDialog(
            "Разрешить непроверенную сборку \(model.compatibility.build)?",
            isPresented: $showCompatibilityOverrideConfirmation
        ) {
            Button("Разрешить непроверенную сборку", role: .destructive) {
                model.setForceUnsupported(true)
            }
            Button("Отмена", role: .cancel) {
                model.setForceUnsupported(false)
            }
        } message: {
            Text("Команды могут не работать или вести себя иначе. Эта настройка не восстанавливает отсутствующие модули.")
        }
    }

    private var readinessColor: Color {
        switch model.readiness {
        case .ready: NostromoTheme.success
        case .controllerOff: .secondary
        case .setupRequired, .permissionRequired, .deviceDisconnected, .launchChatGPT, .restartChatGPT:
            NostromoTheme.signal
        case .unsupportedChatGPT, .bridgeUnavailable:
            NostromoTheme.danger
        }
    }

    private var deviceValue: String {
        switch model.deviceState {
        case .stopped:
            return "Выкл."
        case .waitingForPermission:
            return "Нужен доступ к вводу"
        case .disconnected:
            return "Не подключён"
        case let .connected(count, captureMode):
            let mode = captureMode == .exclusive
                ? "эксклюзивно"
                : "общий доступ"
            return "Подключён · \(mode) · интерфейсов: \(count)"
        case let .error(message):
            return message
        }
    }

    private var deviceState: ConnectionState {
        switch model.deviceState {
        case .connected: .ready
        case .stopped: .off
        case .waitingForPermission, .disconnected: .attention
        case .error: .error
        }
    }

    private var chatGPTDetail: String {
        if model.compatibility.supported {
            return "Проверенный адаптер совместимости"
        }
        return model.compatibility.reason ?? "Эта сборка не проверена."
    }

    private var bridgeValue: String {
        switch model.bridgeStatus {
        case .stopped: "Выкл."
        case .listening: "Ожидание ChatGPT"
        case .connected: "Подключено"
        case let .failed(message): message
        }
    }

    private var bridgeState: ConnectionState {
        switch model.bridgeStatus {
        case .connected: .ready
        case .listening: .attention
        case .stopped: .off
        case .failed: .error
        }
    }
}

private enum ConnectionState {
    case ready
    case attention
    case error
    case off
}

private struct ConnectionRow<Accessory: View>: View {
    let symbol: String
    let title: String
    let value: String
    let detail: String
    let state: ConnectionState
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
            .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: NostromoRadius.medium))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                HStack(spacing: 7) {
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                    Text(value)
                        .font(.callout.weight(.medium))
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(NostromoTheme.mutedForeground)
            }

            Spacer()
            accessory()
        }
        .padding(NostromoSpace.md)
        .accessibilityElement(children: .contain)
    }

    private var tint: Color {
        switch state {
        case .ready: NostromoTheme.success
        case .attention: NostromoTheme.signal
        case .error: NostromoTheme.danger
        case .off: .secondary
        }
    }
}
