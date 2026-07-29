import NostromoCodexCore
import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable {
    case mappings
    case profiles
    case lighting
    case connection
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mappings: "Раскладка"
        case .profiles: "Профили"
        case .lighting: "Подсветка"
        case .connection: "Подключение"
        case .diagnostics: "Диагностика"
        }
    }

    var symbol: String {
        switch self {
        case .mappings: "keyboard"
        case .profiles: "square.stack.3d.up"
        case .lighting: "lightbulb"
        case .connection: "cable.connector"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            Group {
                if model.preferences.setupCompleted || model.hidOnlyMode {
                    dashboard(topInset: proxy.safeAreaInsets.top)
                } else {
                    SetupView()
                        .padding(.top, proxy.safeAreaInsets.top)
                        .background(NostromoTheme.background)
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .navigationTitle("Nostromo Codex")
        .nostromoScreen()
        .task { model.start() }
        .sheet(
            isPresented: Binding(
                get: { model.pendingImportedConfiguration != nil },
                set: { if !$0 { model.cancelProfilesImport() } }
            )
        ) {
            if let imported = model.pendingImportedConfiguration {
                ImportPreviewSheet(
                    name: model.pendingImportName ?? "Выбранный файл",
                    configuration: imported,
                    cancel: { model.cancelProfilesImport() },
                    confirm: { model.confirmProfilesImport() }
                )
                .frame(width: 480)
            }
        }
    }

    private func dashboard(topInset: CGFloat) -> some View {
        NavigationSplitView {
            sidebar
                .padding(.top, topInset)
                .background(NostromoTheme.elevated)
                .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 220)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.lastError {
                    ErrorBanner(message: error) {
                        model.clearError()
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                }

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.top, topInset)
            .background(NostromoTheme.background)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ReadinessPill(state: model.readiness)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: NostromoSpace.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: NostromoRadius.small, style: .continuous)
                        .fill(NostromoTheme.carbon)
                    Text("N")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Nostromo Codex")
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.activeProfile.name)
                        .font(.caption)
                        .foregroundStyle(NostromoTheme.mutedForeground)
                        .lineLimit(1)
                        .help(model.activeProfile.name)
                }
                Spacer()
            }
            .padding(.horizontal, NostromoSpace.md)
            .padding(.top, NostromoSpace.md)
            .padding(.bottom, NostromoSpace.lg)

            ScrollView {
                VStack(alignment: .leading, spacing: NostromoSpace.xxs) {
                    ForEach(DashboardSection.allCases.filter { $0 != .diagnostics }) { section in
                        SidebarButton(
                            section: section,
                            selected: model.dashboardSection == section
                        ) {
                            model.dashboardSection = section
                        }
                    }

                    NostromoEyebrow("Поддержка")
                        .padding(.horizontal, NostromoSpace.sm)
                        .padding(.top, NostromoSpace.lg)
                        .padding(.bottom, NostromoSpace.xxs)

                    SidebarButton(
                        section: .diagnostics,
                        selected: model.dashboardSection == .diagnostics
                    ) {
                        model.dashboardSection = .diagnostics
                    }
                }
                .padding(.horizontal, NostromoSpace.xs)
            }

            VStack(alignment: .leading, spacing: NostromoSpace.xs) {
                HStack(spacing: NostromoSpace.xs) {
                    Circle()
                        .fill(readinessColor)
                        .frame(width: 7, height: 7)
                    Text(model.readiness.title)
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                Text(model.readiness.detail)
                    .font(.caption)
                    .foregroundStyle(NostromoTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(NostromoSpace.sm)
            .background(NostromoTheme.hover, in: RoundedRectangle(cornerRadius: NostromoRadius.medium))
            .overlay {
                RoundedRectangle(cornerRadius: NostromoRadius.medium)
                    .strokeBorder(NostromoTheme.border)
            }
            .padding(NostromoSpace.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(NostromoTheme.elevated)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.dashboardSection {
        case .mappings:
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 16) {
                    DeviceMapView()
                        .frame(minWidth: 520, idealWidth: 700, maxWidth: 760)
                        .layoutPriority(1)
                    AssignmentInspector()
                        .frame(minWidth: 300, idealWidth: 320, maxWidth: 340)
                        .frame(height: 510, alignment: .top)
                }
                .frame(maxWidth: 1116, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(NostromoSpace.lg)
            }

        case .profiles:
            ProfilesView()
                .padding(NostromoSpace.lg)

        case .lighting:
            LightingView()
                .padding(NostromoSpace.lg)

        case .connection:
            ConnectionView()
                .padding(NostromoSpace.lg)

        case .diagnostics:
            DiagnosticsView()
                .padding(NostromoSpace.lg)
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
}

private struct ImportPreviewSheet: View {
    let name: String
    let configuration: AppConfiguration
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NostromoSpace.lg) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(NostromoTheme.accent)
                    .frame(width: 46, height: 46)
                    .background(NostromoTheme.selected, in: RoundedRectangle(cornerRadius: NostromoRadius.medium))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Заменить профили?")
                .font(.title3.weight(.semibold))
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Профили", value: "\(configuration.profiles.count)")
                LabeledContent(
                    "Назначения",
                    value: "\(configuration.profiles.reduce(0) { $0 + $1.bindings.values.filter { $0 != .none }.count })"
                )
                LabeledContent(
                    "Подсветка клавиатуры",
                    value: configuration.lighting.keypadEnabled
                        ? "До \(Int((configuration.lighting.maximumBrightness * 100).rounded()))%"
                        : "Выкл."
                )
            }
            .padding(NostromoSpace.md)
            .background(NostromoTheme.hover, in: RoundedRectangle(cornerRadius: NostromoRadius.medium))
            .overlay {
                RoundedRectangle(cornerRadius: NostromoRadius.medium)
                    .strokeBorder(NostromoTheme.border)
            }

            Label(
                "Перед заменой будет создана резервная копия текущей конфигурации.",
                systemImage: "externaldrive.badge.checkmark"
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Button("Отмена", action: cancel)
                    .buttonStyle(NostromoButtonStyle(variant: .outline))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Заменить профили", role: .destructive, action: confirm)
                    .buttonStyle(NostromoButtonStyle(variant: .destructive))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(NostromoSpace.lg)
        .nostromoScreen()
    }
}

struct ReadinessPill: View {
    let state: ReadinessState

    var body: some View {
        Label(state.title, systemImage: state.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .frame(height: NostromoControlHeight.compact)
            .background(tint.opacity(0.11), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(tint.opacity(0.18))
            }
            .accessibilityLabel("Статус: \(state.title)")
            .help(state.detail)
    }

    private var tint: Color {
        switch state {
        case .ready: NostromoTheme.success
        case .controllerOff: .secondary
        case .setupRequired, .permissionRequired, .deviceDisconnected, .launchChatGPT, .restartChatGPT:
            NostromoTheme.signal
        case .unsupportedChatGPT, .bridgeUnavailable:
            NostromoTheme.danger
        }
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(NostromoTheme.danger)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button("Закрыть", action: dismiss)
                .controlSize(.small)
        }
        .padding(NostromoSpace.sm)
        .background(NostromoTheme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: NostromoRadius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: NostromoRadius.medium)
                .strokeBorder(NostromoTheme.danger.opacity(0.28))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ошибка: \(message)")
    }
}

private struct SidebarButton: View {
    let section: DashboardSection
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NostromoSpace.sm) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? NostromoTheme.foreground : NostromoTheme.mutedForeground)
            .padding(.horizontal, NostromoSpace.sm)
            .frame(height: 34)
            .background(
                selected ? NostromoTheme.selected : .clear,
                in: RoundedRectangle(cornerRadius: NostromoRadius.small)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: NostromoRadius.small)
                        .strokeBorder(NostromoTheme.accent.opacity(0.16))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .help(section.title)
        .accessibilityLabel(section.title)
        .accessibilityValue(selected ? "\(section.title), выбранный раздел" : section.title)
        .accessibilityHint("Открывает раздел «\(section.title)»")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
