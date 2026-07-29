import NostromoCodexCore
import SwiftUI

struct AssignmentInspector: View {
    @EnvironmentObject private var model: AppModel
    @State private var showActionLibrary = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NostromoSpace.md) {
                HStack(alignment: .center, spacing: 12) {
                    controlBadge

                    VStack(alignment: .leading, spacing: 3) {
                        Text(controlTitle)
                            .font(.headline)
                        Text(model.bindingSummary(for: model.selectedControl))
                            .font(.caption)
                            .foregroundStyle(NostromoTheme.mutedForeground)
                            .lineLimit(2)
                    }
                    Spacer()
                }

                Divider()

                if model.selectedControl == .wheelPress {
                    wheelExplanation
                } else {
                    Button {
                        showActionLibrary = true
                    } label: {
                        HStack {
                            Image(systemName: "square.grid.2x2")
                                .foregroundStyle(NostromoTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Выбрать действие")
                                    .font(.callout.weight(.semibold))
                                Text(actionKindLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                        .padding(NostromoSpace.sm)
                        .background(NostromoTheme.hover, in: RoundedRectangle(cornerRadius: NostromoRadius.medium))
                        .overlay {
                            RoundedRectangle(cornerRadius: NostromoRadius.medium)
                                .strokeBorder(NostromoTheme.border)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Выбрать действие")
                    .accessibilityValue("Текущий тип: \(actionKindLabel)")
                    .accessibilityHint("Открывает библиотеку действий с поиском")

                    editor

                    if model.selectedBinding != .none {
                        Divider()
                        Button(role: .destructive) {
                            model.setBinding(.none)
                        } label: {
                            Label("Отключить этот элемент", systemImage: "xmark.circle")
                        }
                    }
                }

                Divider()

                Toggle(
                    "Проверка ввода",
                    isOn: Binding(
                        get: { model.inputTestMode },
                        set: { model.setInputTestMode($0) }
                    )
                )
                .toggleStyle(.switch)
                .help("Проверка ввода")
                .accessibilityLabel("Проверка ввода")
                .accessibilityValue(model.inputTestMode ? "Включено" : "Выключено")
                .accessibilityHint("Проверяет физический ввод без выполнения назначения")

                Text(
                    model.inputTestMode
                        ? "Физический ввод подсвечивается. Назначения не выполняются."
                        : "Проверка ввода позволяет проверить физический элемент без выполнения его назначения."
                )
                .font(.caption)
                .foregroundStyle(model.inputTestMode ? NostromoTheme.success : .secondary)
            }
            .padding(NostromoSpace.md)
        }
        .nostromoPanel()
        .sheet(isPresented: $showActionLibrary) {
            ActionLibraryView {
                showActionLibrary = false
            }
            .environmentObject(model)
            .frame(minWidth: 620, minHeight: 570)
        }
    }

    private var controlTitle: String {
        if ControlID.dpad.contains(model.selectedControl) {
            return "Крестовина \(model.selectedControl.title)"
        }
        if model.selectedControl == .wheelPress {
            return "Колесо"
        }
        return "Элемент \(model.selectedControl.title)"
    }

    private var controlBadge: some View {
        Group {
            if model.selectedControl == .wheelPress {
                Image(systemName: "scroll")
                    .font(.system(size: 20, weight: .semibold))
            } else {
                Text(model.selectedControl.title)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 48, height: 48)
        .background(
            model.activeControls.contains(model.selectedControl)
                ? NostromoTheme.accent
                : NostromoTheme.keycap,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    model.activeControls.contains(model.selectedControl)
                        ? Color.white.opacity(0.8)
                        : Color.white.opacity(0.1)
                )
        }
    }

    private var actionKindLabel: String {
        switch model.selectedBinding.kind {
        case .taskSlot: "Задача"
        case .codexAction: "Codex"
        case .skill: "Навык"
        case .pluginPrompt: "Запрос к плагину"
        case .shortcut: "Сочетание клавиш"
        case .profileSwitch: "Профиль"
        case .none: "Действие не назначено"
        }
    }

    private var wheelExplanation: some View {
        VStack(alignment: .leading, spacing: 13) {
            InspectorSectionTitle("Фиксированные жесты")
            GestureRow(symbol: "scroll", title: "Вращать", detail: "Прокручивать активную задачу")
            GestureRow(symbol: "brain", title: "Удерживать и вращать", detail: "Изменять глубину рассуждения")
            GestureRow(symbol: "arrow.triangle.2.circlepath", title: "Нажать", detail: "Прокрутка ↔ Рассуждение")
            GestureRow(symbol: "gearshape", title: "Удерживать 600 мс", detail: "Открыть раздел «Подключение»")

            Text("Все жесты колеса связаны и не могут назначаться по отдельности.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch model.selectedBinding {
        case let .taskSlot(slot):
            VStack(alignment: .leading, spacing: 10) {
                InspectorSectionTitle("Задача")
                Picker("Задача", selection: Binding(
                    get: { slot },
                    set: { model.setBinding(.taskSlot($0)) }
                )) {
                    ForEach(0 ..< 6, id: \.self) { value in
                        Text("\(value + 1)").tag(value)
                    }
                }
                .pickerStyle(.segmented)
                if let task = model.taskSlot(slot) {
                    Text(taskSlotDescription(task))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        "Слот \(slot + 1) заполнит Codex. Состав слотов зависит "
                            + "от выбранного там источника задач."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case let .codexAction(id):
            VStack(alignment: .leading, spacing: 10) {
                InspectorSectionTitle("Действие Codex")
                if let action = CodexActionCatalog.descriptor(for: id) {
                    HStack {
                        Text(action.title)
                            .font(.headline)
                        Spacer()
                        Text(action.category.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(action.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if action.consequential {
                        Label(
                            "Выполняется сразу после нажатия физического элемента.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(NostromoTheme.signal)
                        .padding(10)
                        .background(NostromoTheme.signal.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                    }
                } else {
                    Label("Это действие отсутствует в проверенном каталоге.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(NostromoTheme.signal)
                }
            }

        case let .skill(skill):
            VStack(alignment: .leading, spacing: 10) {
                InspectorSectionTitle("Навык")
                Picker("Навык", selection: Binding(
                    get: { skill.id },
                    set: { id in
                        guard let selected = model.skills.first(where: { $0.id == id }) else { return }
                        model.setBinding(.skill(selected))
                    }
                )) {
                    if !model.skills.contains(where: { $0.id == skill.id }) {
                        Text("\(skill.displayName) — недоступен").tag(skill.id)
                    }
                    ForEach(model.skills) { item in
                        Text(item.displayName).tag(item.id)
                    }
                }
                HStack {
                    Text("Локальных навыков: \(model.skills.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Обновить") { model.refreshSkills() }
                        .controlSize(.small)
                }
            }

        case let .pluginPrompt(plugin):
            VStack(alignment: .leading, spacing: 10) {
                InspectorSectionTitle("Запрос к плагину")
                TextField("Название плагина", text: pluginBinding(plugin, \.displayName))
                TextField("plugin://stable-uri", text: pluginBinding(plugin, \.uri))
                    .textContentType(.URL)
                TextEditor(text: pluginBinding(plugin, \.template))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 90)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel("Шаблон запроса к плагину")
                    .accessibilityHint("Текст будет вставлен в ChatGPT без автоматической отправки")
                Text("Подготавливает упоминание и текст в поле ввода, но не отправляет их автоматически.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case let .shortcut(shortcut):
            VStack(alignment: .leading, spacing: 10) {
                InspectorSectionTitle("Сочетание клавиш")
                ShortcutRecorderField(
                    shortcut: Binding(
                        get: { shortcut },
                        set: { model.setBinding(.shortcut($0)) }
                    )
                )
                HStack {
                    Text("macOS отправляет это сочетание активному приложению.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !model.shortcutPermissionGranted {
                        Button("Разрешить универсальный доступ") {
                            model.requestShortcutPermission()
                        }
                        .controlSize(.small)
                    }
                }
            }

        case let .profileSwitch(profileID, behavior):
            VStack(alignment: .leading, spacing: 10) {
                InspectorSectionTitle("Профиль")
                Picker("Профиль", selection: Binding(
                    get: { profileID },
                    set: { model.setBinding(.profileSwitch(profileID: $0, behavior: behavior)) }
                )) {
                    Text("Следующий профиль").tag(UUID?.none)
                    ForEach(model.configuration.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                Picker("Поведение", selection: Binding(
                    get: { behavior },
                    set: { model.setBinding(.profileSwitch(profileID: profileID, behavior: $0)) }
                )) {
                    Text("Переключить").tag(ProfileSwitchBehavior.toggle)
                    Text("Пока удерживается").tag(ProfileSwitchBehavior.momentary)
                }
                .pickerStyle(.segmented)
            }

        case .none:
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text("Нет действия")
                    .font(.headline)
                Text("Этот физический элемент отключён в активном профиле.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func pluginBinding(
        _ value: PluginPrompt,
        _ keyPath: WritableKeyPath<PluginPrompt, String>
    ) -> Binding<String> {
        Binding(
            get: { value[keyPath: keyPath] },
            set: { newValue in
                var copy = value
                copy[keyPath: keyPath] = newValue
                model.setBinding(.pluginPrompt(copy))
            }
        )
    }

    private func taskSlotDescription(_ task: CodexTaskSlot) -> String {
        let title = task.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title?.isEmpty == false ? title ?? "Без названия" : "Без названия"
        return "\(name) · \(task.status.title)"
    }
}

private struct ActionLibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if matchesTaskSlots {
                    Section("Задачи") {
                        ForEach(0 ..< 6, id: \.self) { slot in
                            ActionChoiceRow(
                                symbol: "\(slot + 1).circle",
                                title: taskSlotChoiceTitle(slot),
                                detail: taskSlotChoiceDetail(slot)
                            ) {
                                choose(.taskSlot(slot))
                            }
                        }
                    }
                }

                ForEach(CodexActionDescriptor.Category.allCases, id: \.self) { category in
                    let actions = filteredActions(in: category)
                    if !actions.isEmpty {
                        Section(category.rawValue) {
                            ForEach(actions) { action in
                                ActionChoiceRow(
                                    symbol: symbol(for: action.category),
                                    title: action.title,
                                    detail: action.detail,
                                    available: action.available
                                ) {
                                    choose(.codexAction(action.id))
                                }
                            }
                        }
                    }
                }

                let matchingSkills = model.skills.filter {
                    search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)
                }
                if !matchingSkills.isEmpty {
                    Section("Навыки") {
                        ForEach(matchingSkills) { skill in
                            ActionChoiceRow(
                                symbol: "wand.and.stars",
                                title: skill.displayName,
                                detail: "Вставить упоминание навыка"
                            ) {
                                choose(.skill(skill))
                            }
                        }
                    }
                }

                if matches("Плагин запрос сочетание клавиш профиль отключить элемент") {
                    Section("Пользовательские и системные") {
                        ActionChoiceRow(
                            symbol: "puzzlepiece.extension",
                            title: "Запрос к плагину",
                            detail: "Подготовить упоминание плагина и сохранённый текст"
                        ) {
                            choose(
                                .pluginPrompt(
                                    PluginPrompt(uri: "plugin://", displayName: "Плагин")
                                )
                            )
                        }
                        ActionChoiceRow(
                            symbol: "keyboard",
                            title: "Сочетание клавиш",
                            detail: "Управлять другим приложением macOS"
                        ) {
                            choose(.shortcut(ShortcutBinding(configured: false)))
                        }
                        ActionChoiceRow(
                            symbol: "square.stack.3d.up",
                            title: "Сменить профиль",
                            detail: "Переключить постоянно или на время удержания"
                        ) {
                            choose(.profileSwitch(profileID: nil, behavior: .toggle))
                        }
                        ActionChoiceRow(
                            symbol: "circle.slash",
                            title: "Отключить элемент",
                            detail: "Не выполнять ничего при нажатии этого элемента"
                        ) {
                            choose(.none)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Поиск действий")
            .listStyle(.inset)
            .overlay {
                if !hasSearchResults {
                    ContentUnavailableView.search(text: search)
                }
            }
            .navigationTitle("Выбор действия")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена", action: dismiss)
                }
            }
        }
        .nostromoScreen()
    }

    private var hasSearchResults: Bool {
        if search.isEmpty || matchesTaskSlots {
            return true
        }
        if CodexActionDescriptor.Category.allCases.contains(where: {
            !filteredActions(in: $0).isEmpty
        }) {
            return true
        }
        if model.skills.contains(where: {
            $0.displayName.localizedCaseInsensitiveContains(search)
        }) {
            return true
        }
        return matches("Плагин запрос сочетание клавиш профиль отключить элемент")
    }

    private func filteredActions(
        in category: CodexActionDescriptor.Category
    ) -> [CodexActionDescriptor] {
        model.actionCatalog.filter {
            $0.category == category
                && (
                    search.isEmpty
                        || $0.title.localizedCaseInsensitiveContains(search)
                        || $0.detail.localizedCaseInsensitiveContains(search)
                )
        }
    }

    private func matches(_ text: String) -> Bool {
        search.isEmpty || text.localizedCaseInsensitiveContains(search)
    }

    private var matchesTaskSlots: Bool {
        matches("Перейти к задаче")
            || (0 ..< 6).contains { slot in
                model.taskSlot(slot)?.title?.localizedCaseInsensitiveContains(search) == true
            }
    }

    private func taskSlotChoiceTitle(_ slot: Int) -> String {
        guard
            let title = model.taskSlot(slot)?.title?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !title.isEmpty
        else {
            return "Задача \(slot + 1)"
        }
        return title
    }

    private func taskSlotChoiceDetail(_ slot: Int) -> String {
        guard let task = model.taskSlot(slot) else {
            return "Слот \(slot + 1) · данные ещё не получены"
        }
        return "Слот \(slot + 1) · \(task.status.title)"
    }

    private func choose(_ action: BindingAction) {
        model.setBinding(action)
        dismiss()
    }

    private func symbol(for category: CodexActionDescriptor.Category) -> String {
        switch category {
        case .chat: "bubble.left"
        case .mode: "switch.2"
        case .navigation: "arrow.left.arrow.right"
        case .panels: "sidebar.left"
        case .context: "paperclip"
        case .workspace: "folder"
        case .settings: "gearshape"
        }
    }
}

private struct ActionChoiceRow: View {
    let symbol: String
    let title: String
    let detail: String
    var available = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(available ? NostromoTheme.accent : .secondary)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                Text(available ? detail : "\(detail) · Недоступно")
                    .font(.caption)
                    .foregroundStyle(NostromoTheme.mutedForeground)
                        .lineLimit(2)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(available ? "\(title): \(detail)" : "\(title): недоступно. \(detail)")
        .accessibilityLabel(title)
        .accessibilityValue(available ? detail : "\(detail). Недоступно")
        .accessibilityHint(available ? "Назначает действие «\(title)»" : "Это действие недоступно")
        .disabled(!available)
    }
}

private struct InspectorSectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        NostromoEyebrow(text)
    }
}

private struct GestureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .foregroundStyle(NostromoTheme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(NostromoTheme.mutedForeground)
            }
        }
    }
}
