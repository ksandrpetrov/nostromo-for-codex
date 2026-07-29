import NostromoCodexCore
import SwiftUI

struct LightingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NostromoSpace.lg) {
                header
                hardwarePreview

                HStack(alignment: .top, spacing: 16) {
                    keypadPanel
                    pressFeedbackPanel
                }
            }
            .frame(maxWidth: 920)
        }
    }

    private var header: some View {
        NostromoSectionHeader(
            "Подсветка",
            detail: "Настройте физический отклик, сохранив видимость текущего статуса Codex."
        )
    }

    private var hardwarePreview: some View {
        HStack(spacing: 28) {
            KeypadLightingPreview(
                brightness: Double(model.lightingResolution.appliedBrightness) / 255
            )

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ТЕКУЩЕЕ СОСТОЯНИЕ УСТРОЙСТВА")
                            .font(.caption2.monospaced().weight(.bold))
                            .tracking(1)
                            .foregroundStyle(.white.opacity(0.55))
                        Text(lightingSourceTitle)
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Text("\(model.lightingResolution.appliedBrightness) / 255")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }

                HStack(spacing: 22) {
                    HardwareLED(
                        title: "Красный",
                        color: NostromoTheme.danger,
                        active: model.lightingResolution.summary.red,
                        pulsing: false
                    )
                    HardwareLED(
                        title: "Зелёный",
                        color: NostromoTheme.success,
                        active: model.lightingResolution.summary.green,
                        pulsing: false
                    )
                    HardwareLED(
                        title: "Синий",
                        color: NostromoTheme.accent,
                        active: model.lightingResolution.summary.blue,
                        pulsing: false
                    )
                }

                Text("Синий — задача завершена; зелёный — задача выполняется; красный — требуется ваше действие.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(NostromoSpace.lg)
        .background(NostromoTheme.carbon, in: RoundedRectangle(cornerRadius: NostromoRadius.large))
        .overlay {
            RoundedRectangle(cornerRadius: NostromoRadius.large)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 18, y: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Текущее состояние подсветки Nostromo")
        .accessibilityValue(
            "\(lightingSourceTitle), яркость клавиш \(model.lightingResolution.appliedBrightness) из 255, "
                + activeIndicatorAccessibility
        )
    }

    private var keypadPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Подсветка клавиш")
                        .font(.headline)
                    Text("Единый предел для всех профилей")
                        .font(.caption)
                        .foregroundStyle(NostromoTheme.mutedForeground)
                }
                Spacer()
                Toggle(
                    "Подсветка клавиш",
                    isOn: Binding(
                        get: { model.configuration.lighting.keypadEnabled },
                        set: { model.setKeypadLightingEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .help("Подсветка клавиш")
                .accessibilityLabel("Подсветка клавиш")
                .accessibilityValue(
                    model.configuration.lighting.keypadEnabled ? "Включено" : "Выключено"
                )
                .accessibilityHint("Включает или выключает подсветку клавиш Nostromo")
            }

            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { model.configuration.lighting.maximumBrightness },
                        set: { model.setMaximumLightingBrightness($0) }
                    ),
                    in: 0 ... 1,
                    step: 0.01
                )
                .disabled(!model.configuration.lighting.keypadEnabled)
                .accessibilityLabel("Максимальная яркость клавиш")
                .accessibilityValue(maximumBrightnessText)

                Text(maximumBrightnessText)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .frame(width: 44, alignment: .trailing)
            }

            Text("Codex может уменьшить яркость ниже этого предела, но не превысит его.")
                .font(.caption)
                .foregroundStyle(NostromoTheme.mutedForeground)
        }
        .padding(NostromoSpace.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .nostromoPanel()
    }

    private var pressFeedbackPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Отклик на нажатие")
                        .font(.headline)
                    Text("Короткая вспышка клавиш")
                        .font(.caption)
                        .foregroundStyle(NostromoTheme.mutedForeground)
                }
                Spacer()
                Toggle(
                    "Отклик на нажатие",
                    isOn: Binding(
                        get: { model.configuration.lighting.pressFeedbackEnabled },
                        set: { model.setPressFeedbackEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .help("Отклик на нажатие")
                .accessibilityLabel("Отклик на нажатие")
                .accessibilityValue(
                    model.configuration.lighting.pressFeedbackEnabled ? "Включено" : "Выключено"
                )
                .accessibilityHint("Переключает короткую вспышку при физическом нажатии")
            }

            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { model.configuration.lighting.pressFeedbackStrength },
                        set: { model.setPressFeedbackStrength($0) }
                    ),
                    in: 0 ... 1,
                    step: 0.01
                )
                .disabled(
                    !model.configuration.lighting.keypadEnabled
                        || !model.configuration.lighting.pressFeedbackEnabled
                )
                .accessibilityLabel("Сила отклика на нажатие")
                .accessibilityValue(pressStrengthText)

                Text(pressStrengthText)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .frame(width: 44, alignment: .trailing)
            }

            HStack {
                Text("Яркость вспышки не превышает установленный предел.")
                    .font(.caption)
                    .foregroundStyle(NostromoTheme.mutedForeground)
                Spacer()
                Button("Проверить вспышку") {
                    model.testLightingFlash()
                }
                .buttonStyle(NostromoButtonStyle(variant: .outline, compact: true))
                .accessibilityValue("Проверить вспышку")
                .accessibilityHint("Кратко включает подсветку на подключённом Nostromo")
                .disabled(
                    !model.configuration.lighting.keypadEnabled
                        || !model.configuration.lighting.pressFeedbackEnabled
                )
            }
        }
        .padding(NostromoSpace.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .nostromoPanel()
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

    private var activeIndicatorAccessibility: String {
        let summary = model.lightingResolution.summary
        let names = [
            summary.red ? "красный включён" : nil,
            summary.green ? "зелёный включён" : nil,
            summary.blue ? "синий включён" : nil,
        ].compactMap { $0 }
        return names.isEmpty ? "все индикаторы задач выключены" : names.joined(separator: ", ")
    }

    private var maximumBrightnessText: String {
        "\(Int((model.configuration.lighting.maximumBrightness * 100).rounded()))%"
    }

    private var pressStrengthText: String {
        "\(Int((model.configuration.lighting.pressFeedbackStrength * 100).rounded()))%"
    }

}

private struct KeypadLightingPreview: View {
    let brightness: Double

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(24), spacing: 5), count: 5),
            spacing: 5
        ) {
            ForEach(0 ..< 15, id: \.self) { key in
                RoundedRectangle(cornerRadius: 5)
                    .fill(NostromoTheme.keycap)
                    .frame(width: 24, height: 19)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(NostromoTheme.accent.opacity(0.05 + (brightness * 0.30)))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(
                                NostromoTheme.accent.opacity(0.15 + (brightness * 0.55)),
                                lineWidth: 1
                            )
                    }
                    .shadow(
                        color: NostromoTheme.accent.opacity(brightness * 0.45),
                        radius: 4
                    )
                    .accessibilityHidden(true)
            }
        }
        .padding(14)
        .background(NostromoTheme.raised.opacity(0.58), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct HardwareLED: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let color: Color
    let active: Bool
    let pulsing: Bool

    var body: some View {
        HStack(spacing: 7) {
            if active, pulsing, !reduceMotion {
                indicator
                    .phaseAnimator([false, true]) { content, bright in
                        content
                            .opacity(bright ? 1 : 0.48)
                            .scaleEffect(bright ? 1 : 0.88)
                    } animation: { _ in
                        .easeInOut(duration: 0.9)
                    }
            } else {
                indicator
            }
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(active ? .white : .white.opacity(0.48))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Индикатор: \(title)")
        .accessibilityValue(
            active
                ? (pulsing ? "Пульсирует" : "Вкл.")
                : "Выкл."
        )
    }

    private var indicator: some View {
        Circle()
            .fill(active ? color : Color.white.opacity(0.08))
            .frame(width: 11, height: 11)
            .overlay {
                Circle()
                    .strokeBorder(
                        active ? color : Color.white.opacity(0.22),
                        lineWidth: 1
                    )
            }
            .shadow(color: active ? color.opacity(0.9) : .clear, radius: 5)
    }
}
