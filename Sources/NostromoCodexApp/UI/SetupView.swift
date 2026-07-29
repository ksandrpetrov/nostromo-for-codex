import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var autoLaunchChatGPT = true

    var body: some View {
        HStack(spacing: 0) {
            setupRail

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    NostromoSectionHeader(model.setupPhase.title, detail: stepSubtitle)
                    Spacer()
                    Text("\(model.setupPhase.rawValue + 1) из \(SetupPhase.allCases.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(NostromoTheme.mutedForeground)
                }
                .padding(.horizontal, NostromoSpace.xl)
                .padding(.top, NostromoSpace.xl)
                .padding(.bottom, NostromoSpace.lg)

                Divider()

                Group {
                    switch model.setupPhase {
                    case .welcome:
                        welcome
                    case .connect:
                        connect
                    case .keymap:
                        keymap
                    case .test:
                        inputTest
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(NostromoSpace.xl)

                Divider()
                footer
            }
            .background(NostromoTheme.background)
        }
        .nostromoScreen()
        .onChange(of: model.setupPhase) { _, phase in
            model.setInputTestMode(phase == .test)
        }
        .onDisappear {
            if !model.preferences.setupCompleted {
                model.setInputTestMode(false)
            }
        }
    }

    private var setupRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "command.square.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(NostromoTheme.accent)
                Text("Nostromo\nCodex")
                    .font(.system(size: 15, weight: .semibold))
                    .lineSpacing(0)
            }
            .padding(.bottom, NostromoSpace.xl)

            ForEach(SetupPhase.allCases) { phase in
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(stepFill(phase))
                            .frame(width: 26, height: 26)
                        if phase.rawValue < model.setupPhase.rawValue {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        } else {
                            Text("\(phase.rawValue + 1)")
                                .font(.caption.monospacedDigit().bold())
                                .foregroundStyle(
                                    phase == model.setupPhase ? .white : .secondary
                                )
                        }
                    }

                    Text(shortTitle(phase))
                        .font(.subheadline.weight(phase == model.setupPhase ? .semibold : .regular))
                        .foregroundStyle(
                            phase == model.setupPhase
                                ? NostromoTheme.foreground
                                : NostromoTheme.mutedForeground
                        )
                }
                .padding(.vertical, 9)
            }

            Spacer()

            Text("Razer Nostromo · RZ07-0049")
                .font(.caption.monospaced())
                .foregroundStyle(NostromoTheme.mutedForeground)
        }
        .padding(NostromoSpace.lg)
        .frame(width: 230)
        .background(NostromoTheme.elevated)
        .overlay(alignment: .trailing) {
            Divider()
        }
    }

    private var welcome: some View {
        HStack(spacing: 36) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Не отрывайте руку\nот работы.")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                Text(
                    "Nostromo превращается в физическую панель команд Codex: "
                        + "задачи, диктовка, подтверждения, режимы, контекст и навигация."
                )
                .font(.title3)
                .foregroundStyle(NostromoTheme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 13) {
                    SetupBenefit(symbol: "hand.raised.fingers.spread", text: "Пространственное управление одной рукой")
                    SetupBenefit(symbol: "checkmark.shield", text: "Во время настройки действия не выполняются")
                    SetupBenefit(symbol: "macwindow", text: "Нативное приватное локальное подключение")
                }
            }
            .frame(maxWidth: 390, alignment: .leading)

            DecorativeDeviceTwin()
                .frame(maxWidth: .infinity, maxHeight: 400)
        }
    }

    private var connect: some View {
        VStack(spacing: 16) {
            SetupStatusCard(
                symbol: deviceConnected ? "checkmark.circle.fill" : "keyboard.badge.ellipsis",
                title: "Razer Nostromo",
                detail: deviceStatusDetail,
                state: deviceConnected ? .success : .attention
            ) {
                if !deviceConnected {
                    Button("Разрешить доступ к вводу") {
                        model.requestInputMonitoring()
                    }
                    .buttonStyle(NostromoButtonStyle(variant: .primary))
                    .accessibilityValue("Разрешить доступ к вводу")
                }
            }

            SetupStatusCard(
                symbol: model.compatibility.supported ? "checkmark.circle.fill" : "shippingbox",
                title: "ChatGPT",
                detail: chatGPTStatusDetail,
                state: model.compatibility.supported ? .success : .danger
            ) {
                EmptyView()
            }

            SetupStatusCard(
                symbol: "lock.shield",
                title: "Приватное подключение",
                detail: "Защищённый локальный сокет. ChatGPT.app не изменяется.",
                state: bridgeAvailable ? .success : .attention
            ) {
                EmptyView()
            }

            if model.chatGPTNeedsRestart {
                Label(
                    "ChatGPT уже открыт. После настройки потребуется подтвердить его перезапуск.",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: 680)
    }

    private var keymap: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(StarterKeymap.allCases) { starter in
                Button {
                    model.applyStarterKeymap(starter)
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: starter == .codexEssentials ? "command" : "square.dashed")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(
                                model.selectedStarterKeymap == starter
                                    ? NostromoTheme.accent
                                    : .secondary
                            )
                            .frame(width: 44, height: 44)
                            .background(
                                NostromoTheme.accent.opacity(
                                    model.selectedStarterKeymap == starter ? 0.13 : 0
                                ),
                                in: RoundedRectangle(cornerRadius: 12)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                                Text(starter.title)
                                    .font(.headline)
                            Text(starter.detail)
                                .font(.subheadline)
                                .foregroundStyle(NostromoTheme.mutedForeground)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer()

                        Image(
                            systemName: model.selectedStarterKeymap == starter
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.title3)
                        .foregroundStyle(
                            model.selectedStarterKeymap == starter
                                ? NostromoTheme.accent
                                : .secondary
                        )
                    }
                    .padding(NostromoSpace.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        model.selectedStarterKeymap == starter
                            ? NostromoTheme.selected
                            : NostromoTheme.surface,
                        in: RoundedRectangle(cornerRadius: NostromoRadius.large)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: NostromoRadius.large)
                            .strokeBorder(
                                model.selectedStarterKeymap == starter
                                    ? NostromoTheme.accent
                                    : Color.primary.opacity(0.10),
                                lineWidth: model.selectedStarterKeymap == starter ? 2 : 1
                            )
                    }
                }
                .buttonStyle(.plain)
                .help(starter.title)
                .accessibilityLabel(starter.title)
                .accessibilityValue(
                    model.selectedStarterKeymap == starter
                        ? "\(starter.detail). Выбрано"
                        : "\(starter.detail). Не выбрано"
                )
                .accessibilityHint("Выбирает стартовую раскладку «\(starter.title)»")
                .accessibilityAddTraits(
                    model.selectedStarterKeymap == starter ? .isSelected : []
                )
            }

            HStack {
                Button("Импортировать профиль…") {
                    model.importProfiles()
                }
                .buttonStyle(NostromoButtonStyle(variant: .outline))
                .accessibilityValue("Импортировать профиль")
                .accessibilityHint("Открывает выбор файла профилей JSON")
                Spacer()
                Text("Позже можно изменить любое назначение.")
                    .font(.caption)
                    .foregroundStyle(NostromoTheme.mutedForeground)
            }
        }
        .frame(maxWidth: 700)
    }

    private var inputTest: some View {
        VStack(spacing: 16) {
            HStack {
                Label("Проверка ввода активна", systemImage: "checkmark.shield.fill")
                    .font(.headline)
                    .foregroundStyle(NostromoTheme.success)
                Spacer()
                if let control = model.activeControls.first {
                    Text("Элемент \(control.title)")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Нажмите любой элемент")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            DeviceTwinView()
                .environmentObject(model)
                .frame(maxHeight: 430)

            Toggle("Запускать ChatGPT автоматически при старте Nostromo Codex", isOn: $autoLaunchChatGPT)
                .toggleStyle(.switch)
                .help("Запускать ChatGPT автоматически при старте Nostromo Codex")
                .accessibilityLabel("Запускать ChatGPT автоматически при старте Nostromo Codex")
                .accessibilityValue(autoLaunchChatGPT ? "Включено" : "Выключено")
        }
    }

    private var footer: some View {
        HStack {
            if model.setupPhase != .welcome {
                Button("Назад") {
                    guard let previous = SetupPhase(rawValue: model.setupPhase.rawValue - 1) else { return }
                    model.setupPhase = previous
                }
                .buttonStyle(NostromoButtonStyle(variant: .outline))
                .accessibilityValue("Назад")
            }

            Spacer()

            Button(primaryButtonTitle) {
                advance()
            }
            .buttonStyle(NostromoButtonStyle(variant: .primary))
            .accessibilityValue(primaryButtonTitle)
            .disabled(!canAdvance)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, NostromoSpace.xl)
        .padding(.vertical, NostromoSpace.md)
    }

    private var stepSubtitle: String {
        switch model.setupPhase {
        case .welcome: "Быстрая настройка для повседневной работы с Codex."
        case .connect: "Три проверки с понятным способом устранить проблему."
        case .keymap: "Начните с готовой или пустой раскладки."
        case .test: "Физический ввод виден, но назначенные действия заблокированы."
        }
    }

    private var primaryButtonTitle: String {
        model.setupPhase == .test ? "Завершить настройку" : "Продолжить"
    }

    private var canAdvance: Bool {
        switch model.setupPhase {
        case .connect:
            deviceConnected && model.compatibility.supported && bridgeAvailable
        default:
            true
        }
    }

    private var deviceConnected: Bool {
        if case .connected = model.deviceState { return true }
        return false
    }

    private var bridgeAvailable: Bool {
        switch model.bridgeStatus {
        case .listening, .connected: true
        case .stopped, .failed: false
        }
    }

    private var deviceStatusDetail: String {
        switch model.deviceState {
        case .stopped:
            return "Подключите устройство, затем разрешите мониторинг ввода."
        case .waitingForPermission:
            return "Мониторинг ввода всё ещё отключён в Системных настройках."
        case .disconnected:
            return "Доступ к вводу разрешён. Подключите USB-устройство."
        case let .connected(count, captureMode):
            let mode = captureMode == .exclusive
                ? "эксклюзивный захват"
                : "общий доступ"
            return "Подключено HID-интерфейсов: \(count), \(mode)."
        case let .error(message):
            return message
        }
    }

    private var chatGPTStatusDetail: String {
        if model.compatibility.supported {
            return "\(model.compatibility.version) (\(model.compatibility.build)) — проверено."
        }
        return model.compatibility.reason ?? "Установленная сборка не проверена."
    }

    private func shortTitle(_ phase: SetupPhase) -> String {
        switch phase {
        case .welcome: "Начало"
        case .connect: "Подключение"
        case .keymap: "Раскладка"
        case .test: "Проверка"
        }
    }

    private func stepFill(_ phase: SetupPhase) -> Color {
        phase.rawValue <= model.setupPhase.rawValue
            ? NostromoTheme.accent
            : Color.primary.opacity(0.08)
    }

    private func advance() {
        if model.setupPhase == .test {
            model.completeSetup(autoLaunch: autoLaunchChatGPT)
            return
        }
        guard let next = SetupPhase(rawValue: model.setupPhase.rawValue + 1) else { return }
        model.setupPhase = next
    }
}

private struct SetupBenefit: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(NostromoTheme.accent)
                .frame(width: 24)
        }
        .font(.callout.weight(.medium))
    }
}

private enum SetupStatusState {
    case success
    case attention
    case danger
}

private struct SetupStatusCard<Accessory: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let state: SetupStatusState
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            accessory()
        }
        .padding(NostromoSpace.md)
        .frame(maxWidth: .infinity)
        .background(NostromoTheme.surface, in: RoundedRectangle(cornerRadius: NostromoRadius.large))
        .overlay {
            RoundedRectangle(cornerRadius: NostromoRadius.large)
                .strokeBorder(NostromoTheme.border)
        }
    }

    private var tint: Color {
        switch state {
        case .success: NostromoTheme.success
        case .attention: NostromoTheme.signal
        case .danger: NostromoTheme.danger
        }
    }
}

private struct DecorativeDeviceTwin: View {
    var body: some View {
        ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: 34,
                bottomLeadingRadius: 90,
                bottomTrailingRadius: 48,
                topTrailingRadius: 94
            )
            .fill(
                LinearGradient(
                    colors: [NostromoTheme.raised, NostromoTheme.carbon],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .shadow(color: .black.opacity(0.3), radius: 24, y: 14)

            VStack(spacing: 9) {
                ForEach(0 ..< 3, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(0 ..< 5, id: \.self) { column in
                            let number = row * 5 + column + 1
                            RoundedRectangle(cornerRadius: 9)
                                .fill(number == 13 ? NostromoTheme.accent : NostromoTheme.keycap)
                                .frame(width: 48, height: 44)
                                .overlay {
                                    Text(String(format: "%02d", number))
                                        .font(.caption.monospaced().bold())
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                        }
                    }
                    .offset(x: CGFloat(row) * 5)
                }
            }
            .rotationEffect(.degrees(-5))
        }
        .padding(18)
        .accessibilityHidden(true)
    }
}
