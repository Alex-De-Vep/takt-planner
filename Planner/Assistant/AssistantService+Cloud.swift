import Foundation

extension AssistantService {
    var cloudModel: ChatGPTModel? {
        guard current?.usesCloudModel == true, let settings = current?.cloud else { return nil }
        return cloud.models.first { $0.id == settings.modelID } ?? cloud.models.first
    }

    var cloudEffort: String? {
        guard let effort = current?.cloud?.effort, cloudModel?.efforts.contains(effort) == true else { return nil }
        return effort
    }

    var canSendCloud: Bool {
        guard current?.usesCloudModel == true, let settings = current?.cloud else { return false }
        return cloud.canSend(to: settings.accountID)
    }

    func selectCloudModel(_ id: String) {
        guard cloud.canSend(to: current?.cloud?.accountID),
              let model = cloud.models.first(where: { $0.id == id }) else { return }
        chooseModel(model)
    }

    func chooseLocalModel() { chooseModel(nil) }

    private func chooseModel(_ model: ChatGPTModel?) {
        guard !generating, !applying, !storageFailed, let i = currentIndex else { return }
        let previous = archive.threads[i]
        archive.threads[i].chooseModel(model)
        error = nil
        if !persist() { archive.threads[i] = previous }
        if model == nil { self.model.restoreIfInstalled() }
    }

    func selectCloudEffort(_ effort: String?) {
        guard !generating, !applying, let i = currentIndex, archive.threads[i].usesCloudModel,
              effort == nil || cloudModel?.efforts.contains(effort ?? "") == true else { return }
        archive.threads[i].cloud?.effort = effort
        persist()
    }

    func sendCloud(_ input: String, context: AssistantContext, tasks: TaskService?) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !generating, !applying, !storageFailed,
              let i = currentIndex, current?.usesCloudModel == true, let settings = current?.cloud else { return }
        guard text.count <= 8000 else { error = "Сообщение слишком длинное. Сократите его до 8000 символов."; return }
        guard canSendCloud, let accountID = cloud.account?.id, let model = cloudModel else {
            error = "Подключите аккаунт ChatGPT для этого диалога."
            return
        }
        do {
            var context = context
            if archive.threads[i].messages.last?.questions.isEmpty == false,
               let previous = archive.threads[i].clarificationContext {
                context.now = previous.now
                context.timeZoneID = previous.timeZoneID
            }
            let edit: AssistantTextEdit?
            if let active = activeTextEdit {
                guard active.committed == nil else { return }
                edit = active
            } else if let id = context.taskID.flatMap(UUID.init(uuidString:)), let tasks {
                guard let task = try tasks.assistantTask(id: id) else { throw AssistantFailure(message: "Задача больше не существует.") }
                edit = AssistantTextEdit(target: .savedTask, before: try tasks.assistantTextSnapshot(task))
            } else { edit = nil }

            let request = try AssistantCloudRequest(thread: archive.threads[i], text: text, context: context, edit: edit,
                                                    model: model, effort: cloudEffort)
            let previous = archive
            archive.threads[i].cloud?.accountID = settings.accountID ?? accountID
            // Для следующего уточнения сохраняем только время и язык, без снимка календарей.
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
                    let completion = try await cloud.respond(body: request.body, accountID: accountID) { [weak self] delta in
                        guard let self, requestID == token else { return }
                        cloudPreview += delta
                    }
                    try Task.checkCancellation()
                    guard requestID == token, let index = archive.threads.firstIndex(where: { $0.id == threadID }) else { return }
                    let updated = try Self.cloudReply(completion.response, to: archive.threads[index], drafts: request.drafts,
                                                      text: text, context: localContext, edit: edit, usage: completion.usage)
                    let previous = archive.threads[index]
                    archive.threads[index] = updated
                    if !persist() { archive.threads[index] = previous }
                } catch {
                    if requestID == token, !Task.isCancelled {
                        self.error = error is DecodingError ? AssistantCloudStream.invalid.message : error.localizedDescription
                    }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Ответ меняет только историю и карточки. Сохранение в библиотеку остаётся отдельным действием пользователя.
    static func cloudReply(_ reply: AssistantResponse, to original: AssistantThread, drafts: [String: UUID],
                           text: String, context: AssistantContext, edit: AssistantTextEdit?, usage: AssistantCloudUsage? = nil) throws -> AssistantThread {
        var thread = original
        var message = reply.message
        let questions = reply.questions ?? []
        if questions.isEmpty {
            let destination = AssistantIntentPolicy.destination(in: text,
                choices: context.folders.map { ($0.id, $0.name) }, calendar: false,
                replyingToQuestion: thread.messages.dropLast().last?.questions.isEmpty == false)
            for var proposal in reply.actions ?? [] {
                guard proposal.kind == .task, proposal.linkTo == nil else { throw AssistantCloudStream.invalid }
                let existing = drafts[proposal.key].flatMap { id in
                    thread.actions.firstIndex { $0.id == id && [.pending, .failed].contains($0.status) }
                }
                if proposal.key.hasPrefix("draft_"), existing == nil { throw AssistantCloudStream.invalid }
                let old = existing.map { thread.actions[$0] }
                proposal.key = old?.proposal.key ?? UUID().uuidString
                proposal.folderID = destination.specified ? destination.id : (old?.proposal.folderID ?? context.defaultFolderID)
                if AssistantIntentPolicy.noDeadline(text) { proposal.date = nil; proposal.time = nil }
                if let existing, var old {
                    old.proposal = proposal; old.error = nil; old.status = .pending
                    thread.actions[existing] = old
                } else {
                    let action = AssistantAction(proposal: proposal, context: context)
                    thread.actions.append(action)
                    thread.cloud?.draftIDs?.insert(action.id)
                }
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
        thread.messages.append(.init(role: .assistant, text: message, questions: questions, cloudUsage: usage))
        return thread
    }
}
