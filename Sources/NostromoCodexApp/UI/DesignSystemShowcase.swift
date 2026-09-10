import SwiftUI

/// A side-effect-free catalog used by Xcode previews and rendering smoke tests.
/// It deliberately has no AppModel dependency, so opening it cannot touch HID
/// devices or launch ChatGPT.
struct NostromoDesignSystemShowcase: View {
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(width: 920, height: 620)
        .nostromoScreen()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: NostromoSpace.lg) {
            HStack(spacing: NostromoSpace.sm) {
                RoundedRectangle(cornerRadius: NostromoRadius.small)
                    .fill(NostromoTheme.carbon)
                    .frame(width: 32, height: 32)
                    .overlay {
                        Text("N")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                Text("Nostromo Codex")
                    .font(.system(size: 13, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: NostromoSpace.xxs) {
                previewNavigation("Раскладка", symbol: "keyboard", selected: true)
                previewNavigation("Профили", symbol: "square.stack.3d.up")
                previewNavigation("Подсветка", symbol: "lightbulb")
                previewNavigation("Подключение", symbol: "cable.connector")
            }

            Spacer()

            VStack(alignment: .leading, spacing: NostromoSpace.xs) {
                StatusPill(title: "Готово", color: NostromoTheme.success)
                Text("Nostromo подключён к Codex.")
                    .font(.caption)
                    .foregroundStyle(NostromoTheme.mutedForeground)
            }
            .padding(NostromoSpace.sm)
            .nostromoSurface(.elevated)
        }
        .padding(NostromoSpace.md)
        .frame(width: 210)
        .background(NostromoTheme.elevated)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NostromoSpace.lg) {
                NostromoSectionHeader(
                    "Раскладка",
                    detail: "Нативные компоненты, собранные из одной семантической системы."
                )

                HStack(alignment: .top, spacing: NostromoSpace.md) {
                    hardwareCard
                    componentCard
                }

                statusCard
            }
            .padding(NostromoSpace.lg)
        }
    }

    private var hardwareCard: some View {
        VStack(alignment: .leading, spacing: NostromoSpace.md) {
            Text("DIGITAL TWIN")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.58))

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(62), spacing: 8), count: 4),
                spacing: 8
            ) {
                ForEach(1 ... 12, id: \.self) { key in
                    RoundedRectangle(cornerRadius: NostromoRadius.small)
                        .fill(key == 7 ? NostromoTheme.accent.opacity(0.65) : NostromoTheme.keycap)
                        .frame(width: 62, height: 52)
                        .overlay(alignment: .topLeading) {
                            Text(String(format: "%02d", key))
                                .font(.caption.monospaced().bold())
                                .foregroundStyle(.white.opacity(0.82))
                                .padding(8)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: NostromoRadius.small)
                                .strokeBorder(
                                    key == 7 ? NostromoTheme.accent : .white.opacity(0.10),
                                    lineWidth: key == 7 ? 2 : 1
                                )
                        }
                }
            }
        }
        .padding(NostromoSpace.lg)
        .background(NostromoTheme.carbon)
        .clipShape(RoundedRectangle(cornerRadius: NostromoRadius.large))
        .overlay {
            RoundedRectangle(cornerRadius: NostromoRadius.large)
                .strokeBorder(Color.white.opacity(0.10))
        }
        .frame(maxWidth: .infinity)
    }

    private var componentCard: some View {
        NostromoCard(padding: NostromoSpace.lg) {
            VStack(alignment: .leading, spacing: NostromoSpace.md) {
                NostromoEyebrow("Компоненты")

                NostromoField("Название профиля", detail: "Изменения сохраняются автоматически.") {
                    TextField("Название", text: .constant("Основной"))
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button("Сохранить") {}
                        .buttonStyle(NostromoButtonStyle(variant: .primary))
                    Button("Отмена") {}
                        .buttonStyle(NostromoButtonStyle(variant: .outline))
                }

                HStack {
                    StatusPill(title: "Активно", color: NostromoTheme.success)
                    NostromoKbd(value: "⌘ K")
                }
            }
        }
        .frame(width: 300)
    }

    private var statusCard: some View {
        NostromoCard {
            NostromoItem {
                Image(systemName: "lock.shield")
                    .foregroundStyle(NostromoTheme.success)
                    .frame(width: 34, height: 34)
                    .background(
                        NostromoTheme.success.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: NostromoRadius.small)
                    )
            } content: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Приватное подключение")
                        .font(.callout.weight(.semibold))
                    Text("Защищённый локальный сокет · ChatGPT.app не изменяется")
                        .font(.caption)
                        .foregroundStyle(NostromoTheme.mutedForeground)
                }
            } trailing: {
                StatusPill(title: "Подключено", color: NostromoTheme.success)
            }
        }
    }

    private func previewNavigation(
        _ title: String,
        symbol: String,
        selected: Bool = false
    ) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? NostromoTheme.foreground : NostromoTheme.mutedForeground)
            .padding(.horizontal, NostromoSpace.sm)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(
                selected ? NostromoTheme.selected : .clear,
                in: RoundedRectangle(cornerRadius: NostromoRadius.small)
            )
    }
}

#if DEBUG
// SwiftPM builds must not depend on Xcode's PreviewsMacros plugin.
struct NostromoDesignSystemShowcase_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            NostromoDesignSystemShowcase()
                .environment(\.colorScheme, .light)
                .previewDisplayName("Design system — Light")
            NostromoDesignSystemShowcase()
                .environment(\.colorScheme, .dark)
                .previewDisplayName("Design system — Dark")
        }
    }
}
#endif
