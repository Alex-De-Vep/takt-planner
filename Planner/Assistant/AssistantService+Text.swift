import Foundation

extension AssistantService {
    var activeTextEdit: AssistantTextEdit? {
        current?.textEdits?.first { $0.id == current?.activeTextEditID && $0.status == .pending }
    }
    func hasUnreviewedText(for id: UUID) -> Bool {
        current?.textEdits?.contains { $0.target == .proposal && $0.before.id == id && [.pending, .applying].contains($0.status) && $0.hasChanges } == true
    }
    func chooseTextEdit(_ id: UUID?) {
        guard !generating, !applying, let t = currentIndex else { return }
        archive.threads[t].activeTextEditID = id; persist()
    }
    @discardableResult func beginTextEdit(task: PlannerTask, tasks: TaskService) -> Bool {
        do { return beginTextEdit(target: .savedTask, snapshot: try tasks.assistantTextSnapshot(task)) }
        catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func beginTextEdit(proposal: AssistantAction) -> Bool {
        guard proposal.proposal.kind == .task, [.pending, .failed].contains(proposal.status) else { return false }
        return beginTextEdit(target: .proposal, snapshot: Self.textSnapshot(proposal))
    }
    private func beginTextEdit(target: AssistantTextEdit.Target, snapshot: AssistantTextSnapshot) -> Bool {
        guard !generating, !applying, !storageFailed, let t = currentIndex else { return false }
        let previous = archive
        var edits = archive.threads[t].textEdits ?? []
        if let existing = edits.first(where: { $0.target == target && $0.before.id == snapshot.id && $0.status == .pending }) {
            archive.threads[t].activeTextEditID = existing.id
        } else {
            let edit = AssistantTextEdit(target: target, before: snapshot)
            edits.append(edit); archive.threads[t].textEdits = edits
            archive.threads[t].activeTextEditID = edit.id
        }
        guard persist() else { archive = previous; return false }
        error = nil; return true
    }
    static func textSnapshot(_ action: AssistantAction) -> AssistantTextSnapshot {
        .init(id: action.id, title: action.proposal.title, description: action.proposal.description ?? "",
            checklist: (action.proposal.checklist ?? []).map { .init(id: UUID(), title: $0, isCompleted: false) })
    }
    func updateTextEdit(_ edit: AssistantTextEdit) {
        guard !generating, !applying, edit.status == .pending, edit.committed == nil,
              let t = currentIndex, let e = archive.threads[t].textEdits?.firstIndex(where: { $0.id == edit.id }) else { return }
        let previous = archive
        archive.threads[t].textEdits?[e] = edit
        if !persist() { archive = previous }
    }
    func cancelTextEdit(_ id: UUID) {
        guard !generating, !applying, let t = currentIndex,
              let e = archive.threads[t].textEdits?.firstIndex(where: { $0.id == id }),
              archive.threads[t].textEdits?[e].committed == nil else { return }
        let previous = archive
        archive.threads[t].textEdits?[e].status = .cancelled
        if archive.threads[t].activeTextEditID == id { archive.threads[t].activeTextEditID = nil }
        if !persist() { archive = previous }
    }
    func refreshTextEdit(_ id: UUID, tasks: TaskService) {
        guard !generating, !applying, let t = currentIndex,
              let e = archive.threads[t].textEdits?.firstIndex(where: { $0.id == id }),
              let old = archive.threads[t].textEdits?[e], old.committed == nil else { return }
        do {
            let snapshot: AssistantTextSnapshot
            if old.target == .savedTask {
                guard let task = try tasks.assistantTask(id: old.before.id) else { throw AssistantFailure(message: "Задача больше не существует.") }
                snapshot = try tasks.assistantTextSnapshot(task)
            } else {
                guard let action = current?.actions.first(where: { $0.id == old.before.id && [.pending, .failed].contains($0.status) }) else { throw AssistantFailure(message: "Предложение задачи больше недоступно.") }
                snapshot = Self.textSnapshot(action)
            }
            let previous = archive
            archive.threads[t].textEdits?[e].status = .cancelled
            var replacement = AssistantTextEdit(target: old.target, before: snapshot)
            replacement.lastRequest = old.lastRequest
            archive.threads[t].textEdits?.append(replacement)
            archive.threads[t].activeTextEditID = replacement.id
            if !persist() { archive = previous }
        } catch { self.error = error.localizedDescription }
    }
    /// Явная карточка назначения важнее текущего выделения в соседней колонке.
    func routeTextRequest(_ text: String, context: AssistantContext, tasks: TaskService) -> Bool {
        if activeTextEdit != nil { sendText(text, language: context.language); return true }
        guard AssistantTextPrompt.isTextRequest(text) else { return false }
        let pending = current?.actions.filter { $0.proposal.kind == .task && [.pending, .failed].contains($0.status) } ?? []
        let explicitTask = AssistantIntentPolicy.matches(text, "открыт|выбран|(?:open|selected|current) task")
        if !explicitTask, pending.count == 1 {
            if beginTextEdit(proposal: pending[0]) { sendText(text, language: context.language) }
        } else if !explicitTask, pending.count > 1 {
            error = "Выберите «Доработать» у нужного предложения задачи."
        } else if let id = context.taskID.flatMap(UUID.init(uuidString:)), let task = try? tasks.assistantTask(id: id) {
            if beginTextEdit(task: task, tasks: tasks) { sendText(text, language: context.language) }
        } else { error = "Откройте задачу и включите её контекст или выберите предложение в чате." }
        return true
    }
    func sendText(_ text: String, language: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 8000 else { error = "Сообщение слишком длинное. Сократите его до 8000 символов."; return }
        guard current?.usesCloudModel != true, !generating, !applying, !storageFailed, model.canChat, let t = currentIndex, let edit = activeTextEdit, edit.committed == nil else { return }
        error = nil
        let previous = archive
        if let e = archive.threads[t].textEdits?.firstIndex(where: { $0.id == edit.id }) {
            archive.threads[t].textEdits?[e].lastRequest = text
        }
        archive.threads[t].draft = ""
        archive.threads[t].messages.append(.init(role: .user, text: text))
        if archive.threads[t].messages.count == 1 { archive.threads[t].title = String(text.prefix(60)) }
        guard persist() else { archive = previous; return }
        let snapshot = archive.threads[t]
        let token = UUID(); requestID = token; generating = true
        generation = Task { [weak self] in
            guard let self else { return }
            var acquired = false
            do {
                // Проверяем размер до загрузки весов: слишком большой запрос не занимает RAM модели.
                let prompt = try AssistantTextPrompt.request(edit: edit, thread: snapshot, language: language)
                try await model.beginUse(); acquired = true
                let output = try await model.backend.respond(instructions: AssistantTextPrompt.instructions, prompt: prompt)
                try Task.checkCancellation()
                let response = try ActionPlanValidator.decode(output)
                guard (response.actions ?? []).isEmpty else { throw AssistantFailure(message: "Ответ редактора должен содержать только текстовые правки.") }
                guard token == requestID, let t = archive.threads.firstIndex(where: { $0.id == snapshot.id }),
                      let e = archive.threads[t].textEdits?.firstIndex(where: { $0.id == edit.id }) else { throw CancellationError() }
                let questions = response.questions ?? []
                if questions.isEmpty {
                    guard let change = response.textEdit else { throw AssistantFailure(message: "Модель не предложила текстовых изменений. Уточните запрос.") }
                    var updated = archive.threads[t].textEdits![e]
                    try updated.propose(change)
                    archive.threads[t].textEdits?[e] = updated
                }
                let message = language == "en" ? (questions.isEmpty ? "Review Before → After. Nothing has been saved to the task." : "Please clarify the task details.") : (questions.isEmpty ? "Проверьте «Было → Стало». Изменения задачи ещё не сохранены." : "Уточните детали задачи.")
                archive.threads[t].messages.append(.init(role: .assistant, text: message, questions: questions))
                persist()
            } catch {
                if token == requestID, !Task.isCancelled, !(error is CancellationError) {
                    self.error = error is DecodingError ? "Не удалось проверить ответ модели. Упростите запрос и повторите." : error.localizedDescription
                }
            }
            if acquired { await model.endUse() }
            if token == requestID { generating = false; generation = nil }
        }
    }
    func applyTextEdit(_ id: UUID, tasks: TaskService) {
        guard !generating, !applying, !storageFailed, let t = currentIndex,
              let e = archive.threads[t].textEdits?.firstIndex(where: { $0.id == id }),
              var edit = archive.threads[t].textEdits?[e], edit.status == .pending, edit.hasSelection else { return }
        applying = true; error = nil; defer { applying = false }
        do {
            // Повторно валидируем и ручные исправления, а не только JSON модели.
            var checked = edit
            try checked.propose(.init(title: edit.includeTitle ? edit.change.title : nil,
                description: edit.includeDescription ? edit.change.description : nil,
                checklist: edit.includeChecklist ? edit.additions.filter(\.included).map(\.title) : nil))
            guard !edit.includeChecklist || !edit.additions.contains(where: { $0.included && $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw AssistantFailure(message: "Введите название подзадачи.")
            }
            var seen = Set(edit.target == .savedTask ? edit.before.checklist.map { AssistantTextEdit.normalized($0.title) } : [])
            for index in edit.additions.indices where edit.additions[index].included {
                edit.additions[index].title = edit.additions[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !seen.insert(AssistantTextEdit.normalized(edit.additions[index].title)).inserted { edit.additions[index].included = false }
            }
            if edit.target == .proposal {
                guard let a = archive.threads[t].actions.firstIndex(where: { $0.id == edit.before.id && [.pending, .failed].contains($0.status) }) else { throw AssistantFailure(message: "Предложение задачи больше недоступно.") }
                let value = Self.textSnapshot(archive.threads[t].actions[a])
                guard value.title == edit.before.title, value.description == edit.before.description,
                      value.checklist.map(\.title) == edit.before.checklist.map(\.title) else { throw AssistantFailure(message: AssistantTextEdit.conflict) }
                let previous = archive
                let selected = edit.selected
                archive.threads[t].actions[a].proposal.title = selected.title
                archive.threads[t].actions[a].proposal.description = selected.description
                archive.threads[t].actions[a].proposal.checklist = selected.checklist.map(\.title)
                edit.status = .accepted
                archive.threads[t].textEdits?[e] = edit
                archive.threads[t].activeTextEditID = nil
                if !persist() { archive = previous }
                return
            }
            edit.committed = edit.committed ?? edit.selected
            edit.status = .applying; edit.error = nil
            archive.threads[t].textEdits?[e] = edit
            guard persist() else { archive.threads[t].textEdits?[e].status = .pending; return }
            try tasks.applyAssistantText(edit)
            edit.status = .applied
            archive.threads[t].textEdits?[e] = edit
            if archive.threads[t].activeTextEditID == id { archive.threads[t].activeTextEditID = nil }
            // SwiftData и JSON — разные хранилища. При сбое журнал остаётся applying;
            // восстановление сверит готовый текст и UUID пунктов, не повторяя запись.
            if !persist() { storageFailed = true }
        } catch {
            edit.status = .pending; edit.error = error.localizedDescription
            edit.committed = nil
            archive.threads[t].textEdits?[e] = edit
            persist()
        }
    }
}
