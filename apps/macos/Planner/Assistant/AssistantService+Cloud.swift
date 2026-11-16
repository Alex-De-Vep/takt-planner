import Foundation

extension AssistantService {
    var hasAvailableCloudModel: Bool {
        (cloud.isConnected && !cloud.models.isEmpty) || gateways.catalogs.contains { gateway, models in
            !models.isEmpty && gateways.profiles[gateway] != nil && !gateways.busy.contains(gateway)
        }
    }

    var cloudModel: ChatGPTModel? {
        guard current?.usesCloudModel == true, let settings = current?.cloud, settings.gateway == nil else { return nil }
        return cloud.models.first { $0.id == settings.modelID } ?? cloud.models.first
    }

    var chatGPTAccountID: String? {
        current?.cloud?.gateway == nil ? current?.cloud?.accountID : nil
    }

    var gatewayProfile: AssistantGatewayProfile? {
        guard current?.usesCloudModel == true, let settings = current?.cloud, let gateway = settings.gateway,
              let profile = gateways.profiles[gateway], profile.id == settings.gatewayProfileID else { return nil }
        return profile
    }

    var gatewayModel: AssistantGatewayModel? {
        guard let profile = gatewayProfile else { return nil }
        return gateways.catalogs[profile.gateway]?.first { $0.id == current?.cloud?.modelID }
    }

    var supportsCloudProposals: Bool {
        guard current?.cloud?.gateway != nil else { return true }
        guard let profile = gatewayProfile else { return false }
        return gatewayModel?.supportsTools(in: profile) == true
    }

    var cloudModelName: String {
        if let gateway = current?.cloud?.gateway { return gatewayModel?.name ?? gateway.name }
        return cloudModel?.name ?? "ChatGPT"
    }

    var lastCloudMessageIsCurrent: Bool {
        guard let thread = current, let settings = thread.cloud else { return false }
        return thread.messages.count > (settings.historyStart ?? 0)
    }

    var cloudEfforts: [String] { gatewayModel?.efforts ?? cloudModel?.efforts ?? [] }

    var cloudEffort: String? {
        guard let effort = current?.cloud?.effort, cloudEfforts.contains(effort) else { return nil }
        return effort
    }

    var canSendCloud: Bool {
        guard current?.usesCloudModel == true, let settings = current?.cloud else { return false }
        if let gateway = settings.gateway {
            return gatewayModel != nil && !gateways.busy.contains(gateway)
        }
        return cloud.canSend(to: settings.accountID)
    }

    func selectCloudModel(_ id: String) {
        guard cloud.canSend(to: chatGPTAccountID), let accountID = cloud.account?.id,
              let model = cloud.models.first(where: { $0.id == id }) else { return }
        changeModel { $0.chooseModel(id: model.id, efforts: model.efforts, accountID: accountID) }
    }

    func selectGatewayModel(_ id: String, gateway: AssistantGateway) {
        guard let profile = gateways.profiles[gateway], !gateways.busy.contains(gateway),
              let model = gateways.catalogs[gateway]?.first(where: { $0.id == id }) else { return }
        changeModel { $0.chooseModel(id: id, efforts: model.efforts, gateway: gateway, profileID: profile.id) }
    }

    private func changeModel(_ update: (inout AssistantThread) -> Void) {
        guard !generating, !applying, !storageFailed, let i = currentIndex else { return }
        let previous = archive.threads[i]
        update(&archive.threads[i])
        error = nil
        if !persist() { archive.threads[i] = previous }
    }

    func selectCloudEffort(_ effort: String?) {
        guard !generating, !applying, let i = currentIndex, archive.threads[i].usesCloudModel,
              effort == nil || cloudEfforts.contains(effort ?? "") else { return }
        archive.threads[i].cloud?.effort = effort
        persist()
    }

    func clearDraftFocus() {
        guard !generating, !applying, let index = currentIndex else { return }
        let previous = archive.threads[index]
        archive.threads[index].focusedDraftID = nil
        if !persist() { archive.threads[index] = previous }
    }

    // Просмотр черновиков и выбор папки выполняются по данным текущего чата.
    func handleDraftCommand(_ input: String, context: AssistantContext) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = currentIndex, var thread = current else { return false }
        let show = AssistantIntentPolicy.matches(text,
            #"^(?:покажи(?:те)?\s+(?:все\s+)?(?:задачи|черновики)(?:\s+(?:этого\s+)?чата)?(?:\s+снова)?|show\s+(?:(?:all|the)\s+)?(?:tasks|drafts)(?:\s+in\s+this\s+chat)?(?:\s+again)?)[.!?]?$"#)
        let taskIndexes = thread.actions.indices.filter {
            let action = thread.actions[$0]
            return action.proposal.kind == .task && action.included && [.pending, .failed].contains(action.status)
        }
        let bulk = !taskIndexes.isEmpty && AssistantIntentPolicy.matches(text,
            #"^(?:(?:создай|сохрани|добавь)\s+все\s+(?:задачи|черновики)|(?:create|save|add)\s+all\s+(?:tasks|drafts))\b"#)
        let english = context.language == "en"
        let message: String
        if show {
            let hasItems = !thread.visibleActions.isEmpty || thread.textEdits?.contains {
                $0.hasChanges && $0.status == .pending
            } == true
            message = english ? (hasItems ? "Here are the tasks in this chat." : "There are no task cards in this chat yet.")
                : (hasItems ? "Вот задачи этого чата." : "В этом чате пока нет карточек задач.")
        } else if bulk {
            let destination = AssistantIntentPolicy.destination(in: text, choices: context.folders.map { ($0.id, $0.name) }, calendar: false)
            if let folderID = destination.id, let name = destination.name {
                for taskIndex in taskIndexes {
                    thread.actions[taskIndex].proposal.folderID = folderID
                }
                message = english ? "The drafts are ready for ‘\(name)’. Confirm to create them."
                    : "Черновики готовы для папки «\(name)». Подтвердите создание."
            } else if destination.specified {
                message = english ? "I couldn’t identify that folder. You can choose a folder in each card."
                    : "Не удалось определить папку. Её можно выбрать в карточках задач."
            } else {
                message = english ? "Review the drafts and confirm to create them." : "Проверьте черновики и подтвердите создание."
            }
        } else { return false }
        recordLocalReply(text, reply: .init(role: .assistant, text: message), thread: thread, at: index)
        return true
    }

    func recordLocalReply(_ text: String, reply: AssistantMessage, thread: AssistantThread, at index: Int) {
        var updated = thread
        updated.draft = ""
        if updated.messages.isEmpty { updated.title = String(text.prefix(60)) }
        updated.messages.append(.init(role: .user, text: text))
        updated.messages.append(reply)
        let previous = archive.threads[index]
        archive.threads[index] = updated
        error = nil
        if !persist() { archive.threads[index] = previous }
    }

    func sendCloud(_ input: String, context: AssistantContext, tasks: TaskService?,
                   calendar: CalendarService? = nil, visibleCalendarIDs: Set<String>? = nil,
                   notes: NoteStore? = nil) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !generating, !applying, !storageFailed,
              let i = currentIndex, current?.usesCloudModel == true, let settings = current?.cloud else { return }
        guard text.count <= 8000 else { error = "Сообщение слишком длинное. Сократите его до 8000 символов."; return }
        if let calendar, handleCalendarChoice(text, calendar: calendar) { return }
        guard canSendCloud else {
            error = settings.gateway == nil ? "Подключите аккаунт ChatGPT для этого диалога."
                : "Подключите сервис и выберите доступную модель."
            return
        }
        let profile = gatewayProfile
        let accountID = cloud.account?.id
        let tools = supportsCloudProposals
        do {
            var context = context
            if lastCloudMessageIsCurrent, archive.threads[i].messages.last?.questions.isEmpty == false,
               let previous = archive.threads[i].clarificationContext {
                context.now = previous.now
                context.timeZoneID = previous.timeZoneID
            }
            let note: AssistantAttachedNote?
            if let id = archive.threads[i].attachedNoteID {
                guard let notes, notes.flush(), let selected = notes.notes.first(where: { $0.id == id && $0.deletedAt == nil }) else {
                    throw AssistantFailure(message: "Заметка недоступна.")
                }
                note = AssistantAttachedNote(selected)
            } else { note = nil }
            var requestedTask = note == nil ? context.taskID.flatMap(UUID.init(uuidString:)) : nil
            var modelInput = text
            if note == nil, tools, let tasks {
                if lastCloudMessageIsCurrent, let previous = archive.threads[i].messages.last,
                   let lookup = previous.taskLookup, let options = previous.questions.first?.options,
                   let index = options.firstIndex(of: text) ?? Int(text).flatMap({ $0 > 0 && $0 <= options.count ? $0 - 1 : nil }),
                   lookup.taskIDs.indices.contains(index) {
                    requestedTask = lookup.taskIDs[index]
                    modelInput = lookup.request
                } else if let query = AssistantIntentPolicy.savedTaskQuery(text) {
                    let matches = try tasks.assistantTasks(matching: query)
                    if matches.count != 1 {
                        let options = matches.enumerated().map { index, task in
                            "\(index + 1). \(task.title)" + (task.folder.map { " · " + $0.name } ?? "")
                        }
                        let message = context.language == "en"
                            ? (matches.isEmpty ? "I couldn’t find a task by that name." : "Which task should I update?")
                            : (matches.isEmpty ? "Я не нашёл задачу с таким названием." : "Какую задачу обновить?")
                        let lookup = matches.isEmpty ? nil : AssistantTaskLookup(request: text, taskIDs: matches.map(\.id))
                        let reply = AssistantMessage(role: .assistant, text: options.isEmpty ? message : "",
                            questions: options.isEmpty ? [] : [.init(text: message, options: options)], taskLookup: lookup)
                        recordLocalReply(text, reply: reply, thread: archive.threads[i], at: i)
                        return
                    }
                    requestedTask = matches.first?.id
                }
            }
            var thread = archive.threads[i]
            let numberedDraft = AssistantIntentPolicy.referencedDraftNumber(text).flatMap { number in
                thread.numberedTaskDrafts.dropFirst(number - 1).first
            }
            if note == nil, tools, requestedTask == nil, let numberedDraft, [.pending, .failed].contains(numberedDraft.status),
               thread.cloud?.draftIDs?.contains(numberedDraft.id) ?? true {
                thread.focusedDraftID = numberedDraft.id
                thread.activeTextEditID = nil
            }
            let edit: AssistantTextEdit?
            if !tools || note != nil { edit = nil }
            else if let id = requestedTask, let tasks {
                if let pending = archive.threads[i].textEdits?.last(where: {
                    $0.target == .savedTask && $0.before.id == id && $0.status == .pending && $0.committed == nil
                }) {
                    edit = pending
                } else {
                    guard let task = try tasks.assistantTask(id: id) else { throw AssistantFailure(message: "Задача больше не существует.") }
                    edit = AssistantTextEdit(target: .savedTask, before: try tasks.assistantTextSnapshot(task))
                }
            } else if let active = activeTextEdit, active.id == thread.activeTextEditID, active.committed == nil {
                edit = active
            } else { edit = nil }

            let previousNoteProposal = thread.noteProposal.flatMap { proposal in
                proposal.noteID == note?.id && !proposal.applied ? proposal.body : nil
            }
            let request: AssistantCloudRequest
            if let profile, let model = gatewayModel {
                request = try AssistantCloudRequest(thread: thread, text: modelInput, context: context, edit: edit,
                                                    modelID: model.id, effort: cloudEffort, gateway: profile.gateway, supportsTools: tools, note: note?.context, previousNoteProposal: previousNoteProposal)
            } else if settings.gateway == nil, let model = cloudModel {
                request = try AssistantCloudRequest(thread: thread, text: modelInput, context: context, edit: edit,
                                                    model: model, effort: cloudEffort, note: note?.context, previousNoteProposal: previousNoteProposal)
            } else { return }
            let previous = archive
            archive.threads[i] = thread
            if profile == nil { archive.threads[i].cloud?.accountID = settings.accountID ?? accountID }
            // Для следующего уточнения сохраняем только время и язык, без снимка календарей.
            let submittedText = modelInput
            var localContext = context
            localContext.calendars = []; localContext.defaultCalendarID = nil
            archive.threads[i].clarificationContext = localContext
            archive.threads[i].draft = ""
            archive.threads[i].messages.append(.init(role: .user, text: text))
            if archive.threads[i].messages.count == 1 { archive.threads[i].title = String(text.prefix(60)) }
            error = nil
            guard persist() else { archive = previous; return }

            let threadID = archive.threads[i].id
            let token = UUID(); requestID = token; generating = true; cloudPreview = ""
            generation = Task { [weak self] in
                guard let self else { return }
                defer {
                    if requestID == token { generating = false; generation = nil; cloudPreview = "" }
                }
                do {
                    let preview: @MainActor @Sendable (String) -> Void = { [weak self] delta in
                        guard let self, requestID == token else { return }
                        cloudPreview += delta
                    }
                    let completion: AssistantCloudCompletion
                    if let profile {
                        completion = try await gateways.http.reply(request.body, profile: profile, tools: tools, preview: preview)
                    } else if let accountID {
                        completion = try await cloud.respond(body: request.body, accountID: accountID, onText: preview)
                    } else { return }
                    try Task.checkCancellation()
                    guard requestID == token, let index = archive.threads.firstIndex(where: { $0.id == threadID }) else { return }
                    let updated: AssistantThread
                    if let operation = completion.response.calendarRequest, tools, let calendar {
                        updated = Self.calendarReply(operation, to: archive.threads[index],
                            context: context, calendar: calendar, visibleIDs: visibleCalendarIDs, usage: completion.usage)
                    } else {
                        updated = try Self.cloudReply(completion.response, to: archive.threads[index], drafts: request.drafts,
                                                          text: submittedText, context: localContext, edit: edit, usage: completion.usage, note: tools ? note : nil)
                    }
                    let previous = archive.threads[index]
                    archive.threads[index] = updated
                    if !persist() { archive.threads[index] = previous }
                } catch {
                    if requestID == token, !Task.isCancelled {
                        if error is DecodingError { self.error = AssistantCloudStream.invalid.message }
                        else if profile != nil { self.error = (error as? AssistantFailure)?.message ?? AssistantGatewayHTTP.invalid.message }
                        else { self.error = error.localizedDescription }
                    }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Ответ меняет только историю и карточки. Сохранение в библиотеку остаётся отдельным действием пользователя.
    static func cloudReply(_ reply: AssistantResponse, to original: AssistantThread, drafts: [String: UUID],
                           text: String, context: AssistantContext, edit: AssistantTextEdit?, usage: AssistantCloudUsage? = nil,
                           note: AssistantAttachedNote? = nil) throws -> AssistantThread {
        var thread = original
        var message = reply.message
        var resultActionIDs: [UUID] = []
        var resultEditID: UUID?
        var resultNoteProposalID: UUID?
        var questions = reply.questions ?? []
        if questions.isEmpty {
            let destination = AssistantIntentPolicy.destination(in: text,
                choices: context.folders.map { ($0.id, $0.name) }, calendar: false,
                replyingToQuestion: thread.messages.dropFirst(thread.cloud?.historyStart ?? 0).dropLast().last?.questions.isEmpty == false)
            if destination.specified && destination.id == nil, reply.actions?.isEmpty == false {
                questions = [.init(text: context.language == "en" ? "Which folder should I use?" : "В какую папку добавить задачи?",
                                   options: context.folders.map(\.name))]
            }
            for var proposal in reply.actions ?? [] {
                guard proposal.kind == .task, proposal.linkTo == nil else { throw AssistantCloudStream.invalid }
                let existing = drafts[proposal.key].flatMap { id in
                    thread.actions.firstIndex { $0.id == id && [.pending, .failed].contains($0.status) }
                }
                if proposal.key.hasPrefix("draft_"), existing == nil { throw AssistantCloudStream.invalid }
                let old = existing.map { thread.actions[$0] }
                proposal.key = old?.proposal.key ?? UUID().uuidString
                if destination.specified { proposal.folderID = destination.id }
                else if let old { proposal.folderID = old.proposal.folderID }
                else { proposal.folderID = context.defaultFolderID }
                if AssistantIntentPolicy.noDeadline(text) { proposal.date = nil; proposal.time = nil }
                if let existing, var old {
                    old.proposal = proposal; old.error = nil; old.status = .pending
                    thread.actions[existing] = old
                    resultActionIDs.append(old.id)
                } else {
                    let action = AssistantAction(proposal: proposal, context: context)
                    thread.actions.append(action)
                    resultActionIDs.append(action.id)
                    thread.cloud?.draftIDs?.insert(action.id)
                }
            }
            if !resultActionIDs.isEmpty && reply.textEdit == nil {
                thread.activeTextEditID = nil
                thread.focusedEventID = nil
                thread.focusedDraftID = resultActionIDs.count == 1 ? resultActionIDs.first : nil
            }
            if let note, let body = reply.noteEdit?.trimmingCharacters(in: .whitespacesAndNewlines),
               !body.isEmpty, body.utf8.count <= 120_000 {
                let proposal = AssistantNoteProposal(noteID: note.id, title: note.title, version: note.version, body: body)
                thread.noteProposal = proposal
                resultNoteProposalID = proposal.id
            }
            if let change = reply.textEdit {
                if var edit {
                    try edit.propose(change)
                    if edit.hasChanges {
                        edit.lastRequest = text
                        var edits = thread.textEdits ?? []
                        if let index = edits.firstIndex(where: { $0.id == edit.id }) { edits[index] = edit }
                        else { edits.append(edit) }
                        thread.textEdits = edits
                        thread.activeTextEditID = edit.id
                        thread.focusedDraftID = nil
                        thread.focusedEventID = nil
                        resultEditID = edit.id
                    } else if message.isEmpty {
                        message = context.language == "ru" ? "Текст не изменился." : "The text is unchanged."
                    }
                } else {
                    message = context.language == "ru"
                        ? "Приложите открытую задачу или выберите черновик для правки."
                        : "Attach the open task or choose a draft to edit."
                }
            }
        }
        if message.isEmpty {
            message = context.language == "ru" ? "Проверьте предложение в чате." : "Review the proposal in the chat."
        }
        thread.messages.append(.init(role: .assistant, text: message, questions: questions, cloudUsage: usage,
                                     resultActionID: resultActionIDs.count == 1 && resultEditID == nil ? resultActionIDs.first : nil,
                                     resultEditID: resultEditID, resultNoteProposalID: resultNoteProposalID))
        return thread
    }
}
