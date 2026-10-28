import Foundation
import SwiftData

extension TaskService {
    func assistantTask(id: UUID) throws -> PlannerTask? {
        try context.fetch(FetchDescriptor<PlannerTask>(predicate: #Predicate { $0.id == id })).first
    }
    /// Полностью заполненная задача и подзадачи фиксируются одним save. UUID принадлежит действию.
    func createAssistantTask(_ action: AssistantAction, folders: [TaskFolder]) throws -> PlannerTask {
        if let existing = try assistantTask(id: action.id) { return existing }
        let p = action.proposal
        guard let destination = ActionPlanValidator.folder(p.folderID ?? ""), destination.isPrimaryFolder else {
            throw AssistantFailure(message: "Выберите существующую папку.")
        }
        var folder: TaskFolder?
        if case .folder(let id) = destination {
            guard let found = folders.first(where: { $0.id == id && !$0.isDeleted }) else { throw AssistantFailure(message: "Выберите существующую папку.") }
            folder = found
        }
        let deadline = try p.date.map { try ActionPlanValidator.date($0, time: p.time, zone: action.context.timeZoneID) }
        let task = PlannerTask(title: p.title.trimmingCharacters(in: .whitespacesAndNewlines), folder: folder)
        task.id = action.id; task.descriptionText = p.description ?? ""
        task.systemFolderKind = destination == .week ? "week" : destination == .month ? "month" : "inbox"
        if p.today == true { task.focusDay = LocalDay.key(for: .now) }
        task.deadlineDate = deadline; task.deadlineIncludesTime = p.time != nil
        task.deadlineTimeZoneID = deadline == nil ? nil : action.context.timeZoneID
        guard persistAssistant({
            context.insert(task)
            for (index, title) in (p.checklist ?? []).enumerated() {
                context.insert(TaskChecklistItem(task: task, title: title, sortOrder: index))
            }
        }) else { throw AssistantFailure(message: "Не удалось сохранить задачу.") }
        notificationChanged?(task.id, deadline != nil)
        return task
    }
}
