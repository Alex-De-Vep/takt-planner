import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Planner

/// Подзадачи проверяются в отдельной библиотеке, без запуска приложения и обращения к календарям.
@MainActor
struct ChecklistTests {
    @Test func migrationFromV2KeepsExistingDataAndChecklistSurvivesReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Planner.store")
        let taskID = UUID(), folderID = UUID(), linkID = UUID()
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let updated = created.addingTimeInterval(60)
        try autoreleasepool {
            let schema = Schema(versionedSchema: PlannerSchemaV2.self)
            let configuration = ModelConfiguration("Planner", schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let folder = PlannerSchemaV2.TaskFolder(name: "Проект", sortOrder: 7)
            folder.id = folderID
            let task = PlannerSchemaV2.PlannerTask(title: "Название", folder: folder, now: created)
            task.id = taskID; task.descriptionText = "Описание\nс переносом"
            task.updatedAt = updated; task.completedAt = updated; task.focusDay = "2026-10-25"
            task.planningKind = "week"; task.planningAnchor = created
            let event = CalendarEvent(identifier: "event", externalIdentifier: "external", calendarID: "calendar",
                                      title: "Время", start: created, end: updated)
            let link = PlannerSchemaV2.TaskEventLink(task: task, event: event)
            link.id = linkID
            container.mainContext.insert(link)
            try container.mainContext.save()
        }
        let itemID: UUID = try autoreleasepool {
            let container = try PlannerPersistence.makeContainer(at: url)
            let task = try #require(container.mainContext.fetch(FetchDescriptor<PlannerTask>()).first)
            #expect(task.id == taskID && task.folder?.id == folderID)
            #expect(task.title == "Название" && task.descriptionText == "Описание\nс переносом")
            #expect(task.createdAt == created && task.updatedAt == updated && task.completedAt == updated)
            #expect(task.focusDay == "2026-10-25" && task.planningKind == "week" && task.planningAnchor == created)
            #expect(task.folder?.sortOrder == 7)
            #expect(task.eventLinks?.first?.id == linkID && task.eventLinks?.first?.externalIdentifier == "external")
            #expect(task.orderedChecklistItems.isEmpty)
            let service = TaskService(context: container.mainContext)
            let item = try #require(service.addChecklistItem(to: task))
            #expect(service.renameChecklistItem(item, to: "Первый шаг"))
            #expect(service.toggleChecklistItem(item))
            return item.id
        }
        try autoreleasepool {
            let container = try PlannerPersistence.makeContainer(at: url)
            let task = try #require(container.mainContext.fetch(FetchDescriptor<PlannerTask>()).first)
            let item = try #require(task.orderedChecklistItems.first)
            #expect(task.id == taskID && task.createdAt == created)
            #expect(task.eventLinks?.first?.eventIdentifier == "event")
            #expect(item.id == itemID && item.title == "Первый шаг" && item.isCompleted)
            #expect(item.task?.id == taskID)
        }
    }

    @Test func checklistOrderAndParentStateStayIndependent() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let task = try #require(service.createTask(in: .inbox, folders: [], now: created))
        let other = try #require(service.createTask(in: .inbox, folders: [], now: created.addingTimeInterval(60)))
        let tasks = [task, other]
        let before = TaskListSnapshot(tasks: tasks, filter: .inbox, now: created).taskIDs
        let a = try #require(service.addChecklistItem(to: task))
        let c = try #require(service.addChecklistItem(to: task))
        let b = try #require(service.addChecklistItem(to: task, after: a))
        let ids = [a.id, b.id, c.id]
        #expect(task.orderedChecklistItems.map(\.id) == ids)
        service.toggleToday(task, now: created)
        let focus = task.focusDay
        for item in [a, b, c] { #expect(service.toggleChecklistItem(item)) }
        #expect(!task.isCompleted && task.focusDay == focus && task.createdAt == created)
        #expect(service.renameChecklistItem(b, to: "Переименовано"))
        #expect(task.orderedChecklistItems.map(\.id) == ids)
        #expect(TaskListSnapshot(tasks: tasks, filter: .inbox, now: created).taskIDs == before)
        service.toggleCompleted(task)
        let allItemsCompleted = task.orderedChecklistItems.allSatisfy { $0.isCompleted }
        #expect(allItemsCompleted)
        #expect(service.toggleChecklistItem(b))
        #expect(task.isCompleted && !b.isCompleted)
        #expect(service.deleteChecklistItem(b))
        #expect(task.orderedChecklistItems.map(\.id) == [a.id, c.id])
    }

    @Test func failedChecklistSaveRetainsDraftAndRollbackCanRetry() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        var fail = false
        let service = TaskService(context: container.mainContext, saveContext: {
            if fail { throw CalendarFailure(message: "Ошибка записи") }
            try $0.save()
        })
        let task = try #require(service.createTask(in: .inbox, folders: []))
        let otherTask = try #require(service.createTask(in: .inbox, folders: []))
        let first = try #require(service.addChecklistItem(to: task))
        let other = try #require(service.addChecklistItem(to: otherTask))
        fail = true
        #expect(!service.renameChecklistItem(first, to: "Черновик"))
        #expect(first.title.isEmpty && service.checklistTitle(for: first) == "Черновик")
        #expect(service.checklistTitle(for: other).isEmpty)
        #expect(!service.toggleChecklistItem(first) && !first.isCompleted)
        #expect(service.addChecklistItem(to: task) == nil)
        #expect(task.orderedChecklistItems.count == 1)
        fail = false
        #expect(service.renameChecklistItem(first, to: service.checklistTitle(for: first)))
        #expect(first.title == "Черновик" && service.checklistDrafts.isEmpty)
    }

    @Test func deletingTaskCascadesOnlyItsOwnChecklist() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        let a = try #require(service.createTask(in: .inbox, folders: []))
        let b = try #require(service.createTask(in: .inbox, folders: []))
        let first = try #require(service.addChecklistItem(to: a))
        let other = try #require(service.addChecklistItem(to: b))
        service.checklistDrafts[first.id] = "Черновик удаляемой задачи"
        #expect(service.delete(a))
        #expect(service.checklistDrafts.isEmpty)
        let items = try container.mainContext.fetch(FetchDescriptor<TaskChecklistItem>())
        #expect(items.map(\.id) == [other.id] && other.task?.id == b.id)
    }

    @Test func checklistToolbarButtonBelongsToTaskColumnAndNeedsSelection() throws {
        let controller = WorkspaceSplitController()
        let toolbar = NSToolbar()
        let identifier = NSToolbarItem.Identifier("Planner.Checklist")
        let ids = controller.toolbarDefaultItemIdentifiers(toolbar)
        let index = try #require(ids.firstIndex(of: identifier))
        #expect(ids[index - 1] == .space)
        #expect(ids[index - 2] == NSToolbarItem.Identifier("Planner.NewTask"))
        let item = try #require(controller.toolbar(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: true))
        let surface = try #require(item.view as? WorkspaceToolbarButtonSurface)
        let button = try #require(surface.contentView as? NSButton)
        #expect(item.isHidden && !button.isEnabled)
        var added = 0
        controller.update(sidebar: AnyView(EmptyView()), tasks: AnyView(EmptyView()), detail: AnyView(EmptyView()),
                          taskActions: AnyView(EmptyView()), isSidebarVisible: true, newFolderTitle: "Папка",
                          toggleSidebarTitle: "Панель", folderTitle: "Входящие", taskCountTitle: "1",
                          newTaskTitle: "Задача", newChecklistItemTitle: "Подзадача", taskActionsTitle: "Действия",
                          hasSelectedTask: true, newFolder: {}, newTask: {}, newChecklistItem: { added += 1 },
                          sidebarVisibilityChanged: { _ in })
        #expect(!item.isHidden && button.isEnabled && button.image != nil)
        button.performClick(nil)
        #expect(added == 1)
    }
}
