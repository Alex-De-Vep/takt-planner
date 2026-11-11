import Foundation
import SwiftData
import Testing
import PlannerLocalization
@testable import Planner

@MainActor
struct TaskRowContentTests {
    @Test func outgoingRowKeepsItsContentsAfterDeletingTaskAndFolder() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let service = TaskService(context: context)
        let now = Date.now
        let folder = TaskFolder(name: "Проект", sortOrder: 0)
        let task = PlannerTask(title: "Удаляемая задача", folder: folder, now: now)
        task.completedAt = now
        task.focusDay = LocalDay.key(for: now)
        context.insert(task)
        let deadline = TaskDeadline(date: now, includesTime: true)
        #expect(service.setDeadline(task, to: deadline))
        let id = task.id
        let row = TaskRowContent(task, now: now, strings: Translations(language: .russian))

        // Модель и её связи уже удалены, но SwiftUI ещё может рисовать уходящую строку.
        #expect(service.delete(task))
        #expect(service.deleteFolder(folder))
        #expect(try context.fetch(FetchDescriptor<PlannerTask>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TaskFolder>()).isEmpty)
        #expect(row.id == id)
        #expect(row.title == "Удаляемая задача" && row.folderName == "Проект")
        #expect(row.createdAt == now && row.isCompleted && row.isFocused)
        #expect(row.deadline == deadline)
    }
}
