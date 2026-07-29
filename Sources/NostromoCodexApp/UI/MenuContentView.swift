import AppKit
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showRestartConfirmation = false
    let openDashboard: (DashboardSection) -> Void

    init(openDashboard: @escaping (DashboardSection) -> Void) {
        self.openDashboard = openDashboard
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NostromoSpace.sm) {
            HStack(spacing: 12) {
                Image(systemName: model.readiness.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(readinessColor)
                    .frame(width: 38, height: 38)
                    .background(readinessColor.opacity(0.12), in: RoundedRectangle(cornerRadius: NostromoRadius.medium))

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.readiness.title)
                        .font(.headline)
                    Text(model.readiness.detail)
                        .font(.caption)
                        .foregroundStyle(NostromoTheme.mutedForeground)
                        .lineLimit(2)
                }
                Spacer()
            }

            Divider()

            Button("Открыть Nostromo Codex") {
                open(model.dashboardSection)
            }
            .buttonStyle(NostromoButtonStyle(variant: .primary))
            .accessibilityValue("Открыть Nostromo Codex")

            if model.preferences.setupCompleted {
                Picker("Профиль", selection: Binding(
                    get: { model.configuration.activeProfileID },
                    set: { model.activateProfile($0) }
                )) {
                    ForEach(model.configuration.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }

                Toggle(
                    "Включить контроллер",
                    isOn: Binding(
                        get: { model.controllerEnabled },
                        set: { model.setControllerEnabled($0) }
                    )
                )
                .help("Включить контроллер")
                .accessibilityLabel("Включить контроллер")
                .accessibilityValue(model.controllerEnabled ? "Включено" : "Выключено")
                .accessibilityHint("Запускает или останавливает чтение Nostromo")
            }

            primaryAction

            HStack(spacing: 8) {
                Button("Раскладка") {
                    open(.mappings)
                }
                .buttonStyle(NostromoButtonStyle(variant: .primary))
                .accessibilityValue("Открыть раскладку")

                Button("Подключение") {
                    open(.connection)
                }
                .buttonStyle(NostromoButtonStyle(variant: .outline))
                .accessibilityValue("Открыть подключение")
            }

            Divider()

            Button("Выйти из Nostromo Codex") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(NostromoSpace.md)
        .frame(width: 340)
        .nostromoScreen()
        .onAppear { model.start() }
        .confirmationDialog(
            "Перезапустить ChatGPT через Nostromo?",
            isPresented: $showRestartConfirmation
        ) {
            Button("Перезапустить ChatGPT", role: .destructive) {
                model.restartThroughNostromo()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Сначала сохраните незавершённый текст. ChatGPT будет закрыт и запущен заново.")
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if !model.preferences.setupCompleted {
            Button("Завершить настройку") {
                open(.connection)
            }
            .buttonStyle(NostromoButtonStyle(variant: .primary))
        } else if model.chatGPTNeedsRestart {
            Button("Перезапустить ChatGPT…") {
                showRestartConfirmation = true
            }
        } else if !model.launcher.isRunning() {
            Button("Запустить ChatGPT") {
                model.launchChatGPT()
            }
        } else if model.readiness != .ready {
            Button("Исправить подключение") {
                open(.connection)
            }
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

    private func open(_ section: DashboardSection) {
        model.dashboardSection = section
        openDashboard(section)
    }
}
