import SwiftUI
import AppKit

/// Чат занимает ту же оболочку правой панели, что и календарь; собственную шапку окна не рисуем.
struct AssistantPanel: View {
    @Environment(\.translations) private var strings
    @Bindable var service: AssistantService
    @Bindable var preferences: AppPreferences
    let taskService: TaskService
    let calendar: CalendarService
    let folders: [TaskFolder]
    let selectedTask: PlannerTask?
    let filter: TaskFilter
    let openTask: (PlannerTask) -> Void
    let openEvent: (CalendarEvent) -> Void
    @State private var useFolder = true
    @State private var useTask = true
    @State private var cloudTaskID: UUID?
    @State private var editing: AssistantAction?
    @State private var showClear = false
    @State private var showModelConnections = false
    private var folderOptions: [AssistantFolder] { AssistantService.folders(folders, preferences: preferences) }
    private var calendarOptions: [AssistantCalendar] { calendar.calendars.filter(\.writable).map { AssistantCalendar(id: $0.id, name: $0.title) } }
    private var isCloud: Bool { service.current?.usesCloudModel == true }
    private var canSend: Bool { isCloud ? service.canSendCloud : service.model.canChat }
    private var canPropose: Bool { !isCloud || service.supportsCloudProposals }
    private var taskIsAttached: Bool { isCloud ? canPropose && selectedTask?.id == cloudTaskID && cloudTaskID != nil : useTask }
    private var context: AssistantContext {
        let defaultFolder = preferences.assistantUseCurrentFolder && useFolder && filter.isPrimaryFolder
            ? (filter == .inbox ? "inbox" : filter == .week ? "week" : filter == .month ? "month" : { if case .folder(let id) = filter { return id.uuidString }; return "inbox" }())
            : (folderOptions.contains { $0.id == preferences.assistantDefaultFolder } ? preferences.assistantDefaultFolder : "inbox")
        return AssistantContext(now: .now, timeZoneID: TimeZone.current.identifier,
            language: preferences.language.resolvedCode, folders: folderOptions, calendars: calendarOptions,
            defaultFolderID: defaultFolder, defaultCalendarID: calendar.creationCalendar(preferred: preferences.creationCalendarID),
            taskID: taskIsAttached ? selectedTask?.id.uuidString : nil, taskTitle: taskIsAttached ? selectedTask?.displayTitle(using: strings) : nil,
            durationMinutes: preferences.assistantDuration, reminderMinutes: preferences.assistantReminder < 0 ? nil : preferences.assistantReminder)
    }
    var body: some View {
        VStack(spacing: 0) {
            conversationHeader
            if isCloud || service.model.canChat || service.current?.messages.isEmpty == false { conversation }
            else { AssistantModelSetup(manager: service.model) }
            modelFooter
        }
        .background(Color.clear)
        .sheet(isPresented: $showModelConnections) {
            AssistantModelConnections(service: service, russian: preferences.language.resolvedCode == "ru",
                boundAccountID: service.chatGPTAccountID, selectModel: service.selectCloudModel)
        }
        .onAppear(perform: prepareConversation)
        .onChange(of: preferences.rightPanel) { prepareConversation() }
        .onChange(of: service.archive.currentID) {
            editing = nil; cloudTaskID = nil
            prepareConversation()
        }
        .onChange(of: selectedTask?.id) { cloudTaskID = nil }
        .onChange(of: isCloud) { cloudTaskID = nil }
        .onChange(of: service.current?.cloud?.gatewayProfileID) { cloudTaskID = nil }
        .onChange(of: canPropose) { if !canPropose { cloudTaskID = nil } }
    }
    private func prepareConversation() {
        guard preferences.rightPanel == .assistant else { return }
        // Каталог доступен в едином меню даже при выборе модели на Mac.
        service.cloud.activate()
        service.gateways.activate()
        if !isCloud { service.model.restoreIfInstalled() }
    }
    private var conversationHeader: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    ForEach(service.archive.threads) { thread in
                        Button { service.selectConversation(thread.id) } label: {
                            Label(thread.title == "Новый разговор" ? strings[thread.title] : thread.title,
                                  systemImage: thread.usesCloudModel ? "cloud" : "desktopcomputer")
                        }
                    }
                    Divider()
                    Button(strings["Очистить историю"], role: .destructive) { showClear = true }
                } label: { Label(strings["История"], systemImage: "clock.arrow.circlepath") }
                .disabled(service.generating || service.applying)
                Spacer(minLength: 4)
                Button { service.newConversation() } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel(strings["Новый разговор"])
                .help(strings["Новый разговор"]).disabled(service.generating || service.applying)
            }
            .buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 10)
            if showClear {
                VStack(alignment: .leading, spacing: 8) {
                    Text(strings["Очистить историю помощника?"]).fontWeight(.medium)
                    Text(strings["Созданные задачи и события сохранятся."]).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(strings["Отмена"]) { showClear = false }
                        Spacer()
                        Button(strings["Очистить"], role: .destructive) { service.clearHistory(); showClear = false }
                    }
                }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16)
            }
        }
    }
    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if service.current?.messages.isEmpty != false { examples }
                        ForEach(service.current?.messages ?? []) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(strings[message.role == .user ? "Вы" : "Помощник"]).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                if message.id == service.current?.messages.last?.id, !isCloud || service.lastCloudMessageIsCurrent {
                                    ForEach(message.questions) { question in
                                        Text(question.text).fontWeight(.medium)
                                        ForEach(Array(question.options.prefix(4).enumerated()), id: \.offset) { _, option in
                                            Button(option) { send(option) }.disabled(!canSend || service.generating || service.applying)
                                        }
                                        if question.options.count > 4 {
                                            Menu(strings["Другие варианты"]) {
                                                ForEach(Array(question.options.dropFirst(4).enumerated()), id: \.offset) { _, option in
                                                    Button(option) { send(option) }
                                                }
                                            }.disabled(!canSend || service.generating || service.applying)
                                        }
                                    }
                                }
                            }
                            .padding(12).background(message.role == .user ? PlannerStyle.accent.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                        }
                        ForEach(service.current?.actions ?? []) { action in actionCard(action) }
                        ForEach(service.current?.textEdits?.filter { $0.hasChanges && $0.status != .cancelled } ?? []) { edit in
                            AssistantTextEditCard(edit: edit, busy: service.generating || service.applying || service.storageFailed,
                                active: service.current?.activeTextEditID == edit.id, canRefine: canPropose, update: service.updateTextEdit,
                                refine: { if canPropose { service.chooseTextEdit(edit.id) } },
                                apply: { service.applyTextEdit(edit.id, tasks: taskService) },
                                cancel: { service.cancelTextEdit(edit.id) },
                                refresh: {
                                    guard canPropose else { return }
                                    service.refreshTextEdit(edit.id, tasks: taskService)
                                    if let active = service.activeTextEdit, active.id != edit.id {
                                        sendTextCommand(edit.lastRequest ?? strings["Улучшить описание"])
                                    }
                                },
                                open: { if let task = try? taskService.assistantTask(id: edit.before.id) { openTask(task) }
                                        else { service.error = "Задача больше не существует." } })
                        }
                        if service.generating {
                            if !service.cloudPreview.isEmpty {
                                Text(service.cloudPreview).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                            }
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(strings[isCloud ? "Готовлю ответ…" : "Готовлю предложение…"]).foregroundStyle(.secondary)
                            }
                        }
                        if let error = service.error { Text(strings[error]).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                        Color.clear.frame(height: 1).id("assistant-bottom")
                    }
                    .padding(16)
                }
                // Новое сообщение отправляется явно; изменения карточек не отбирают прокрутку.
                .onChange(of: service.current?.messages.count) { proxy.scrollTo("assistant-bottom", anchor: .bottom) }
                .onChange(of: service.generating) { if !service.generating { proxy.scrollTo("assistant-bottom", anchor: .bottom) } }
            }
            if (service.current?.actions.contains { $0.included && [.pending, .failed].contains($0.status) } ?? false) {
                let count = service.readyCount(folders: folderOptions, calendars: calendarOptions)
                Button {
                    Task { await service.apply(taskService: taskService, calendar: calendar, folders: folders) }
                } label: {
                    Text(service.applying ? strings["Создание…"] : strings.format("Создать: %d", count)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("assistant-apply").padding(.horizontal, 16).padding(.bottom, 10)
                .disabled(count == 0 || service.generating || service.applying || service.storageFailed || editing != nil)
            }
            if isCloud || service.model.canChat { composer }
            else { AssistantModelSetup(manager: service.model).frame(maxHeight: 210) }
        }
    }
    private var examples: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 28)).foregroundStyle(PlannerStyle.accent)
            Text(strings["Опишите, что нужно сделать"]).font(.title3.weight(.semibold))
            Text(strings[!canPropose ? "Выбранная модель поддерживает только диалог." : isCloud
                ? "Задайте вопрос, подготовьте задачи с подзадачами или приложите задачу для правки."
                : "Помощник подготовит задачи и события. Перед созданием вы проверите каждое предложение."]).foregroundStyle(.secondary)
            ForEach(!canPropose ? [] : isCloud ? ["Создай задачу с подзадачами", "Распиши новую задачу: подготовить презентацию"]
                : ["Создай задачи для подготовки проекта", "Запланируй встречу на завтра", "Создай задачу с подзадачами", "Распиши новую задачу: подготовить презентацию"], id: \.self) { example in
                Button(strings[example]) { service.setDraft(strings[example]) }
            }
        }.padding(.vertical, 12)
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editing != nil { Text(strings["Завершите изменение карточки кнопкой «Готово» или «Отмена»."]).font(.caption).foregroundStyle(.secondary) }
            if useFolder && preferences.assistantUseCurrentFolder && filter.isPrimaryFolder {
                contextChip(strings["Папка"] + ": " + filter.title(in: folders, using: strings)) { useFolder = false }
            }
            if canPropose, let target = service.activeTextEdit {
                contextChip(strings[target.target == .savedTask ? "Доработка задачи" : "Черновик задачи"] + ": " + target.before.title) { service.chooseTextEdit(nil); cloudTaskID = nil }
                textTools
            } else if taskIsAttached, let task = selectedTask {
                contextChip(strings["Задача"] + ": " + task.displayTitle(using: strings)) {
                    if isCloud { cloudTaskID = nil } else { useTask = false }
                }
                textTools
            } else if isCloud, canPropose, let task = selectedTask {
                Button { cloudTaskID = task.id } label: { Label(strings["Приложить открытую задачу"], systemImage: "paperclip") }
                    .buttonStyle(.borderless).font(.caption).disabled(service.generating || service.applying)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if service.current?.draft.isEmpty != false { Text(strings["Сообщение помощнику"]).foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                    AssistantComposer(text: Binding(get: { service.current?.draft ?? "" }, set: { value in service.setDraft(value) }), submit: { send(service.current?.draft ?? "") })
                        .frame(height: 76)
                }
                Button {
                    if service.generating { service.stop() } else { send(service.current?.draft ?? "") }
                } label: { Image(systemName: service.generating ? "stop.fill" : "arrow.up").frame(width: 24, height: 24) }
                .buttonStyle(.borderedProminent).clipShape(Circle())
                .help(strings[service.generating ? "Остановить" : "Отправить"])
                .disabled(service.applying || service.storageFailed || editing != nil || (!service.generating && (!canSend || (service.current?.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))))
            }
            .padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
    }
    private var modelFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isCloud {
                HStack {
                    if let gateway = service.current?.cloud?.gateway {
                        if service.gatewayModel != nil {
                            Text(strings.format("Данные запроса отправляются через %@", gateway.name)).foregroundStyle(.secondary)
                            if !canPropose { Text("· " + strings["Только диалог"]).foregroundStyle(.secondary) }
                        } else if service.gatewayProfile != nil {
                            Text(strings["Выберите доступную модель в меню"]).foregroundStyle(.secondary)
                        } else {
                            Button(strings["Подключения моделей…"]) { showModelConnections = true }.buttonStyle(.borderless)
                        }
                    } else if service.cloud.isConnected && (service.chatGPTAccountID.map { $0 == service.cloud.account?.id } ?? true) {
                        Text(strings["Данные запроса отправляются в OpenAI"]).foregroundStyle(.secondary)
                    } else if !service.generating {
                        Button(strings["Подключения моделей…"]) { showModelConnections = true }.buttonStyle(.borderless)
                    }
                    Spacer(minLength: 4)
                }.font(.caption2)
            }
            HStack {
                AssistantModelPicker(service: service) { showModelConnections = true }.disabled(editing != nil)
                if isCloud { AssistantUsageButton(service: service) }
                Spacer(minLength: 0)
                if isCloud || service.model.canChat {
                    Menu {
                        Toggle(strings["Использовать текущую папку"], isOn: $useFolder)
                        if !isCloud { Toggle(strings["Использовать выбранную задачу"], isOn: $useTask) }
                    } label: { Image(systemName: "scope") }.menuStyle(.borderlessButton).fixedSize()
                        .help(strings["Контекст сообщения"])
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
    }
    private func contextChip(_ title: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) { Text(title).lineLimit(1); Button(action: remove) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            .font(.caption).foregroundStyle(.secondary)
    }
    private func send(_ text: String) {
        guard editing == nil, canSend else { return }
        service.send(text, context: context, taskService: taskService)
    }
    private func sendTextCommand(_ command: String) {
        if isCloud { send(command) }
        else { service.sendText(command, language: preferences.language.resolvedCode) }
    }
    private var textTools: some View {
        AssistantTextToolsButton(title: strings["Доработать текст"],
            commands: ["Переформулировать название", "Улучшить описание", "Расписать задачу", "Разбить на подзадачи", "Сократить описание"].map { strings[$0] },
            enabled: canSend && !service.generating && !service.applying && editing == nil) { command in
                guard editing == nil else { return }
                if service.activeTextEdit != nil { sendTextCommand(command) }
                else if taskIsAttached, let task = selectedTask, service.beginTextEdit(task: task, tasks: taskService) {
                    sendTextCommand(command)
                }
            }
            .fixedSize()
    }

    private func actionCard(_ action: AssistantAction) -> some View {
        let problems = service.problems(action, folders: folderOptions, calendars: calendarOptions)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: action.proposal.kind == .task ? "checkmark.circle" : "calendar")
                Text(action.proposal.title).fontWeight(.semibold)
                Spacer(minLength: 0)
                if [.pending, .failed].contains(action.status), action.createdEventID == nil {
                    Toggle("", isOn: Binding(get: { action.included }, set: { value in var copy = action; copy.included = value; service.updateAction(copy) })).labelsHidden().toggleStyle(.checkbox)
                }
            }
            if action.proposal.kind == .task {
                Text(strings["Папка"] + ": " + (folderOptions.first { $0.id == action.proposal.folderID }?.name ?? strings["Не выбрана"]))
                if action.proposal.today == true { Label(strings["На сегодня"], systemImage: "star.fill").foregroundStyle(.yellow) }
            } else {
                Text(calendarOptions.first { $0.id == action.proposal.calendarID }?.name ?? strings["Календарь не выбран"])
                if action.status != .created && action.createdEventID == nil {
                    if calendar.access != .full {
                        Button(strings[calendar.access == .notDetermined || calendar.access == .writeOnly ? "Подключить календарь" : "Открыть системные настройки"]) {
                            if calendar.access == .notDetermined || calendar.access == .writeOnly { Task { await calendar.connect() } }
                            else { calendar.openPrivacySettings() }
                        }.disabled(calendar.connecting)
                    } else if action.proposal.calendarID == nil,
                              let id = calendar.creationCalendar(preferred: preferences.creationCalendarID) {
                        Button(strings["Использовать календарь по умолчанию"]) {
                            var copy = action; copy.proposal.calendarID = id; service.updateAction(copy)
                        }
                    }
                }
            }
            if let date = action.proposal.date {
                Text(date + (action.proposal.allDay == true ? " · " + strings["Весь день"] : action.proposal.time.map { " · " + $0 } ?? ""))
                if action.proposal.kind == .event {
                    if action.proposal.allDay != true {
                        let draft = try? ActionPlanValidator.eventDraft(action)
                        let minutes = draft.map { Int($0.end.timeIntervalSince($0.start) / 60) } ?? action.proposal.durationMinutes ?? action.context.durationMinutes
                        Text(strings.format("Длительность: %d мин", minutes))
                        if let draft { Text(strings["Окончание"] + ": " + draft.end.formatted(date: .abbreviated, time: .shortened)) }
                    } else if let end = action.proposal.endDate { Text(strings["Окончание"] + ": " + end) }
                    if action.context.timeZoneID != TimeZone.current.identifier { Text(action.context.timeZoneID).foregroundStyle(.secondary) }
                    Text(action.proposal.reminderMinutes.map { strings.format("Напоминание: за %d мин", $0) } ?? strings["Без напоминания"])
                }
            }
            if let description = action.proposal.description, !description.isEmpty { Text(description).lineLimit(4) }
            ForEach(Array((action.proposal.checklist ?? []).enumerated()), id: \.offset) { _, title in Label(title, systemImage: "circle").lineLimit(2) }
            if let link = action.proposal.linkTo {
                Label(action.context.taskID == link ? (action.context.taskTitle ?? strings["Задача"]) : (service.current?.actions.first { $0.proposal.key == link }?.proposal.title ?? strings["Связанная задача"]), systemImage: "link")
            }
            if action.status == .created {
                HStack { Label(strings["Создано"], systemImage: "checkmark.circle.fill").foregroundStyle(.green); Spacer(); Button(strings["Открыть"]) { open(action) } }
            } else if action.status == .needsReview {
                Text(strings["Проверьте календарь: результат предыдущего сохранения неизвестен. Автоматическое повторение отключено."]).foregroundStyle(.orange)
            } else {
                ForEach(problems, id: \.self) { Text(strings[$0]).foregroundStyle(.orange) }
                if let error = action.error { Text(strings[error]).foregroundStyle(.red) }
                if action.createdEventID == nil {
                    if editing?.id == action.id {
                        AssistantActionEditor(action: action, folders: folderOptions, calendars: calendarOptions,
                            actions: service.current?.actions ?? [], save: { service.updateAction($0); editing = nil }, cancel: { editing = nil })
                            .disabled(service.generating || service.applying)
                    } else {
                        Button(strings["Изменить предложение"]) { editing = action }.disabled(service.generating || service.applying)
                        if action.proposal.kind == .task {
                            if canPropose {
                                Button(strings["Доработать текст"]) { service.beginTextEdit(proposal: action) }
                                    .disabled(service.generating || service.applying)
                                    .accessibilityIdentifier("assistant-refine-proposal-\(action.id)")
                            }
                            if service.hasUnreviewedText(for: action.id) {
                                Text(strings["Сначала примите или отмените предложенные правки."]).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .font(.callout).padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .opacity(action.included ? 1 : 0.55)
    }
    private func open(_ action: AssistantAction) {
        if let id = action.createdTaskID, let task = try? taskService.assistantTask(id: id) { openTask(task) }
        else if let id = action.createdEventID, let event = calendar.resolve(identifier: id, externalIdentifier: action.createdEventExternalID) { openEvent(event) }
        else { service.error = "Созданный объект больше недоступен. Возможно, он удалён." }
    }
}

struct AssistantModelSetup: View {
    @Environment(\.translations) private var strings
    @Bindable var manager: ModelManager
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "sparkles").font(.system(size: 32)).foregroundStyle(PlannerStyle.accent)
                Text(strings["Ваш личный ии-помощник"]).font(.title2.weight(.semibold))
                Text(strings["Создавайте задачи и события обычными сообщениями. Перед сохранением помощник предложит проверить результат."])
                Text(strings["Требуется Mac с чипом Apple M1 или новее."]).fontWeight(.medium)
                Text(manager.displayName + " · " + ByteCountFormatter.string(fromByteCount: manager.total, countStyle: .file))
                Text(strings["Ваши сообщения обрабатываются на этом Mac. Содержимое чата не отправляется разработчикам модели."]).foregroundStyle(.secondary)
                Link(strings["Лицензионное соглашение"], destination: manager.modelURL)
                if manager.busy {
                    if manager.state == .downloading {
                        ProgressView(value: manager.fraction)
                        Text(ByteCountFormatter.string(fromByteCount: manager.received, countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: manager.total, countStyle: .file)).monospacedDigit()
                    } else { ProgressView().controlSize(.small) }
                    Text(strings[manager.state == .verifying ? "Проверка файлов…" : manager.state == .preparing ? "Подготовка модели…" : "Загрузка модели…"])
                    Button(strings["Отменить загрузку"]) { manager.cancel() }
                } else {
                    Button(strings[manager.accepted ? "Включить помощника" : "Скачать и включить"]) { manager.install() }
                        .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("assistant-download")
                }
                if let error = manager.error { Text(strings[error]).foregroundStyle(.red).textSelection(.enabled) }
                Text(strings["Нажимая кнопку, вы включаете помощника и подтверждаете ознакомление с лицензионным соглашением."]).font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Обычный NSTextView сохраняет системный ввод и явно различает Enter и Shift+Enter.
private struct AssistantComposer: NSViewRepresentable {
    @Binding var text: String
    let submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 76)); view.minSize = NSSize(width: 0, height: 76); view.isRichText = false; view.drawsBackground = false
        view.font = .systemFont(ofSize: 14); view.textColor = .labelColor
        view.setAccessibilityIdentifier("assistant-composer")
        view.textContainerInset = NSSize(width: 0, height: 6)
        view.autoresizingMask = [.width]; view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true; view.delegate = context.coordinator
        scroll.documentView = view; scroll.hasVerticalScroller = true
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AssistantComposer
        init(_ parent: AssistantComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView { parent.text = view.string } }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)), !NSEvent.modifierFlags.contains(.shift) { parent.submit(); return true }
            return false
        }
    }
}
