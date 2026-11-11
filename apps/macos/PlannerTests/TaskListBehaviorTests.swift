import Foundation
import SwiftData
import Testing
@testable import Planner

/// Регрессии порядка и выбора проверяются на тех же проекциях, которые использует интерфейс.
@MainActor
struct TaskListBehaviorTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return calendar
    }

    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private func snapshot(_ tasks: [PlannerTask], filter: TaskFilter = .inbox) -> TaskListSnapshot {
        TaskListSnapshot(tasks: tasks, filter: filter, now: date(25), calendar: calendar)
    }

    @Test func starsAndRenamingPreserveCreationOrderAndGroups() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        let earlier = PlannerTask(title: "Ранее", now: date(20))
        let yesterday = PlannerTask(title: "Вчера", now: date(24))
        let todayFirst = PlannerTask(title: "Первая", now: date(25))
        let todaySecond = PlannerTask(title: "Вторая", now: date(25))
        todayFirst.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        todaySecond.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let tasks = [earlier, todaySecond, yesterday, todayFirst]
        for task in tasks { container.mainContext.insert(task) }
        try container.mainContext.save()

        let expected = [todayFirst.id, todaySecond.id, yesterday.id, earlier.id]
        let initial = snapshot(tasks)
        let expectedGroups: [[UUID]] = [expected]
        let initialGroups = initial.sections.map { $0.tasks.map(\.id) }
        #expect(initial.taskIDs == expected)
        #expect(initial.sections.map(\.id) == ["active"])
        #expect(initialGroups == expectedGroups)

        let state = WorkspaceState()
        state.selectTask(todaySecond.id)
        service.toggleToday(earlier, now: date(25, hour: 15), calendar: calendar)
        service.rename(yesterday, to: "Новое название", now: date(25, hour: 16))
        // Намеренно меняем входной порядок, в том числе задач с одинаковым createdAt.
        let changed = snapshot(Array(tasks.reversed()))
        let changedGroups = changed.sections.map { $0.tasks.map(\.id) }
        state.reconcileSelection(previousIDs: initial.taskIDs, visibleIDs: changed.taskIDs)
        #expect(changed.taskIDs == expected)
        #expect(changed.sections.map(\.id) == initial.sections.map(\.id))
        #expect(changedGroups == initialGroups)
        #expect(state.selectedTaskID == todaySecond.id)
        #expect(earlier.updatedAt == date(25, hour: 15))

        service.toggleToday(earlier, now: date(25, hour: 17), calendar: calendar)
        #expect(snapshot(tasks).taskIDs == expected)
        #expect(!earlier.isFocused(on: date(25), calendar: calendar))
    }

    @Test func todaySelectionMovesNextThenPreviousThenClears() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        let first = PlannerTask(title: "Верхняя", now: date(25))
        let middle = PlannerTask(title: "Средняя", now: date(24))
        let last = PlannerTask(title: "Нижняя", now: date(23))
        let tasks = [last, first, middle]
        for task in tasks {
            container.mainContext.insert(task)
            service.toggleToday(task, now: date(25), calendar: calendar)
        }
        let state = WorkspaceState()
        state.selectFilter(.today)
        state.selectTask(middle.id)

        func unstar(_ task: PlannerTask) {
            let previous = snapshot(tasks, filter: .today).taskIDs
            service.toggleToday(task, now: date(25), calendar: calendar)
            state.reconcileSelection(previousIDs: previous, visibleIDs: snapshot(tasks, filter: .today).taskIDs)
        }

        unstar(middle)
        #expect(snapshot(tasks, filter: .today).taskIDs == [first.id, last.id])
        #expect(state.selectedTaskID == last.id)
        unstar(last)
        #expect(state.selectedTaskID == first.id)
        unstar(first)
        #expect(state.selectedTaskID == nil)
        #expect(snapshot(tasks, filter: .today).taskIDs.isEmpty)
        #expect(snapshot(tasks).taskIDs == [first.id, middle.id, last.id])
    }

    @Test func removingAnotherTodayTaskKeepsTheSelection() {
        let first = PlannerTask(title: "Выбранная", now: date(25))
        let second = PlannerTask(title: "Другая", now: date(24))
        let third = PlannerTask(title: "Последняя", now: date(23))
        let tasks = [first, second, third]
        for task in tasks { task.focusDay = LocalDay.key(for: date(25), calendar: calendar) }
        let state = WorkspaceState()
        let previous = snapshot(tasks, filter: .today).taskIDs
        state.selectFilter(.today)
        state.selectTask(first.id)
        second.focusDay = nil
        let visible = snapshot(tasks, filter: .today).taskIDs
        state.reconcileSelection(previousIDs: previous, visibleIDs: visible)
        #expect(visible == [first.id, third.id])
        #expect(state.selectedTaskID == first.id)
    }

    @Test func removingNewestTaskDoesNotReorderOtherFolderGroups() {
        let firstFolder = TaskFolder(name: "Первая папка", sortOrder: 0)
        let secondFolder = TaskFolder(name: "Вторая папка", sortOrder: 1)
        let newest = PlannerTask(title: "Новая в первой", folder: firstFolder, now: date(25))
        let oldest = PlannerTask(title: "Старая в первой", folder: firstFolder, now: date(23))
        let middle = PlannerTask(title: "Во второй", folder: secondFolder, now: date(24))
        let tasks = [middle, oldest, newest]
        for task in tasks { task.focusDay = LocalDay.key(for: date(25), calendar: calendar) }
        let before = snapshot(tasks, filter: .today)
        #expect(before.taskIDs == [newest.id, oldest.id, middle.id])

        newest.focusDay = nil
        let after = snapshot(tasks, filter: .today)
        #expect(after.taskIDs == [oldest.id, middle.id])
        #expect(after.sections.map(\.id) == before.sections.map(\.id))
    }

    @Test func folderSwitchResetsSearchSelectionAndCompletedPanel() {
        let folder = TaskFolder(name: "Проект", sortOrder: 0)
        let active = PlannerTask(title: "Активная", folder: folder, now: date(24))
        let completed = PlannerTask(title: "Выполненная", folder: folder, now: date(25))
        completed.completedAt = date(25)
        let state = WorkspaceState()
        let previouslyCreated = UUID()
        state.selectCreatedTask(previouslyCreated)
        state.updateSearch("поиск", visibleIDs: [previouslyCreated])
        state.setCompletedTasksExpanded(true)

        let target = snapshot([completed, active], filter: .folder(folder.id))
        state.selectFilter(.folder(folder.id))
        #expect(state.filter == .folder(folder.id))
        #expect(state.search.isEmpty)
        #expect(state.createdTaskID == nil)
        #expect(state.selectedTaskID == nil)
        #expect(!state.completedTasksExpanded)
        #expect(target.sections.last?.id == "completed")
        // Позднее согласование списка не выбирает первую строку за пользователя.
        state.reconcileSelection(previousIDs: [previouslyCreated], visibleIDs: target.taskIDs)
        #expect(state.selectedTaskID == nil)
    }

    @Test func folderWithOnlyCompletedTasksDoesNotOpenATaskEvenWhenReturning() {
        let folder = TaskFolder(name: "Архив", sortOrder: 0)
        let completed = PlannerTask(title: "Выполненная", folder: folder, now: date(25))
        completed.completedAt = date(25)
        let target = snapshot([completed], filter: .folder(folder.id))
        let state = WorkspaceState()
        for _ in 0..<2 {
            state.selectFilter(.folder(folder.id))
            state.reconcileSelection(previousIDs: [], visibleIDs: target.taskIDs)
            #expect(target.activeTasks.isEmpty && target.completedTasks.count == 1)
            #expect(state.selectedTaskID == nil && !state.completedTasksExpanded)
            // Ручное раскрытие и открытие выполненной задачи по-прежнему доступны.
            state.setCompletedTasksExpanded(true)
            state.selectTask(completed.id)
            #expect(state.selectedTaskID == completed.id && state.completedTasksExpanded)
            state.selectFilter(.inbox)
            #expect(state.selectedTaskID == nil && !state.completedTasksExpanded)
        }
        // Календарь и уведомления открывают конкретную задачу явно, в том числе выполненную.
        state.openLinkedTask(completed, visibleIDs: [])
        #expect(state.filter == .folder(folder.id) && state.selectedTaskID == completed.id)
    }

    @Test func selectingCurrentFolderKeepsTheOpenTask() {
        let state = WorkspaceState(), id = UUID()
        state.selectTask(id)
        state.setCompletedTasksExpanded(true)
        state.selectFilter(.inbox)
        #expect(state.selectedTaskID == id && state.completedTasksExpanded)
    }

    @Test func deletingActiveTasksClearsSelectionAndNeverSelectsCompletedTasks() {
        let first = UUID(), middle = UUID(), last = UUID(), completed = UUID()
        let state = WorkspaceState()
        state.selectTask(middle)
        state.selectAfterDeletingTask(middle)
        #expect(state.selectedTaskID == nil)

        // У нижней активной строки выбирается предыдущая активная, а не первая выполненная.
        state.selectTask(last)
        state.selectAfterDeletingTask(last)
        #expect(state.selectedTaskID == nil)
        state.selectTask(first)
        state.selectAfterDeletingTask(first)
        #expect(state.selectedTaskID == nil)

        // Последующее обновление общего списка тоже не должно выбрать скрытую выполненную задачу.
        state.reconcileSelection(previousIDs: [first, completed], visibleIDs: [completed])
        #expect(state.selectedTaskID == nil)
    }

    @Test func deletingCompletedTasksClearsSelection() {
        let first = UUID(), last = UUID()
        let state = WorkspaceState()
        state.selectTask(first)
        state.selectAfterDeletingTask(first)
        #expect(state.selectedTaskID == nil)
        state.selectTask(last)
        state.selectAfterDeletingTask(last)
        #expect(state.selectedTaskID == nil)
    }

    @Test func deletingCreatedTaskClearsItsFocusMarkerAndDoesNotReopenNeighbor() {
        let state = WorkspaceState(), deleted = UUID(), neighbor = UUID()
        state.selectCreatedTask(deleted)
        state.selectAfterDeletingTask(deleted)
        state.reconcileSelection(previousIDs: [deleted, neighbor], visibleIDs: [neighbor])
        #expect(state.selectedTaskID == nil && state.createdTaskID == nil)
    }

    @Test func deletingUnselectedTaskPreservesCurrentSelection() {
        let active = UUID(), completed = UUID()
        let state = WorkspaceState()
        state.selectTask(active)
        state.selectAfterDeletingTask(completed)
        #expect(state.selectedTaskID == active)
        state.selectTask(completed)
        state.selectAfterDeletingTask(active)
        #expect(state.selectedTaskID == completed)
    }

    @Test func completedTasksStayLastAndSortedByCreation() {
        let active = PlannerTask(title: "В работе", now: date(20))
        let oldCompleted = PlannerTask(title: "Старая выполненная", now: date(23))
        let newCompleted = PlannerTask(title: "Новая выполненная", now: date(24))
        oldCompleted.completedAt = date(25, hour: 18)
        newCompleted.completedAt = date(25, hour: 10)
        let result = snapshot([oldCompleted, newCompleted, active])
        #expect(result.taskIDs == [active.id, newCompleted.id, oldCompleted.id])
        #expect(result.sections.last?.tasks.map(\.id) == [newCompleted.id, oldCompleted.id])
        #expect(result.activeTasks.map(\.id) == [active.id])
        #expect(result.completedTasks.map(\.id) == [newCompleted.id, oldCompleted.id])
    }

    @Test func completedPanelContainsEveryMatchingTaskAndRespectsSearch() {
        let folder = TaskFolder(name: "Проект", sortOrder: 0)
        let anotherFolder = TaskFolder(name: "Другое", sortOrder: 1)
        let completed = (0..<120).map { index in
            let task = PlannerTask(title: "Готово \(index)", folder: folder, now: date(25).addingTimeInterval(Double(index)))
            task.completedAt = date(25, hour: 18)
            return task
        }
        let active = PlannerTask(title: "Готово позже", folder: folder, now: date(25))
        let unrelated = PlannerTask(title: "Готово в другой папке", folder: anotherFolder, now: date(25))
        unrelated.completedAt = date(25, hour: 18)
        let tasks = completed + [active, unrelated]
        let result = snapshot(tasks, filter: .folder(folder.id))
        let expectedIDs = completed.reversed().map(\.id)
        #expect(result.completedTasks.count == 120)
        #expect(result.completedTasks.map(\.id) == expectedIDs)
        #expect(result.activeTasks.map(\.id) == [active.id])

        let searched = TaskListSnapshot(tasks: tasks, filter: .folder(folder.id), search: "Готово 119", now: date(25), calendar: calendar)
        #expect(searched.completedTasks.map(\.id) == [completed[119].id])
        #expect(searched.activeTasks.isEmpty)
    }

    @Test func completingAndRestoringTheOpenTaskKeepsSelection() {
        let first = PlannerTask(title: "Первая", now: date(25))
        let second = PlannerTask(title: "Вторая", now: date(24))
        let tasks = [first, second]
        let state = WorkspaceState()
        state.selectTask(first.id)
        let initial = snapshot(tasks)

        first.completedAt = date(25, hour: 18)
        let completed = snapshot(tasks)
        state.reconcileSelection(previousIDs: initial.taskIDs, visibleIDs: completed.taskIDs)
        #expect(state.selectedTaskID == first.id)
        #expect(completed.activeTasks.map(\.id) == [second.id])
        #expect(completed.completedTasks.map(\.id) == [first.id])

        first.completedAt = nil
        let restored = snapshot(tasks)
        state.reconcileSelection(previousIDs: completed.taskIDs, visibleIDs: restored.taskIDs)
        #expect(state.selectedTaskID == first.id)
        #expect(restored.activeTasks.map(\.id) == [first.id, second.id])
        #expect(restored.completedTasks.isEmpty)
    }

    @Test func creationOrderSurvivesReopeningTheLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Order.store")
        let expected: [UUID] = try autoreleasepool {
            let container = try PlannerPersistence.makeContainer(at: url)
            let service = TaskService(context: container.mainContext)
            let old = try #require(service.createTask(in: .inbox, folders: [], now: date(20)))
            let new = try #require(service.createTask(in: .inbox, folders: [], now: date(25)))
            service.rename(old, to: "Обновлена позже новой", now: date(25, hour: 18))
            service.toggleToday(old, now: date(25, hour: 19), calendar: calendar)
            return [new.id, old.id]
        }
        try autoreleasepool {
            let reopened = try PlannerPersistence.makeContainer(at: url)
            let tasks = try reopened.mainContext.fetch(FetchDescriptor<PlannerTask>())
            #expect(snapshot(tasks).taskIDs == expected)
        }
    }
}
