import NostromoCodexCore
import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var profileName = ""
    @State private var profilePendingDeletion: ControllerProfile?
    @State private var recentlyDeletedProfile: ControllerProfile?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NostromoSpace.lg) {
                HStack(alignment: .firstTextBaseline) {
                    NostromoSectionHeader(
                        "Профили",
                        detail: "Переключайте контексты без перенастройки контроллера."
                    )

                    Spacer()

                    Button {
                        model.addProfile()
                        profileName = model.activeProfile.name
                    } label: {
                        Label("Новый профиль", systemImage: "plus")
                    }
                    .buttonStyle(NostromoButtonStyle(variant: .primary))
                    .accessibilityValue("Новый профиль")
                    .accessibilityHint("Создаёт новый профиль и делает его активным")
                }

                if let recentlyDeletedProfile {
                    HStack(spacing: 12) {
                        Image(systemName: "trash")
                            .foregroundStyle(NostromoTheme.signal)
                        Text("Профиль «\(recentlyDeletedProfile.name)» удалён.")
                        Spacer()
                        Button("Отменить") {
                            model.restoreProfile(recentlyDeletedProfile)
                            self.recentlyDeletedProfile = nil
                        }
                        .buttonStyle(NostromoButtonStyle(variant: .ghost, compact: true))
                        .accessibilityValue("Отменить удаление профиля")
                    }
                    .font(.callout)
                    .padding(NostromoSpace.sm)
                    .background(NostromoTheme.signal.opacity(0.10), in: RoundedRectangle(cornerRadius: NostromoRadius.medium))
                    .overlay {
                        RoundedRectangle(cornerRadius: NostromoRadius.medium)
                            .strokeBorder(NostromoTheme.signal.opacity(0.20))
                    }
                }

                HStack(alignment: .top, spacing: 18) {
                    profileList
                        .frame(width: 270)
                    profileEditor
                        .frame(maxWidth: .infinity)
                }

                transferPanel
            }
            .frame(maxWidth: 920)
        }
        .onAppear {
            profileName = model.activeProfile.name
        }
        .onChange(of: model.configuration.activeProfileID) {
            profileName = model.activeProfile.name
        }
        .confirmationDialog(
            "Удалить профиль «\(profilePendingDeletion?.name ?? "")»?",
            isPresented: Binding(
                get: { profilePendingDeletion != nil },
                set: { if !$0 { profilePendingDeletion = nil } }
            )
        ) {
            Button("Удалить профиль", role: .destructive) {
                guard let profile = profilePendingDeletion else { return }
                recentlyDeletedProfile = profile
                model.deleteActiveProfile()
                profilePendingDeletion = nil
                profileName = model.activeProfile.name
            }
            Button("Отмена", role: .cancel) {
                profilePendingDeletion = nil
            }
        } message: {
            Text("Все его назначения будут удалены. Сразу после удаления действие можно отменить.")
        }
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: NostromoSpace.xs) {
            NostromoEyebrow("Профили")
                .padding(.horizontal, 8)

            ForEach(model.configuration.profiles) { profile in
                Button {
                    model.activateProfile(profile.id)
                } label: {
                    HStack(spacing: 11) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text("Назначено: \(assignedCount(profile))")
                                .font(.caption)
                                .foregroundStyle(NostromoTheme.mutedForeground)
                        }
                        Spacer()
                        if profile.id == model.configuration.activeProfileID {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(NostromoTheme.accent)
                        }
                    }
                    .padding(11)
                    .background(
                        profile.id == model.configuration.activeProfileID
                            ? NostromoTheme.selected
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: NostromoRadius.small)
                    )
                }
                .buttonStyle(.plain)
                .help(profile.name)
                .accessibilityLabel(profile.name)
                .accessibilityValue(
                    profile.id == model.configuration.activeProfileID
                        ? "Активный профиль"
                        : "Неактивный профиль"
                )
            }
        }
        .padding(12)
        .nostromoPanel()
    }

    private var profileEditor: some View {
        VStack(alignment: .leading, spacing: NostromoSpace.md) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.activeProfile.name)
                        .font(.title3.weight(.semibold))
                    Text("Сейчас активен · изменения сохраняются автоматически")
                        .font(.caption)
                        .foregroundStyle(NostromoTheme.mutedForeground)
                }
                Spacer()
                Menu {
                    Button("Дублировать", systemImage: "plus.square.on.square") {
                        model.duplicateActiveProfile()
                        profileName = model.activeProfile.name
                    }
                    Divider()
                    Button("Удалить", systemImage: "trash", role: .destructive) {
                        profilePendingDeletion = model.activeProfile
                    }
                    .disabled(model.configuration.profiles.count == 1)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Действия профиля \(model.activeProfile.name)")
                .accessibilityLabel("Действия профиля \(model.activeProfile.name)")
                .accessibilityValue("Дублировать или удалить профиль")
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                NostromoEyebrow("Название")
                HStack {
                    TextField("Название профиля", text: $profileName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.renameActiveProfile(profileName) }
                    Button("Переименовать") {
                        model.renameActiveProfile(profileName)
                        profileName = model.activeProfile.name
                    }
                    .buttonStyle(NostromoButtonStyle(variant: .outline))
                    .accessibilityValue("Переименовать профиль")
                    .disabled(
                        profileName.trimmingCharacters(in: .whitespacesAndNewlines)
                            == model.activeProfile.name
                    )
                }
            }

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: 12
            ) {
                ProfileMetric(title: "Назначено", value: "\(assignedCount(model.activeProfile))")
                ProfileMetric(
                    title: "Codex",
                    value: "\(count(kind: .codexAction, in: model.activeProfile))"
                )
                ProfileMetric(
                    title: "Другие приложения",
                    value: "\(count(kind: .shortcut, in: model.activeProfile))"
                )
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(NostromoTheme.signal)
                Text(
                    "Создайте отдельный профиль для другого приложения и переключайтесь на него "
                        + "через строку меню или физическое назначение профиля."
                )
                .font(.callout)
                .foregroundStyle(NostromoTheme.mutedForeground)
            }
            .padding(NostromoSpace.sm)
            .background(NostromoTheme.hover, in: RoundedRectangle(cornerRadius: NostromoRadius.medium))
        }
        .padding(NostromoSpace.lg)
        .nostromoPanel()
    }

    private var transferPanel: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.up.arrow.down.square")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(NostromoTheme.accent)
                .frame(width: 42, height: 42)
                .background(NostromoTheme.selected, in: RoundedRectangle(cornerRadius: NostromoRadius.medium))

            VStack(alignment: .leading, spacing: 3) {
                Text("Безопасный перенос профилей")
                    .font(.headline)
                Text("Перед заменой конфигурации импорт покажет сводку и создаст резервную копию.")
                    .font(.caption)
                    .foregroundStyle(NostromoTheme.mutedForeground)
            }

            Spacer()

            Button("Экспортировать…") {
                model.exportProfiles()
            }
            .buttonStyle(NostromoButtonStyle(variant: .outline))
            .accessibilityValue("Экспортировать профили")
            .accessibilityHint("Открывает панель сохранения JSON")
            Button("Импортировать…") {
                model.chooseProfilesForImport()
            }
            .buttonStyle(NostromoButtonStyle(variant: .secondary))
            .accessibilityValue("Импортировать профили")
            .accessibilityHint("Открывает выбор JSON и показывает сводку перед заменой")
        }
        .padding(NostromoSpace.md)
        .nostromoPanel()
    }

    private func assignedCount(_ profile: ControllerProfile) -> Int {
        profile.bindings.values.filter { $0 != .none }.count
    }

    private func count(kind: BindingKind, in profile: ControllerProfile) -> Int {
        profile.bindings.values.filter { $0.kind == kind }.count
    }

}

private struct ProfileMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title2.monospacedDigit().weight(.semibold))
            Text(title)
                .font(.caption)
                .foregroundStyle(NostromoTheme.mutedForeground)
        }
        .padding(NostromoSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NostromoTheme.hover, in: RoundedRectangle(cornerRadius: NostromoRadius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: NostromoRadius.medium)
                .strokeBorder(NostromoTheme.border)
        }
    }
}
