import SwiftUI
import Observation

/// Навигация обновляется атомарно. Локальные переходы строк задаются их представлениями.
@MainActor
func withImmediateNavigationUpdate(_ update: () -> Void) {
    withTransaction(Transaction(animation: nil), update)
}

/// Состояние принадлежит окну; методы меняют связанные значения одновременно.
@MainActor @Observable
final class WorkspaceState {
    private(set) var filter: TaskFilter? = .inbox
    private(set) var selectedTaskID: UUID?
    private(set) var search = ""
    private(set) var createdTaskID: UUID?
    private(set) var completedTasksExpanded = false

    func selectFilter(_ filter: TaskFilter) {
        guard self.filter != filter else { return }
        withImmediateNavigationUpdate {
            self.filter = filter
            search = ""
            createdTaskID = nil
            // Переход в папку показывает список, а задачу пользователь открывает явно.
            selectedTaskID = nil
            completedTasksExpanded = false
        }
    }

    func setCompletedTasksExpanded(_ expanded: Bool) { completedTasksExpanded = expanded }

    func updateSearch(_ search: String, visibleIDs: [UUID]) {
        withImmediateNavigationUpdate {
            self.search = search
            if !visibleIDs.contains(where: { $0 == selectedTaskID }) {
                selectedTaskID = visibleIDs.first
                createdTaskID = nil
            }
        }
    }

    func selectTask(_ id: UUID?) {
        guard selectedTaskID != id else { return }
        withImmediateNavigationUpdate {
            selectedTaskID = id
            createdTaskID = nil
        }
    }

    func selectCreatedTask(_ id: UUID) {
        withImmediateNavigationUpdate {
            search = ""
            createdTaskID = id
            selectedTaskID = id
        }
    }

    func openLinkedTask(_ task: PlannerTask, visibleIDs: [UUID]) {
        withImmediateNavigationUpdate {
            if !visibleIDs.contains(task.id) { filter = task.primaryFolder }
            search = ""
            createdTaskID = nil
            selectedTaskID = task.id
        }
    }

    /// Удаление открытой задачи закрывает карточку; соседняя задача сама не открывается.
    func selectAfterDeletingTask(_ deletedID: UUID) {
        guard selectedTaskID == deletedID else { return }
        selectTask(nil)
        if createdTaskID == deletedID { createdTaskID = nil }
    }

    /// Уход активной задачи из папки не раскрывает выполненные и не меняет текущую папку.
    func selectAfterMovingTask(_ id: UUID, previous: TaskListSnapshot, current: TaskListSnapshot) {
        guard selectedTaskID == id, !current.taskIDs.contains(id) else { return }
        let active = previous.activeTasks.contains { $0.id == id }
        reconcileSelection(previousIDs: (active ? previous.activeTasks : previous.completedTasks).map(\.id),
                           visibleIDs: (active ? current.activeTasks : current.completedTasks).map(\.id))
    }

    /// Если строка исчезла, ищем соседей в прежнем визуальном порядке: сначала ниже, затем выше.
    func reconcileSelection(previousIDs: [UUID], visibleIDs: [UUID]) {
        guard let selected = selectedTaskID, !visibleIDs.contains(selected) else { return }
        let remaining = Set(visibleIDs)
        let replacement: UUID?
        if let index = previousIDs.firstIndex(of: selected) {
            replacement = previousIDs.dropFirst(index + 1).first(where: remaining.contains)
                ?? previousIDs.prefix(index).reversed().first(where: remaining.contains)
                ?? visibleIDs.first
        } else {
            replacement = visibleIDs.first
        }
        selectTask(replacement)
    }
}
