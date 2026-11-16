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
    let selectedNote: PlannerNote?
    private var notes: NoteStore { taskService.notes }
    let filter: TaskFilter
    let openEvent: (CalendarEvent) -> Void
    @State private var useFolder = true
    @State private var cloudTaskID: UUID?
    @State private var editing: AssistantAction?
    @State private var showDrafts = false
    @State private var showClear = false
    @State private var showModelConnections = false
    private var folderOptions: [AssistantFolder] { AssistantService.folders(folders, preferences: preferences) }
    private var calendarOptions: [AssistantCalendar] { calendar.calendars.filter(\.writable).map { AssistantCalendar(id: $0.id, name: $0.title) } }
    private var isCloud: Bool { service.current?.usesCloudModel == true }
    private var canSend: Bool { service.canSendCloud }
    private var canPropose: Bool { isCloud && service.supportsCloudProposals }
    private var taskIsAttached: Bool { canPropose && selectedTask?.id == cloudTaskID && cloudTaskID != nil }
    private var draftActions: [AssistantAction] { service.current?.visibleActions ?? [] }
    private var actionsBusy: Bool { service.generating || service.applying || service.storageFailed || editing != nil }
    private var pendingEdits: [AssistantTextEdit] {
        (service.current?.textEdits ?? []).filter { $0.hasChanges && $0.status == .pending }
    }
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
            conversation
            modelFooter
        }
        .background(Color.clear)
        .sheet(isPresented: $showModelConnections) {
            AssistantModelConnections(service: service, russian: preferences.language.resolvedCode == "ru",
                boundAccountID: service.chatGPTAccountID, preferences: preferences, dismissOnChatSelection: true)
        }
        .sheet(item: $editing) { action in
            AssistantActionEditor(action: action, folders: folderOptions, calendars: calendarOptions,
                actions: service.current?.actions ?? [], save: {
                    if service.updateAction($0) { editing = nil; return nil }
                    return service.error ?? "Не удалось сохранить"
                }, cancel: { editing = nil })
        }
        .onAppear(perform: prepareConversation)
        .onChange(of: preferences.rightPanel) { prepareConversation() }
        .onChange(of: service.archive.currentID) {
            editing = nil; cloudTaskID = nil; showDrafts = false
            prepareConversation()
        }
        .onChange(of: selectedTask?.id) { cloudTaskID = nil }
        .onChange(of: service.current?.focusedDraftID) { if service.current?.focusedDraftID != nil { cloudTaskID = nil } }
        .onChange(of: isCloud) { cloudTaskID = nil }
        .onChange(of: service.current?.cloud?.gatewayProfileID) { cloudTaskID = nil }
        .onChange(of: canPropose) { if !canPropose { cloudTaskID = nil } }
    }
    private func prepareConversation() {
        guard preferences.rightPanel == .assistant else { return }
        service.cloud.activate()
        service.gateways.activate()
    }
    private var conversationHeader: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    ForEach(service.archive.threads) { thread in
                        Button { service.selectConversation(thread.id) } label: {
                            Label(thread.title == "Новый разговор" ? strings[thread.title] : thread.title,
                                  systemImage: "bubble.left")
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
                                let latest = message.id == service.current?.messages.last?.id
                                if !message.text.isEmpty {
                                    Text(message.calendarTimeZoneID != nil ? strings[message.text] : message.text)
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                ForEach(message.questions) { question in
                                    Text(strings[question.text]).fontWeight(.medium)
                                    if latest, !isCloud || service.lastCloudMessageIsCurrent {
                                        ForEach(Array(question.options.prefix(4).enumerated()), id: \.offset) { _, option in
                                            Button(option) { send(option) }.disabled((!canSend && message.calendarSelection == nil) || service.generating || service.applying)
                                        }
                                        if question.options.count > 4 {
                                            Menu(strings["Другие варианты"]) {
                                                ForEach(Array(question.options.dropFirst(4).enumerated()), id: \.offset) { _, option in
                                                    Button(option) { send(option) }
                                                }
                                            }.disabled((!canSend && message.calendarSelection == nil) || service.generating || service.applying)
                                        }
                                    }
                                }
                                if let agenda = message.calendarAgenda, !agenda.isEmpty {
                                    if latest { calendarAgenda(agenda, zoneID: message.calendarTimeZoneID) }
                                    else {
                                        DisclosureGroup(strings.format("События · %d", agenda.count)) { calendarAgenda(agenda, zoneID: message.calendarTimeZoneID) }
                                    }
                                }
                                if latest, message.calendarAccessRequired == true, calendar.access != .full { calendarAccessButton }
                            }
                            .padding(12).background(message.role == .user ? PlannerStyle.accent.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                            if !showDrafts, let suggestion = service.current?.noteProposal,
                               message.resultNoteProposalID == suggestion.id {
                                noteProposalCard(suggestion)
                            }
                            if message.role == .assistant, message.id == service.current?.messages.last?.id, !showDrafts {
                                if let id = message.resultActionID, let action = draftActions.first(where: { $0.id == id }) {
                                    actionCard(action)
                                }
                                if let id = message.resultEditID,
                                   let edit = service.current?.textEdits?.first(where: { $0.id == id && $0.status != .cancelled }) {
                                    textEditCard(edit)
                                }
                            }
                        }
                        if showDrafts {
                            draftList
                        }
                        if service.generating {
                            if !service.cloudPreview.isEmpty {
                                Text(service.cloudPreview).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                            }
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(strings["Готовлю ответ…"]).foregroundStyle(.secondary)
                            }
                        }
                        if let error = service.error { Text(strings[error]).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                        Color.clear.frame(height: 1).id("assistant-bottom")
                    }
                    .padding(16)
                }
                // Новое сообщение отправляется явно; изменения карточек не отбирают прокрутку.
                .onChange(of: showDrafts) { if showDrafts { proxy.scrollTo("assistant-bottom", anchor: .bottom) } }
                .onChange(of: service.current?.messages.count) { proxy.scrollTo("assistant-bottom", anchor: .bottom) }
                .onChange(of: service.generating) { if !service.generating { proxy.scrollTo("assistant-bottom", anchor: .bottom) } }
            }
            if !draftActions.isEmpty || !pendingEdits.isEmpty {
                Button {
                    showDrafts.toggle()
                } label: {
                    Label(strings.format(draftActions.contains(where: { $0.proposal.kind == .event })
                                        ? "Карточки чата · %d" : "Задачи чата · %d", draftActions.count + pendingEdits.count),
                          systemImage: showDrafts ? "chevron.down" : "chevron.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("assistant-chat-tasks")
            }
            if service.hasAvailableCloudModel || isCloud { composer }
        }
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 28)).foregroundStyle(PlannerStyle.accent)
            if service.hasAvailableCloudModel || isCloud {
                Text(strings["Начните общение с вашим ИИ-агентом"]).font(.title3.weight(.semibold))
            } else if service.cloud.busy || !service.gateways.busy.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                Button(strings["Подключить модель"]) { showModelConnections = true }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(.vertical, 12)
    }

    private var draftList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(draftActions) { action in
                actionCard(action)
            }
            ForEach(pendingEdits) { edit in
                textEditCard(edit)
            }
            applyDraftsButton()
        }
    }

    @ViewBuilder private func applyDraftsButton(actionID: UUID? = nil) -> some View {
        let includedCount = draftActions.count(where: { $0.proposal.kind == .task && (actionID == nil || $0.id == actionID)
            && $0.included && [.pending, .failed].contains($0.status) })
        if includedCount >= (actionID == nil ? 2 : 1) {
            let count = service.readyCount(folders: folderOptions, calendars: calendarOptions, actionID: actionID, kind: .task)
            let title = actionID == nil ? strings.format("Создать: %d", count) : strings["Создать задачу"]
            Button {
                Task { await service.apply(taskService: taskService, calendar: calendar, folders: folders, actionID: actionID, kind: .task) }
            } label: {
                Text(service.applying ? strings["Создание…"] : title)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("assistant-apply")
            .disabled(count == 0 || actionsBusy)
        }
    }

    private func textEditCard(_ edit: AssistantTextEdit) -> some View {
        AssistantTextEditCard(
            edit: edit, busy: service.generating || service.applying || service.storageFailed,
            apply: { service.applyTextEdit(edit.id, tasks: taskService) },
            refresh: {
                guard canSend && canPropose else { return }
                service.refreshTextEdit(edit.id, tasks: taskService)
                if let active = service.activeTextEdit, active.id != edit.id {
                    send(edit.lastRequest ?? strings["Улучшить описание"])
                }
            }
        )
        .contextMenu {
            if edit.status == .pending, edit.committed == nil {
                Button(strings["Отмена"]) { service.cancelTextEdit(edit.id) }
                    .disabled(service.generating || service.applying || service.storageFailed)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if useFolder && preferences.assistantUseCurrentFolder && filter.isPrimaryFolder {
                contextChip(strings["Папка"] + ": " + filter.title(in: folders, using: strings)) { useFolder = false }
            }
            if let noteID = service.current?.attachedNoteID {
                let title = notes.notes.first { $0.id == noteID }?.displayTitle ?? ""
                contextChip(title.isEmpty ? strings["Заметка"] : strings["Заметка"] + " · " + title) {
                    service.attachNote(nil)
                }
                .disabled(service.generating || service.applying)
            } else if taskIsAttached, let task = selectedTask {
                contextChip(strings["Задача"] + ": " + task.displayTitle(using: strings)) {
                    setCurrentTaskAttached(false)
                }
            } else if canPropose, let target = service.activeTextEdit {
                contextChip(strings[target.target == .savedTask ? "Доработка задачи" : "Черновик задачи"] + ": " + target.before.title) {
                    service.chooseTextEdit(nil)
                }
            } else if canPropose, let thread = service.current, let draft = thread.focusedDraft,
                      let number = thread.taskDraftNumber(draft.id) {
                contextChip("#\(number) · " + draft.proposal.title) { service.clearDraftFocus() }
            } else if canPropose, selectedTask != nil {
                Button { setCurrentTaskAttached(true) } label: { Label(strings["Приложить открытую задачу"], systemImage: "paperclip") }
                    .buttonStyle(.borderless).font(.caption).disabled(service.generating || service.applying)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if service.current?.draft.isEmpty != false { Text(strings["Сообщение помощнику"]).foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                    if let threadID = service.archive.currentID {
                        AssistantComposer(text: Binding(get: { service.draft(for: threadID) },
                            set: { service.setDraft($0, for: threadID) }), submit: {
                            if service.archive.currentID == threadID { send(service.draft(for: threadID)) }
                        })
                        .id(threadID)
                        .frame(height: 76)
                    }
                }
                Button {
                    if service.generating { service.stop() } else { send(service.current?.draft ?? "") }
                } label: { Image(systemName: service.generating ? "stop.fill" : "arrow.up").frame(width: 24, height: 24) }
                .buttonStyle(.borderedProminent).clipShape(Circle())
                .help(strings[service.generating ? "Остановить" : "Отправить"])
                .disabled(service.applying || service.storageFailed || editing != nil || (!service.generating && (service.current?.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)))
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
                if service.hasAvailableCloudModel || isCloud {
                    Menu {
                        Toggle(strings["Использовать папку"], isOn: $useFolder)
                        Toggle(strings["Использовать задачу"], isOn: Binding(
                            get: { taskIsAttached },
                            set: { attached in setCurrentTaskAttached(attached) }
                        ))
                        .disabled(selectedTask == nil || !canPropose || service.generating || service.applying)
                        Toggle(strings["Использовать заметку"], isOn: Binding(
                            get: { service.current?.attachedNoteID != nil },
                            set: { enabled in service.attachNote(enabled ? selectedNote?.id : nil) }
                        ))
                        .disabled((service.current?.attachedNoteID == nil && (selectedNote == nil || selectedNote?.deletedAt != nil || !canSend))
                                  || service.generating || service.applying)
                    } label: { Image(systemName: "scope") }.menuStyle(.borderlessButton).fixedSize()
                        .help(strings["Контекст сообщения"])
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
    }
    private func setCurrentTaskAttached(_ attached: Bool) {
        guard !service.generating, !service.applying else { return }
        if attached {
            guard canPropose, let selectedTask else { return }
            cloudTaskID = selectedTask.id
        } else {
            // Снимаем и фокус правки этой задачи, чтобы её текст не ушёл со следующим сообщением.
            if let edit = service.activeTextEdit, edit.target == .savedTask, edit.before.id == cloudTaskID {
                service.chooseTextEdit(nil)
            }
            cloudTaskID = nil
        }
    }

    private func contextChip(_ title: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) { Text(title).lineLimit(1); Button(action: remove) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            .font(.caption).foregroundStyle(.secondary)
    }
    private func send(_ text: String) {
        guard editing == nil, !service.generating, !service.applying, !service.storageFailed,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if service.handleDraftCommand(text, context: context) {
            showDrafts = true
            return
        }
        if service.handleCalendarChoice(text, calendar: calendar) {
            showDrafts = false
            return
        }
        guard canSend else {
            service.error = "Выберите доступную модель в меню"
            return
        }
        showDrafts = false
        var requestContext = context
        if canPropose, let selectedTask, AssistantIntentPolicy.referencesOpenTask(text) {
            requestContext.taskID = selectedTask.id.uuidString
            requestContext.taskTitle = selectedTask.title
        }
        service.sendCloud(text, context: requestContext, tasks: taskService,
                          calendar: calendar, visibleCalendarIDs: preferences.visibleCalendarIDs, notes: notes)
    }

    private func noteProposalCard(_ suggestion: AssistantNoteProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(suggestion.title.isEmpty ? strings["Готовый текст заметки"] : suggestion.title, systemImage: "note.text")
                .font(.headline)
            Text(suggestion.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if suggestion.applied {
                Label(strings["Изменения сохранены"], systemImage: "checkmark").foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { noteProposalActions(suggestion) }
                    VStack(alignment: .leading) { noteProposalActions(suggestion) }
                }
                .disabled(actionsBusy)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func noteProposalActions(_ suggestion: AssistantNoteProposal) -> some View {
        Button(strings["Заменить текст заметки"]) {
            service.applyNoteProposal(suggestion.id, notes: notes, append: false)
        }
        Button(strings["Добавить в конец"]) {
            service.applyNoteProposal(suggestion.id, notes: notes, append: true)
        }
    }

    private func actionCard(_ action: AssistantAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let move = action.calendarMove { eventMoveCard(action, move: move) }
            else { standardActionCard(action) }
            HStack {
                if action.proposal.kind == .event { eventApplyButton(action) }
                else { applyDraftsButton(actionID: action.id) }
                if action.isEditable {
                    Spacer(minLength: 0)
                    Button(strings["Редактировать"]) { editing = action }
                        .disabled(actionsBusy)
                }
            }
        }
        .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private func standardActionCard(_ action: AssistantAction) -> some View {
        let problems = service.problems(action, folders: folderOptions, calendars: calendarOptions)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let number = service.current?.taskDraftNumber(action.id) {
                    Text("#\(number)").monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Image(systemName: action.proposal.kind == .task ? "checkmark.circle" : "calendar")
                }
                Text(action.proposal.title).fontWeight(.semibold)
                Spacer(minLength: 0)
                if action.isEditable {
                    Toggle("", isOn: Binding(get: { action.included }, set: { value in var copy = action; copy.included = value; service.updateAction(copy) }))
                        .labelsHidden().toggleStyle(.checkbox).disabled(actionsBusy)
                }
            }
            if action.proposal.kind == .task {
                Text(strings["Папка"] + ": " + (folderOptions.first { $0.id == action.proposal.folderID }?.name ?? strings["Не выбрана"]))
                if action.proposal.today == true { Label(strings["На сегодня"], systemImage: "star.fill").foregroundStyle(.yellow) }
            } else {
                Text(calendarOptions.first { $0.id == action.proposal.calendarID }?.name ?? strings["Календарь не выбран"])
                if action.isEditable {
                    if calendar.access != .full {
                        calendarAccessButton
                    } else if action.proposal.calendarID == nil, action.context.calendars.isEmpty,
                              let id = calendar.creationCalendar(preferred: preferences.creationCalendarID) {
                        Button(strings["Использовать календарь по умолчанию"]) {
                            var copy = action; copy.proposal.calendarID = id; service.updateAction(copy)
                        }.disabled(actionsBusy)
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
            if let description = action.proposal.description, !description.isEmpty { Text(description).textSelection(.enabled) }
            ForEach(Array((action.proposal.checklist ?? []).enumerated()), id: \.offset) { _, title in Label(title, systemImage: "circle") }
            if let link = action.proposal.linkTo {
                Label(action.context.taskID == link ? (action.context.taskTitle ?? strings["Задача"]) : (service.current?.actions.first { $0.proposal.key == link }?.proposal.title ?? strings["Связанная задача"]), systemImage: "link")
            }
            if action.status == .needsReview {
                Text(strings["Проверьте календарь: результат предыдущего сохранения неизвестен. Автоматическое повторение отключено."]).foregroundStyle(.orange)
            } else {
                ForEach(problems, id: \.self) { Text(strings[$0]).foregroundStyle(.orange) }
                if let error = action.error { Text(strings[error]).foregroundStyle(.red) }
                if action.proposal.kind == .task, service.hasUnreviewedText(for: action.id) {
                    Text(strings["Сначала примите или отмените предложенные правки."]).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .opacity(action.included ? 1 : 0.55)
    }
    private var calendarAccessButton: some View {
        let canRequest = calendar.access == .notDetermined || calendar.access == .writeOnly
        return Button(strings[canRequest ? "Подключить календарь" : "Открыть системные настройки"]) {
            if canRequest { Task { await calendar.connect() } }
            else { calendar.openPrivacySettings() }
        }.disabled(calendar.connecting)
    }

    private func eventInterval(start: Date, end: Date, allDay: Bool, zone: TimeZone) -> String {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        let last = allDay ? (local.date(byAdding: .day, value: -1, to: end) ?? end) : end
        let date = Date.FormatStyle(date: .abbreviated, time: .omitted,
                                    locale: preferences.language.locale, calendar: local, timeZone: zone)
        let time = Date.FormatStyle(date: .omitted, time: .shortened,
                                    locale: preferences.language.locale, calendar: local, timeZone: zone)
        let startDay = start.formatted(date)
        let endDay = last.formatted(date)
        if allDay {
            return (startDay == endDay ? startDay : startDay + " – " + endDay) + " · " + strings["Весь день"]
        }
        return startDay + " · " + start.formatted(time) + " – "
            + (startDay == endDay ? "" : endDay + " · ") + last.formatted(time)
    }

    private func calendarAgenda(_ items: [AssistantCalendarItem], zoneID: String?) -> some View {
        let zone = zoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                Button {
                    // По времени начала различаем в том числе экземпляры одного повторяющегося события.
                    let range = DateInterval(start: item.start, end: item.start.addingTimeInterval(1))
                    if let events = try? calendar.load(range, visibleIDs: [item.calendarID]),
                       let event = events.first(where: item.matches) {
                        openEvent(event)
                    } else { service.error = "Событие изменилось. Найдите его снова в календаре." }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(item.title, systemImage: "calendar")
                        Text(eventInterval(start: item.start, end: item.end, allDay: item.allDay, zone: zone))
                            .font(.caption).foregroundStyle(.secondary)
                        if !item.calendarName.isEmpty { Text(item.calendarName).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }
    }

    private func eventMoveCard(_ action: AssistantAction, move: AssistantCalendarMove) -> some View {
        let zone = TimeZone(identifier: move.timeZoneID) ?? .current
        return VStack(alignment: .leading, spacing: 8) {
            Label(action.proposal.title, systemImage: "calendar").fontWeight(.semibold)
            Text(eventInterval(start: move.start, end: move.end, allDay: move.source.allDay, zone: zone))
            if !move.source.calendarName.isEmpty { Text(move.source.calendarName).foregroundStyle(.secondary) }
            if zone != .current { Text(zone.identifier).foregroundStyle(.secondary) }
            if action.status == .needsReview {
                Text(strings["Проверьте календарь: результат предыдущего сохранения неизвестен. Автоматическое повторение отключено."])
                    .foregroundStyle(.orange)
            } else {
                if calendar.access != .full { calendarAccessButton }
                ForEach(service.problems(action, folders: folderOptions, calendars: calendarOptions), id: \.self) {
                    Text(strings[$0]).foregroundStyle(.orange)
                }
                if let error = action.error { Text(strings[error]).foregroundStyle(.red) }
            }
        }
    }

    @ViewBuilder private func eventApplyButton(_ action: AssistantAction) -> some View {
        if action.included && [.pending, .failed].contains(action.status) {
            let title = action.calendarMove != nil ? "Перенести событие"
                : (action.createdEventID == nil ? "Создать событие" : "Сохранить связь")
            Button(strings[title]) {
                Task { await service.apply(taskService: taskService, calendar: calendar, folders: folders, actionID: action.id) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(calendar.access != .full || actionsBusy ||
                service.readyCount(folders: folderOptions, calendars: calendarOptions, actionID: action.id) == 0)
            .accessibilityIdentifier("assistant-apply-event")
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
        if !view.hasMarkedText(), view.string != text { view.string = text }
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
