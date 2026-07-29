import NostromoCodexCore
import SwiftUI

struct DeviceMapView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showClearAssignmentsConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: NostromoSpace.md) {
            HStack(alignment: .center, spacing: 16) {
                NostromoSectionHeader(
                    "Раскладка",
                    detail: "Выберите физический элемент и назначьте ему действие."
                )

                Spacer()

                Picker("Профиль", selection: Binding(
                    get: { model.configuration.activeProfileID },
                    set: { model.activateProfile($0) }
                )) {
                    ForEach(model.configuration.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .frame(width: 190)
                .accessibilityHint("Изменяет активный профиль контроллера")

                Menu {
                    Button(
                        "Очистить все назначения…",
                        systemImage: "eraser",
                        role: .destructive
                    ) {
                        showClearAssignmentsConfirmation = true
                    }
                    .disabled(!activeProfileHasAssignments)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Действия раскладки профиля \(model.activeProfile.name)")
                .accessibilityLabel("Действия раскладки профиля \(model.activeProfile.name)")
                .accessibilityValue("Очистить все назначения")
            }

            DeviceTwinView()
                .environmentObject(model)
                .frame(maxWidth: .infinity)
                .frame(height: 350)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    runtimeLegends
                    Spacer()
                    inputTestLabel
                }

                VStack(alignment: .leading, spacing: 8) {
                    runtimeLegends
                    inputTestLabel
                }
            }
        }
        .padding(NostromoSpace.md)
        .nostromoPanel()
        .confirmationDialog(
            "Очистить все назначения профиля «\(model.activeProfile.name)»?",
            isPresented: $showClearAssignmentsConfirmation
        ) {
            Button("Очистить все назначения", role: .destructive) {
                model.clearActiveProfileBindings()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(
                "Кнопки, крестовина и нажатие колеса останутся без действий. "
                    + "После этого профиль можно настроить заново."
            )
        }
    }

    private var activeProfileHasAssignments: Bool {
        model.activeProfile.bindings.values.contains { $0 != .none }
    }

    @ViewBuilder
    private var runtimeLegends: some View {
        RuntimeLegend(
            symbol: model.wheelMode == .scroll ? "scroll" : "brain",
            title: "Колесо",
            value: model.wheelMode == .scroll ? "Прокрутка" : "Рассуждение"
        )
        RuntimeLegend(symbol: "hand.tap", title: "Удерживать и вращать", value: "Рассуждение")
        RuntimeLegend(symbol: "gearshape", title: "Удерживать 600 мс", value: "Подключение")
    }

    @ViewBuilder
    private var inputTestLabel: some View {
        if model.inputTestMode {
            Label("Проверка ввода — действия заблокированы", systemImage: "checkmark.shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(NostromoTheme.success)
        }
    }
}

struct DeviceTwinView: View {
    @EnvironmentObject private var model: AppModel

    private let upperRows: [[ControlID]] = [
        [.key01, .key02, .key03, .key04, .key05],
        [.key06, .key07, .key08, .key09, .key10],
    ]
    private let lowerRow: [ControlID] = [.key11, .key12, .key13, .key14]

    var body: some View {
        GeometryReader { proxy in
            let designWidth: CGFloat = 700
            let designHeight: CGFloat = 340
            let scale = min(
                1,
                proxy.size.width / designWidth,
                proxy.size.height / designHeight
            )

            ZStack {
                controllerBody
                    .frame(width: designWidth, height: designHeight)

                HStack(alignment: .center, spacing: 22) {
                    VStack(spacing: 10) {
                        ForEach(Array(upperRows.enumerated()), id: \.offset) { rowIndex, row in
                            HStack(spacing: 9) {
                                ForEach(row) { control in
                                    keypadKey(control)
                                }
                            }
                            .offset(x: CGFloat(rowIndex) * 7)
                        }

                        HStack(spacing: 9) {
                            ForEach(lowerRow) { control in
                                keypadKey(control)
                            }
                            WheelKey(
                                selected: model.selectedControl == .wheelPress,
                                pressed: model.activeControls.contains(.wheelPress)
                            ) {
                                model.selectedControl = .wheelPress
                            }
                            .frame(width: 72, height: 66)
                        }
                        .offset(x: 14)
                    }

                    thumbModule
                }
                .padding(22)
            }
            .frame(width: designWidth, height: designHeight)
            .scaleEffect(scale)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .clipped()
        }
        .frame(height: 350)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Схема контроллера Razer Nostromo")
    }

    private var controllerBody: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 38,
            bottomLeadingRadius: 86,
            bottomTrailingRadius: 54,
            topTrailingRadius: 94
        )
        .fill(
            LinearGradient(
                colors: [NostromoTheme.raised, NostromoTheme.carbon],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay {
            UnevenRoundedRectangle(
                topLeadingRadius: 38,
                bottomLeadingRadius: 86,
                bottomTrailingRadius: 54,
                topTrailingRadius: 94
            )
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.17), .black.opacity(0.48)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .shadow(color: .black.opacity(0.34), radius: 26, y: 15)
        .padding(8)
    }

    private var thumbModule: some View {
        VStack(spacing: 12) {
            PhysicalKey(
                control: .key16,
                summary: model.bindingSummary(for: .key16),
                compactSummary: model.compactBindingSummary(for: .key16),
                selected: model.selectedControl == .key16,
                pressed: model.activeControls.contains(.key16),
                taskColor: taskColor(for: .key16)
            ) {
                model.selectedControl = .key16
            }

            DPadKey()
                .environmentObject(model)

            PhysicalKey(
                control: .key15,
                summary: model.bindingSummary(for: .key15),
                compactSummary: model.compactBindingSummary(for: .key15),
                selected: model.selectedControl == .key15,
                pressed: model.activeControls.contains(.key15),
                taskColor: taskColor(for: .key15),
                wide: true
            ) {
                model.selectedControl = .key15
            }
        }
        .padding(.vertical, 8)
        .frame(width: 158)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 42, style: .continuous))
    }

    private func keypadKey(_ control: ControlID) -> some View {
        PhysicalKey(
            control: control,
            summary: model.bindingSummary(for: control),
            compactSummary: model.compactBindingSummary(for: control),
            selected: model.selectedControl == control,
            pressed: model.activeControls.contains(control),
            taskColor: taskColor(for: control)
        ) {
            model.selectedControl = control
        }
    }

    private func taskColor(for control: ControlID) -> Color? {
        guard
            case let .taskSlot(slot) = model.activeProfile.bindings[control]
        else {
            return nil
        }
        if let task = model.taskSlot(slot) {
            guard let rgbValue = task.status.rgbValue else { return nil }
            return Color(rgbValue: rgbValue)
        }
        guard
            let thread = model.lighting.threads.first(where: { $0.id == slot }),
            thread.brightness > 0
        else {
            return nil
        }
        return Color(rgbValue: thread.color)
    }
}

private struct PhysicalKey: View {
    let control: ControlID
    let summary: String
    let compactSummary: String
    let selected: Bool
    let pressed: Bool
    let taskColor: Color?
    var wide = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(control.title)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    Spacer()
                    if let taskColor {
                        Circle()
                            .fill(taskColor)
                            .frame(width: 7, height: 7)
                            .shadow(color: taskColor.opacity(0.8), radius: 4)
                    } else if pressed {
                        Circle()
                            .fill(.white)
                            .frame(width: 7, height: 7)
                    }
                }

                Text(compactSummary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selected || pressed ? .white : .white.opacity(0.64))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(width: wide ? 126 : 72, height: wide ? 54 : 66, alignment: .topLeading)
            .background(background, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(border, lineWidth: selected || pressed ? 2 : 1)
            }
            .shadow(
                color: pressed ? NostromoTheme.accent.opacity(0.55) : .black.opacity(0.30),
                radius: pressed ? 12 : 5,
                y: pressed ? 0 : 4
            )
            .offset(y: pressed ? 2 : 0)
        }
        .buttonStyle(.plain)
        .help("\(control.title): \(summary)")
        .accessibilityLabel("Элемент управления \(control.title)")
        .accessibilityValue(summary)
        .accessibilityHint("Выбирает этот физический элемент управления для редактирования")
    }

    private var background: Color {
        if pressed { return NostromoTheme.accent }
        if selected { return NostromoTheme.accent.opacity(0.58) }
        return NostromoTheme.keycap
    }

    private var border: Color {
        if pressed { return .white.opacity(0.85) }
        if selected { return NostromoTheme.accent }
        return .white.opacity(0.10)
    }
}

private struct WheelKey: View {
    let selected: Bool
    let pressed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(pressed ? NostromoTheme.accent : NostromoTheme.keycap)
                    Circle()
                        .strokeBorder(
                            selected || pressed ? NostromoTheme.accent : .white.opacity(0.12),
                            lineWidth: selected || pressed ? 2 : 1
                        )
                    ForEach(0 ..< 8, id: \.self) { index in
                        Capsule()
                            .fill(.white.opacity(0.34))
                            .frame(width: 3, height: 19)
                            .offset(y: -13)
                            .rotationEffect(.degrees(Double(index) * 45))
                    }
                    Circle()
                        .fill(pressed ? .white : NostromoTheme.accent)
                        .frame(width: 10, height: 10)
                }
                .frame(width: 55, height: 55)

                Text("КОЛЕСО")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.66))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Колесо")
        .accessibilityValue("Прокрутка или рассуждение")
        .accessibilityHint("Выбирает описание жестов колеса")
    }
}

private struct DPadKey: View {
    @EnvironmentObject private var model: AppModel

    private let placements: [(ControlID, CGFloat, CGFloat)] = [
        (.dpadUp, 0, -39), (.dpadUpRight, 28, -28),
        (.dpadRight, 39, 0), (.dpadDownRight, 28, 28),
        (.dpadDown, 0, 39), (.dpadDownLeft, -28, 28),
        (.dpadLeft, -39, 0), (.dpadUpLeft, -28, -28),
    ]

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.26))
                .frame(width: 128, height: 128)

            ForEach(placements, id: \.0) { control, x, y in
                let selected = model.selectedControl == control
                let pressed = model.activeControls.contains(control)

                Button {
                    model.selectedControl = control
                } label: {
                    Text(control.title)
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(.white)
                        .background(
                            pressed
                                ? NostromoTheme.accent
                                : selected
                                    ? NostromoTheme.accent.opacity(0.48)
                                    : NostromoTheme.keycap,
                            in: Circle()
                        )
                        .overlay {
                            Circle().strokeBorder(
                                selected || pressed ? NostromoTheme.accent : .white.opacity(0.1),
                                lineWidth: selected || pressed ? 2 : 1
                            )
                        }
                }
                .buttonStyle(.plain)
                .offset(x: x, y: y)
                .help("\(control.title): \(model.bindingSummary(for: control))")
                .accessibilityLabel("Крестовина \(control.title)")
                .accessibilityValue(model.bindingSummary(for: control))
            }

            Circle()
                .fill(NostromoTheme.carbon)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "scope").foregroundStyle(.white.opacity(0.45)))
        }
        .frame(width: 132, height: 132)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Восьмипозиционная крестовина")
    }
}

private struct RuntimeLegend: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(NostromoTheme.accent)
            Text(title)
                .foregroundStyle(NostromoTheme.mutedForeground)
            Text(value)
                .fontWeight(.medium)
        }
        .font(.caption)
    }
}

extension Color {
    fileprivate init(rgbValue: Int) {
        self.init(
            red: Double((rgbValue >> 16) & 0xFF) / 255,
            green: Double((rgbValue >> 8) & 0xFF) / 255,
            blue: Double(rgbValue & 0xFF) / 255
        )
    }
}
