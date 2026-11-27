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
