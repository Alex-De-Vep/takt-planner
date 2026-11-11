import Foundation

extension AssistantService {
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

    func chooseLocalModel() {
        changeModel { $0.chooseModel(nil) }
        model.restoreIfInstalled()
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

    func sendCloud(_ input: String, context: AssistantContext, tasks: TaskService?) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !generating, !applying, !storageFailed,
              let i = currentIndex, current?.usesCloudModel == true, let settings = current?.cloud else { return }
        guard text.count <= 8000 else { error = "Сообщение слишком длинное. Сократите его до 8000 символов."; return }
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
            let edit: AssistantTextEdit?
            if !tools { edit = nil }
            else if let active = activeTextEdit {
                guard active.committed == nil else { return }
                edit = active
            } else if let id = context.taskID.flatMap(UUID.init(uuidString:)), let tasks {
                guard let task = try tasks.assistantTask(id: id) else { throw AssistantFailure(message: "Задача больше не существует.") }
                edit = AssistantTextEdit(target: .savedTask, before: try tasks.assistantTextSnapshot(task))
            } else { edit = nil }

            let request: AssistantCloudRequest
            if let profile, let model = gatewayModel {
                request = try AssistantCloudRequest(thread: archive.threads[i], text: text, context: context, edit: edit,
                                                    modelID: model.id, effort: cloudEffort, gateway: profile.gateway, supportsTools: tools)
            } else if settings.gateway == nil, let model = cloudModel {
                request = try AssistantCloudRequest(thread: archive.threads[i], text: text, context: context, edit: edit,
                                                    model: model, effort: cloudEffort)
            } else { return }
            let previous = archive
            if profile == nil { archive.threads[i].cloud?.accountID = settings.accountID ?? accountID }
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
                    let updated = try Self.cloudReply(completion.response, to: archive.threads[index], drafts: request.drafts,
                                                      text: text, context: localContext, edit: edit, usage: completion.usage)
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
                           text: String, context: AssistantContext, edit: AssistantTextEdit?, usage: AssistantCloudUsage? = nil) throws -> AssistantThread {
        var thread = original
        var message = reply.message
        let questions = reply.questions ?? []
        if questions.isEmpty {
            let destination = AssistantIntentPolicy.destination(in: text,
                choices: context.folders.map { ($0.id, $0.name) }, calendar: false,
                replyingToQuestion: thread.messages.dropFirst(thread.cloud?.historyStart ?? 0).dropLast().last?.questions.isEmpty == false)
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
