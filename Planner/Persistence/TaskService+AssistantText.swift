import Foundation
import SwiftData

extension TaskService {
    func assistantTextSnapshot(_ task: PlannerTask) throws -> AssistantTextSnapshot {
        guard !task.isDeleted else { throw AssistantFailure(message: "Задача больше не существует.") }
        guard titleDrafts[task.id] == nil, descriptionDrafts[task.id] == nil,
              !task.orderedChecklistItems.contains(where: { checklistDrafts[$0.id] != nil }) else {
            throw AssistantFailure(message: "Сначала повторите сохранение черновика задачи.")
        }
        return AssistantTextSnapshot(id: task.id, title: task.title, description: task.descriptionText,
            checklist: task.orderedChecklistItems.map { .init(id: $0.id, title: $0.title, isCompleted: $0.isCompleted) })
    }
    /// Одно сохранение меняет только выбранные поля. UUID добавлений служат квитанцией после сбоя журнала.
    func applyAssistantText(_ edit: AssistantTextEdit, now: Date = .now) throws {
        guard let task = try assistantTask(id: edit.before.id) else { throw AssistantFailure(message: "Задача больше не существует.") }
        let current = try assistantTextSnapshot(task)
        let expected = edit.committed ?? edit.selected
        let additions = expected.checklist.filter { item in !edit.before.checklist.contains { $0.id == item.id } }
        let changesTitle = expected.title != edit.before.title
        let changesDescription = expected.description != edit.before.description
        let alreadyApplied = (!changesTitle || current.title == expected.title) &&
            (!changesDescription || current.description == expected.description) &&
            additions.allSatisfy { item in current.checklist.contains(item) }
        if alreadyApplied { return }
        guard (!changesTitle || current.title == edit.before.title),
              (!changesDescription || current.description == edit.before.description),
              (additions.isEmpty || current.checklist == edit.before.checklist) else {
            throw AssistantFailure(message: AssistantTextEdit.conflict)
        }
        let previousUpdatedAt = task.updatedAt
        let previousItems = task.checklistItems
        var inserted: [TaskChecklistItem] = []
        guard persistAssistant({
            if changesTitle { task.title = expected.title }
            if changesDescription { task.descriptionText = expected.description }
            let order = (task.orderedChecklistItems.map(\.sortOrder).max() ?? -1) + 1
            for (index, addition) in additions.enumerated() {
                let item = TaskChecklistItem(task: task, title: addition.title, sortOrder: order + index)
                item.id = addition.id
                context.insert(item)
                inserted.append(item)
            }
            task.updatedAt = now
            // Регистрируем отложенные изменения до save, чтобы rollback восстановил и живые объекты.
            context.processPendingChanges()
        }) else {
            // SwiftData может оставить изменённые значения в уже наблюдаемом объекте после rollback.
            // Возвращаем именно текущий снимок до записи, включая не затронутые помощником поля.
            for item in inserted where item.modelContext === context { context.delete(item) }
            task.title = current.title
            task.descriptionText = current.description
            task.updatedAt = previousUpdatedAt
            task.checklistItems = previousItems
            context.processPendingChanges()
            throw AssistantFailure(message: "Не удалось сохранить задачу.")
        }
        if changesTitle { notificationChanged?(task.id, false) }
    }
}
