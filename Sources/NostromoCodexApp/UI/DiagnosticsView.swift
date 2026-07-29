import Foundation
import NostromoCodexCore
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel

    private let calibrationOrder = ControlID.keypad + ControlID.dpad + [.wheelPress]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NostromoSpace.lg) {
                HStack {
                    NostromoSectionHeader(
                        "Диагностика",
                        detail: "Необработанные данные устройства и средства восстановления."
                    )
                    Spacer()
                    if model.hidOnlyMode {
                        StatusPill(title: "Только HID", color: NostromoTheme.success)
                    }
                }

                if model.hidOnlyMode {
                    Label(
                        "Мост, запуск ChatGPT, сочетания клавиш и все назначения отключены.",
                        systemImage: "checkmark.shield.fill"
                    )
                    .font(.callout.weight(.medium))
                    .foregroundStyle(NostromoTheme.success)
                    .padding(NostromoSpace.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(NostromoTheme.success.opacity(0.10), in: RoundedRectangle(cornerRadius: NostromoRadius.medium))
                    .overlay {
                        RoundedRectangle(cornerRadius: NostromoRadius.medium)
                            .strokeBorder(NostromoTheme.success.opacity(0.20))
                    }
                }

                if let warning = model.applicationIdentityWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(NostromoTheme.danger)
                        .padding(NostromoSpace.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            NostromoTheme.danger.opacity(0.10),
                            in: RoundedRectangle(
                                cornerRadius: NostromoRadius.medium
                            )
                        )
                }

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 14
                ) {
                    DiagnosticCard(
                        title: "Nostromo HID",
                        value: deviceTitle,
                        detail: "VID 1532 · PID 0111",
                        color: deviceColor,
                        icon: "keyboard"
                    )
                    DiagnosticCard(
                        title: "Подключение к Codex",
                        value: bridgeTitle,
                        detail: "Защищённый Unix-сокет · протокол v2",
                        color: bridgeColor,
                        icon: "lock.shield"
                    )
                    DiagnosticCard(
                        title: "Сборка ChatGPT",
                        value: "\(model.compatibility.version) (\(model.compatibility.build))",
                        detail: model.compatibility.supported
                            ? "Проверенный адаптер совместимости"
                            : (model.compatibility.reason ?? "Непроверенная сборка"),
                        color: model.compatibility.supported
                            ? NostromoTheme.success
                            : NostromoTheme.danger,
                        icon: "shippingbox"
                    )
                    DiagnosticCard(
                        title: "Последнее HID-событие",
                        value: model.lastHIDEvent,
                        detail: model.inputTestMode ? "Проверка ввода блокирует назначения" : "Назначения активны",
                        color: model.inputTestMode ? NostromoTheme.success : NostromoTheme.accent,
                        icon: "waveform.path.ecg"
                    )
                    DiagnosticCard(
                        title: "Защита от печати",
                        value: keyboardSuppressionTitle,
                        detail: "Только клавиатурный интерфейс Nostromo 1532:0111",
                        color: keyboardSuppressionColor,
                        icon: "keyboard.badge.ellipsis"
                    )
                }

                applicationIdentityPanel
                pipelinePanel
                calibrationPanel
                eventLogPanel
                capabilityPanel
                taskLightingPanel
            }
            .frame(maxWidth: 920)
        }
    }

    private var calibrationPanel: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Физическая калибровка")
                        .font(.headline)
                    Text("Записывает фактическую HID-сигнатуру каждого элемента без выполнения назначений.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if model.calibrationTarget != nil {
                    Button("Отмена", role: .cancel) {
                        model.cancelCalibration()
                    }
                } else {
                    Button("Начать калибровку") {
                        model.beginCalibration()
                    }
                    .buttonStyle(NostromoButtonStyle(variant: .primary))
                    .accessibilityValue("Начать физическую калибровку")
                    .accessibilityHint("Запускает последовательную запись всех элементов Nostromo")
                }
            }

            if let target = model.calibrationTarget {
                Divider()

                HStack(spacing: 14) {
                    Text(target.title)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(NostromoTheme.signal, in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Нажмите элемент \(target.title)")
                            .font(.callout.weight(.semibold))
                        ProgressView(value: calibrationProgress)
                            .frame(maxWidth: 300)
                        Text("\(calibrationStep) из \(calibrationOrder.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(NostromoTheme.mutedForeground)
                    }
                    Spacer()
                }
            } else {
                Divider()
                Toggle(
                    "Проверка ввода",
                    isOn: Binding(
                        get: { model.inputTestMode },
                        set: { model.setInputTestMode($0) }
                    )
                )
                .help("Проверка ввода")
                .accessibilityLabel("Проверка ввода")
                .accessibilityValue(model.inputTestMode ? "Включено" : "Выключено")
                .accessibilityHint("Проверяет физический ввод без выполнения назначений")
                Text("Используйте перед калибровкой, если нужно только проверить распознавание элемента.")
                    .font(.caption)
                    .foregroundStyle(NostromoTheme.mutedForeground)
            }
        }
        .padding(NostromoSpace.md)
        .nostromoPanel()
    }

    private var applicationIdentityPanel: some View {
        let identity = model.applicationIdentity
        return VStack(alignment: .leading, spacing: 12) {
            Text("Идентичность приложения")
                .font(.headline)
            Text(
                "Помогает отличить проблему HID от разрешений, выданных "
                    + "другой копии или другой подписи приложения."
            )
            .font(.caption)
            .foregroundStyle(NostromoTheme.mutedForeground)

            Divider()

            Grid(
                alignment: .leading,
                horizontalSpacing: 20,
                verticalSpacing: 7
            ) {
                pipelineRow("Запущенная копия", identity.runningBundlePath)
                pipelineRow(
                    "Копия, зарегистрированная macOS",
                    identity.registeredBundlePath ?? "—"
                )
                pipelineRow(
                    "Code identifier",
                    identity.codeIdentifier ?? "—"
                )
                pipelineRow(
                    "Team identifier",
                    identity.teamIdentifier ?? "—"
                )
                pipelineRow("CDHash", identity.cdHash ?? "—")
                pipelineRow(
                    "Проверка подписи",
                    identity.signatureValidationStatus.map(String.init)
                        ?? "недоступна"
                )
            }
            .font(.caption)
        }
        .padding(NostromoSpace.md)
        .nostromoPanel()
    }

    private var pipelinePanel: some View {
        let pipeline = model.hidPipelineDiagnostics
        return VStack(alignment: .leading, spacing: 12) {
            Text("Трассировка обработки")
                .font(.headline)
            Text(
                "Показывает, на каком слое останавливается нажатие: "
                    + "сырой HID → сопоставление → назначение → мост."
            )
            .font(.caption)
            .foregroundStyle(NostromoTheme.mutedForeground)

            Divider()

            Grid(
                alignment: .leading,
                horizontalSpacing: 20,
                verticalSpacing: 7
            ) {
                pipelineRow(
                    "Сырые / допустимые события",
                    "\(pipeline.rawEventCount) / \(pipeline.eligibleEventCount)"
                )
                pipelineRow(
                    "Сопоставлено с элементом",
                    "\(pipeline.mappedControlCount)"
                )
                pipelineRow(
                    "Выполнено назначений",
                    "\(pipeline.bindingExecutionCount)"
                )
                pipelineRow(
                    "Заблокировано защитой",
                    "\(pipeline.blockedActionCount)"
                )
                pipelineRow(
                    "Мост: попытки / успех / ошибка",
                    "\(pipeline.bridgeDispatchAttemptCount) / "
                        + "\(pipeline.bridgeDispatchSuccessCount) / "
                        + "\(pipeline.bridgeDispatchFailureCount)"
                )
                pipelineRow(
                    "Последний элемент",
                    pipeline.lastMappedControl ?? "—"
                )
                pipelineRow(
                    "Последнее назначение",
                    pipeline.lastBinding ?? "—"
                )
                pipelineRow(
                    "Последняя отправка",
                    pipelineLastDispatchTitle
                )
            }
            .font(.caption)
        }
        .padding(NostromoSpace.md)
        .nostromoPanel()
    }

    private func pipelineRow(
        _ title: String,
        _ value: String
    ) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(NostromoTheme.mutedForeground)
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }

    private var pipelineLastDispatchTitle: String {
        let value = [
            model.hidPipelineDiagnostics.lastBridgeAction,
            model.hidPipelineDiagnostics.lastDispatchOutcome,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        return value.isEmpty ? "—" : value
    }

    private var eventLogPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Необработанный журнал HID")
                        .font(.headline)
                    Text(eventLogDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Очистить") {
                    model.clearHIDDiagnostics()
                }
                .buttonStyle(NostromoButtonStyle(variant: .ghost, compact: true))
                .accessibilityValue("Очистить журнал HID")
                .disabled(model.hidDiagnosticEvents.isEmpty)
                Button("Экспортировать JSON…") {
                    model.exportHIDDiagnostics()
                }
                .buttonStyle(NostromoButtonStyle(variant: .outline, compact: true))
                .accessibilityValue("Экспортировать журнал HID в JSON")
                .disabled(model.hidDiagnosticEvents.isEmpty)
            }

            Divider()

            if model.hidDiagnosticEvents.isEmpty {
                ContentUnavailableView {
                    Label("Нет записанных событий", systemImage: "waveform.path")
                } description: {
                    Text("Журнал начнёт заполняться после первого HID-события.")
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ForEach(Array(model.hidDiagnosticEvents.suffix(14).reversed())) { event in
                    HStack {
                        Text(event.summary)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        if !event.eligibleForAction {
                            Text("ПОДАВЛЕНО")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(NostromoTheme.signal)
                        }
                    }
                }
            }
        }
        .padding(NostromoSpace.md)
        .nostromoPanel()
    }

    private var eventLogDetail: String {
        let limit = model.hidOnlyMode ? 2_000 : 256
        let base =
            "Событий: \(model.hidDiagnosticEvents.count) "
            + "· в памяти хранится до \(limit)"
        guard let p95 = model.hidCallbackLatencyP95Milliseconds else { return base }
        return base + String(format: " · задержка p95 %.2f мс", p95)
    }

    private var taskLightingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Индикация задач")
                .font(.headline)
            HStack(spacing: 10) {
                ForEach(model.lighting.threads, id: \.id) { thread in
                    VStack(spacing: 8) {
                        Circle()
                            .fill(
                                Color(rgbValue: thread.color)
                                    .opacity(max(0.16, thread.brightness))
                            )
                            .frame(width: 17, height: 17)
                            .overlay {
                                Circle().strokeBorder(
                                    thread.selected ? Color.primary : .clear,
                                    lineWidth: 2
                                )
                            }
                        Text("\(thread.id + 1)")
                            .font(.caption.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "Задача \(thread.id + 1)\(thread.selected ? ", выбрана" : "")"
                    )
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
                GridRow {
                    Text("Источник")
                        .foregroundStyle(NostromoTheme.mutedForeground)
                    Text(lightingSourceTitle)
                }
                GridRow {
                    Text("Запрошено")
                        .foregroundStyle(NostromoTheme.mutedForeground)
                    Text(model.lightingResolution.requestedBrightness, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                GridRow {
                    Text("Предел пользователя")
                        .foregroundStyle(NostromoTheme.mutedForeground)
                    Text(model.lightingResolution.maximumBrightness, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                GridRow {
                    Text("Применено")
                        .foregroundStyle(NostromoTheme.mutedForeground)
                    Text("\(model.lightingResolution.appliedBrightness) / 255")
                        .monospacedDigit()
                }
            }
            .font(.caption)

            Text("Состояния шести задач Codex отображаются тремя светодиодами профиля и яркостью клавиш.")
                .font(.caption)
                .foregroundStyle(NostromoTheme.mutedForeground)
        }
        .padding(NostromoSpace.md)
        .nostromoPanel()
    }

    private var capabilityPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Возможности среды выполнения")
                .font(.headline)
            if let capabilities = model.runtimeCapabilities {
                LabeledContent(
                    "Каталог команд",
                    value: "\(capabilities.commandIDs.count) · \(commandRegistrySourceTitle(capabilities.commandRegistrySource))"
                )
                LabeledContent(
                    "Глубина рассуждения",
                    value: reasoningEffortTitle(model.reasoningEffort)
                )
                ForEach(capabilities.requiredAPIs.keys.sorted(), id: \.self) { name in
                    LabeledContent(
                        capabilityTitle(name),
                        value: capabilities.requiredAPIs[name] == true ? "Доступно" : "Отсутствует"
                    )
                }
                if !capabilities.unavailableFeatures.isEmpty {
                    Text(capabilities.unavailableFeatures.joined(separator: "\n"))
                        .font(.caption)
                        .foregroundStyle(NostromoTheme.signal)
                        .textSelection(.enabled)
                }
            } else {
                Text("Будет доступно после защищённого подключения к ChatGPT.")
                    .font(.caption)
                    .foregroundStyle(NostromoTheme.mutedForeground)
            }
            if !model.hidDiagnosticMessages.isEmpty {
                Divider()
                Text(model.hidDiagnosticMessages.suffix(8).joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(NostromoTheme.danger)
                    .textSelection(.enabled)
            }
        }
        .padding(NostromoSpace.md)
        .nostromoPanel()
    }

    private var calibrationStep: Int {
        guard
            let target = model.calibrationTarget,
            let index = calibrationOrder.firstIndex(of: target)
        else {
            return 0
        }
        return index + 1
    }

    private var calibrationProgress: Double {
        Double(calibrationStep) / Double(calibrationOrder.count)
    }

    private var deviceTitle: String {
        switch model.deviceState {
        case .stopped:
            return "Выкл."
        case .waitingForPermission:
            return "Нужен доступ к вводу"
        case .disconnected:
            return "Не подключён"
        case let .connected(count, captureMode):
            let mode = captureMode == .exclusive
                ? "exclusive"
                : "shared"
            return "Подключён · \(mode) · интерфейсов: \(count)"
        case let .error(message):
            return message
        }
    }

    private var deviceColor: Color {
        if case .connected = model.deviceState { return NostromoTheme.success }
        if case .error = model.deviceState { return NostromoTheme.danger }
        return NostromoTheme.signal
    }

    private var keyboardSuppressionTitle: String {
        switch model.inputProtectionStatus {
        case .inactive:
            "Выкл."
        case .pending:
            "Включение…"
        case .exclusiveCapture:
            "Активна · эксклюзивный HID-захват"
        case let .active(serviceCount, usageCount):
            "Активна · сервисов: \(serviceCount) · usages: \(usageCount)"
        case .deviceUnavailable:
            "HID-сервис не найден"
        case let .failed(failure):
            failure.summary
        }
    }

    private var keyboardSuppressionColor: Color {
        switch model.inputProtectionStatus {
        case .exclusiveCapture, .active:
            NostromoTheme.success
        case .pending:
            NostromoTheme.signal
        case .inactive:
            .secondary
        case .deviceUnavailable, .failed:
            NostromoTheme.danger
        }
    }

    private var bridgeTitle: String {
        switch model.bridgeStatus {
        case .stopped: "Выкл."
        case .listening: "Ожидание ChatGPT"
        case .connected: "Подключено"
        case let .failed(message): message
        }
    }

    private var bridgeColor: Color {
        switch model.bridgeStatus {
        case .connected: NostromoTheme.success
        case .failed: NostromoTheme.danger
        case .listening: NostromoTheme.signal
        case .stopped: .secondary
        }
    }

    private var lightingSourceTitle: String {
        let summary = model.lightingResolution.summary
        let statuses = [
            summary.red ? "Требуется действие · красный" : nil,
            summary.green ? "Задача выполняется · зелёный" : nil,
            summary.blue ? "Задача завершена · синий" : nil,
        ].compactMap { $0 }
        return statuses.isEmpty
            ? "Нет активных статусов задач"
            : statuses.joined(separator: " · ")
    }

    private func commandRegistrySourceTitle(_ source: String) -> String {
        switch source {
        case "runtime-app-asar": "Текущая сборка ChatGPT"
        case "verified-fallback": "Проверенный резервный каталог"
        default: source
        }
    }

    private func capabilityTitle(_ name: String) -> String {
        switch name {
        case "browserWindow": "Окно ChatGPT"
        case "rendererMessaging": "Сообщения интерфейсу"
        case "rendererEvaluation": "Выполнение кода интерфейса"
        case "scopedHidHook": "Изолированный HID-перехват"
        default: name
        }
    }

    private func reasoningEffortTitle(_ effort: String?) -> String {
        switch effort {
        case "none": "Без рассуждения"
        case "minimal": "Минимальная"
        case "low": "Низкая"
        case "medium": "Средняя"
        case "high": "Высокая"
        case "xhigh": "Очень высокая"
        case "max": "Максимальная"
        case "ultra": "Ультра"
        case let value?: value
        case nil: "Не предоставлено интерфейсом"
        }
    }
}

private struct DiagnosticCard: View {
    let title: String
    let value: String
    let detail: String
    let color: Color
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: NostromoRadius.small))

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NostromoTheme.mutedForeground)
                Text(value)
                    .font(.headline)
                    .lineLimit(2)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(NostromoTheme.mutedForeground)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(NostromoSpace.md)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .nostromoPanel()
        .accessibilityElement(children: .combine)
    }
}

private extension Color {
    init(rgbValue: Int) {
        self.init(
            red: Double((rgbValue >> 16) & 0xFF) / 255,
            green: Double((rgbValue >> 8) & 0xFF) / 255,
            blue: Double(rgbValue & 0xFF) / 255
        )
    }
}
