import Foundation
import SwiftData
import Testing
import PlannerLocalization
@testable import Planner

/// Папка является принадлежностью, а не периодическим фильтром или копией задачи.
@MainActor struct TaskFolderTests {
    private let now = Date(timeIntervalSince1970: 1_793_030_400)

    @Test func creationUsesOnePrimaryFolderAndVirtualViewsUseInbox() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        let folder = try service.saveFolder(name: "Проект")
        let destinations = TaskFilter.systemFolders + [.folder(folder.id)]
        for destination in destinations + [.today, .all] {
            let task = try #require(service.createTask(in: destination, folders: [folder], now: now))
            #expect(task.primaryFolder == destination.creationFolder)
            #expect(destinations.filter { $0.matches(task, now: now) } == [destination.creationFolder])
            #expect(TaskFilter.today.matches(task, now: now) == (destination == .today))
            #expect(TaskFilter.all.matches(task, now: now))
            // Начало новой недели и месяца не меняет основную папку.
            #expect(task.primaryFolder.matches(task, now: now.addingTimeInterval(90 * 86400)))
        }
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PlannerTask>()) == 6)
        #expect(service.createTask(in: .folder(UUID()), folders: [folder]) == nil)
    }

    @Test func moveAndTodayKeepTaskContentDatesLinksAndNotifications() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        let folder = try service.saveFolder(name: "Проект")
        let task = try #require(service.createTask(in: .week, folders: [folder], now: now))
        task.title = "Сохранить содержимое"; task.descriptionText = "Описание\nВторая строка"
        let item = TaskChecklistItem(task: task, title: "Пункт", sortOrder: 0)
        container.mainContext.insert(item)
        let event = CalendarEvent(identifier: "event", externalIdentifier: "external", calendarID: "work",
                                  title: "Время задачи", start: now, end: now.addingTimeInterval(3600))
        #expect(service.link(event, to: task))
        #expect(service.setDeadline(task, to: TaskDeadline(date: now.addingTimeInterval(3600), includesTime: true)))
        #expect(service.markToday(task, now: now))
        service.toggleCompleted(task, now: now)
        let created = task.createdAt, id = task.id, deadline = task.deadline
        let linkID = task.eventLinks?.first?.id, itemID = task.orderedChecklistItems.first?.id
        var notificationChanges = 0
        service.notificationChanged = { _, _ in notificationChanges += 1 }
        for destination in [TaskFilter.month, .folder(folder.id), .inbox, .week] {
            #expect(service.move(task, to: destination, folders: [folder], now: now.addingTimeInterval(60)))
            #expect(task.primaryFolder == destination && task.id == id && task.createdAt == created)
            #expect(task.isFocused(on: now) && task.isCompleted && task.deadline == deadline)
            #expect(task.title == "Сохранить содержимое" && task.descriptionText == "Описание\nВторая строка")
            #expect(task.eventLinks?.first?.id == linkID && task.orderedChecklistItems.first?.id == itemID)
        }
        // Drop на «Сегодня» добавляет отметку идемпотентно, а не выключает уже существующую.
        #expect(service.markToday(task, now: now))
        #expect(service.markToday(task, now: now))
        #expect(task.primaryFolder == .week && task.isFocused(on: now) && notificationChanges == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PlannerTask>()) == 1)
        #expect(!service.move(task, to: .all, folders: [folder]))
        #expect(!service.move(task, to: .today, folders: [folder]))
        #expect(!service.move(task, to: .folder(UUID()), folders: [folder]))
        #expect(task.primaryFolder == .week)
    }

    @Test func allTasksAreGloballySortedAndHeadingCountsOnlyActiveSearchResults() {
        let folder = TaskFolder(name: "Проект", sortOrder: 0)
        let first = PlannerTask(title: "Совпадение 1", folder: folder, now: now)
        let second = PlannerTask(title: "Совпадение 2", now: now.addingTimeInterval(60))
        second.systemFolderKind = "month"
        let third = PlannerTask(title: "Другая", now: now.addingTimeInterval(120))
        let completed = PlannerTask(title: "Совпадение готово", now: now.addingTimeInterval(180))
        completed.completedAt = now
        let tasks = [completed, first, third, second]
        let all = TaskListSnapshot(tasks: tasks, filter: .all, now: now)
        #expect(all.activeTasks.map(\.id) == [third.id, second.id, first.id])
        #expect(all.completedTasks.map(\.id) == [completed.id] && all.activeCount == 3)
        let searched = TaskListSnapshot(tasks: tasks, filter: .all, search: "Совпадение", now: now)
        #expect(searched.activeCount == 2 && searched.completedTasks.count == 1)
        #expect(all.activeSections.map(\.id) == ["active"])
    }

    @Test func movingOutOfFolderKeepsSelectionInTheSameListArea() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        let first = try #require(service.createTask(in: .inbox, folders: [], now: now))
        let second = try #require(service.createTask(in: .inbox, folders: [], now: now.addingTimeInterval(60)))
        let completed = try #require(service.createTask(in: .inbox, folders: []))
        service.toggleCompleted(completed)
        let tasks = [first, second, completed], state = WorkspaceState()
        func snapshot() -> TaskListSnapshot { .init(tasks: tasks, filter: .inbox, now: now) }
        state.selectTask(second.id)
        let before = snapshot()
        #expect(service.move(second, to: .week, folders: []))
        state.selectAfterMovingTask(second.id, previous: before, current: snapshot())
        #expect(state.selectedTaskID == first.id && state.filter == .inbox)
        let last = snapshot()
        #expect(service.move(first, to: .month, folders: []))
        state.selectAfterMovingTask(first.id, previous: last, current: snapshot())
        #expect(state.selectedTaskID == nil && snapshot().completedTasks.count == 1)
        state.openLinkedTask(second, visibleIDs: [])
        #expect(state.filter == .week && state.selectedTaskID == second.id)
    }

    @Test func failedMoveDoesNotChangeOwnershipOrOtherTaskState() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        var fail = false
        let service = TaskService(context: container.mainContext, saveContext: {
            if fail { throw CocoaError(.fileWriteUnknown) }
            try $0.save()
        })
        let folder = try service.saveFolder(name: "Проект")
        let task = try #require(service.createTask(in: .folder(folder.id), folders: [folder], now: now))
        fail = true
        #expect(!service.move(task, to: .week, folders: [folder], now: now.addingTimeInterval(60)))
        #expect(task.primaryFolder == .folder(folder.id) && task.updatedAt == now && task.createdAt == now)
        #expect(service.error != nil)
    }

    @Test func dragReferenceIsLocalAndRejectsForeignOrMalformedPayloads() throws {
        let payload = TaskDragPayload(taskID: UUID(), scopeID: UUID())
        #expect(TaskDragPayload.decode(try JSONEncoder().encode(payload)) == payload)
        #expect(payload.taskID(in: payload.scopeID) == payload.taskID)
        #expect(payload.taskID(in: UUID()) == nil)
        #expect(TaskDragPayload.decode(Data("not a task".utf8)) == nil)
        #expect(TaskDragPayload.decode(Data(repeating: 0, count: 1025)) == nil)
        #expect(payload.provider().hasItemConformingToTypeIdentifier("local.planner.task"))
        #expect(TaskFilter.today.acceptsTaskDrop && !TaskFilter.all.acceptsTaskDrop)
        #expect(TaskFilter.systemFolders.allSatisfy { $0.isPrimaryFolder })
        #expect(!TaskFilter.today.isPrimaryFolder && !TaskFilter.all.isPrimaryFolder)
    }

    @Test func migrationV4PreservesContentAndRunsOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Folders.store")
        let ids = (0..<4).map { _ in UUID() }
        let folderID = UUID(), itemID = UUID(), linkID = UUID()
        try autoreleasepool {
            let schema = Schema(versionedSchema: PlannerSchemaV4.self)
            let configuration = ModelConfiguration("Planner", schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            let folder = PlannerSchemaV4.TaskFolder(name: "Своя папка", sortOrder: 2)
            folder.id = folderID; context.insert(folder)
            for index in ids.indices {
                let task = PlannerSchemaV4.PlannerTask(title: "Задача \(index)", folder: index == 0 ? folder : nil, now: now)
                task.id = ids[index]; task.descriptionText = "Описание"; task.updatedAt = now.addingTimeInterval(30)
                task.planningKind = index <= 1 ? "week" : index == 2 ? "month" : nil
                task.planningAnchor = now.addingTimeInterval(-90 * 86400)
                task.focusDay = LocalDay.key(for: now); task.deadlineDate = now.addingTimeInterval(3600)
                task.deadlineIncludesTime = true; task.deadlineTimeZoneID = "Europe/Moscow"
                if index == 2 { task.completedAt = now }
                context.insert(task)
                if index == 0 {
                    let item = PlannerSchemaV4.TaskChecklistItem(task: task, title: "Пункт", sortOrder: 1)
                    item.id = itemID; item.isCompleted = true; context.insert(item)
                    let event = CalendarEvent(identifier: "external-event", externalIdentifier: "external-id",
                        calendarID: "work", title: "Событие", start: now, end: now.addingTimeInterval(3600))
                    let link = PlannerSchemaV4.TaskEventLink(task: task, event: event)
                    link.id = linkID; context.insert(link)
                }
            }
            try context.save()
        }
        for pass in 0..<2 {
            try autoreleasepool {
                let container = try PlannerPersistence.makeContainer(at: url)
                let tasks = try container.mainContext.fetch(FetchDescriptor<PlannerTask>())
                #expect(tasks.count == 4)
                let expected: [TaskFilter] = [.folder(folderID), pass == 0 ? .week : .inbox, .month, .inbox]
                for index in ids.indices {
                    let task = try #require(tasks.first { $0.id == ids[index] })
                    #expect(task.primaryFolder == expected[index] && task.createdAt == now)
                    #expect(task.title == "Задача \(index)" && task.descriptionText == "Описание")
                    #expect(task.isFocused(on: now) && task.deadlineDate == now.addingTimeInterval(3600))
                    #expect(task.deadlineIncludesTime && task.deadlineTimeZoneID == "Europe/Moscow")
                    if index == 0 {
                        #expect(task.orderedChecklistItems.first?.id == itemID && task.orderedChecklistItems.first?.isCompleted == true)
                        #expect(task.eventLinks?.first?.id == linkID && task.eventLinks?.first?.eventIdentifier == "external-event")
                    }
                    if index != 1 || pass == 0 { #expect(task.updatedAt == now.addingTimeInterval(30)) }
                }
                #expect(tasks.first { $0.id == ids[2] }?.isCompleted == true)
                if pass == 0 {
                    let task = try #require(tasks.first { $0.id == ids[1] })
                    #expect(TaskService(context: container.mainContext).move(task, to: .inbox, folders: []))
                }
            }
        }
    }
}
