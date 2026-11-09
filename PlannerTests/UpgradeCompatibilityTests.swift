import Foundation
import SwiftData
import Testing
@testable import Planner

/// Проверяем обновление на вымышленной библиотеке; основной контейнер пользователя не открывается.
@MainActor
struct UpgradeCompatibilityTests {
    @Test func livePathRetainsOriginalLibraryName() throws {
        let path = try PlannerPersistence.liveStoreURL()
        #expect(path.lastPathComponent == "Planner.store")
        #expect(!path.path.contains("PlannerAIPreview"))
        // UI-тесты могут добавлять свой суффикс к основной папке Planner.
        #expect(path.pathComponents.contains("Planner"))
    }

    @Test func migratingV5LibraryPreservesFoldersTasksAndRelationships() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "UpgradeCheck-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "Planner.store")
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let taskID = UUID(), folderID = UUID(), itemID = UUID(), linkID = UUID()
        try autoreleasepool {
            let oldSchema = Schema(versionedSchema: PlannerSchemaV5.self)
            let oldConfiguration = ModelConfiguration("Planner", schema: oldSchema, url: store, cloudKitDatabase: .none)
            let container = try ModelContainer(for: oldSchema, configurations: [oldConfiguration])
            let context = container.mainContext
            let folder = TaskFolder(name: "Моя папка", sortOrder: 4); folder.id = folderID
            context.insert(folder)
            let task = PlannerTask(title: "Сохранённая задача", folder: folder, now: created); task.id = taskID
            task.descriptionText = "Описание\n- первый пункт\n- второй пункт"
            task.updatedAt = created.addingTimeInterval(60); task.completedAt = created.addingTimeInterval(120)
            task.focusDay = "2026-10-30"; task.systemFolderKind = "month"
            task.deadlineDate = created.addingTimeInterval(3600); task.deadlineIncludesTime = true
            task.deadlineTimeZoneID = "Europe/Moscow"
            context.insert(task)
            let item = TaskChecklistItem(task: task, title: "Подзадача", sortOrder: 2)
            item.id = itemID; item.isCompleted = true; context.insert(item)
            let event = CalendarEvent(identifier: "fake-event", externalIdentifier: "fake-external", calendarID: "fake-calendar",
                                      title: "Запланировано", start: created, end: created.addingTimeInterval(3600))
            let link = TaskEventLink(task: task, event: event); link.id = linkID; context.insert(link)
            let week = PlannerTask(title: "На неделе", now: created); week.systemFolderKind = "week"; context.insert(week)
            try context.save()
        }
        try autoreleasepool {
            let container = try PlannerPersistence.makeContainer(at: store)
            let context = container.mainContext
            try PlannerPersistence.bootstrap(context)
            #expect(try context.fetchCount(FetchDescriptor<PlannerSchemaV6.SyncQueueItem>()) == 0)
            let tasks = try context.fetch(FetchDescriptor<PlannerTask>())
            let task = try #require(tasks.first(where: { $0.id == taskID }))
            #expect(tasks.count == 2)
            #expect(task.title == "Сохранённая задача")
            #expect(task.descriptionText == "Описание\n- первый пункт\n- второй пункт")
            #expect(task.createdAt == created && task.updatedAt == created.addingTimeInterval(60))
            #expect(task.completedAt == created.addingTimeInterval(120))
            #expect(task.focusDay == "2026-10-30" && task.systemFolderKind == "month")
            #expect(task.deadlineDate == created.addingTimeInterval(3600) && task.deadlineIncludesTime)
            #expect(task.deadlineTimeZoneID == "Europe/Moscow")
            #expect(task.folder?.id == folderID && task.folder?.name == "Моя папка" && task.folder?.sortOrder == 4)
            #expect(task.orderedChecklistItems.count == 1 && task.orderedChecklistItems.first?.id == itemID)
            #expect(task.orderedChecklistItems.first?.title == "Подзадача" && task.orderedChecklistItems.first?.isCompleted == true)
            #expect(task.eventLinks?.first?.id == linkID && task.eventLinks?.first?.externalIdentifier == "fake-external")
            #expect(task.eventLinks?.first?.eventIdentifier == "fake-event" && task.eventLinks?.first?.lastTitle == "Запланировано")
            #expect(tasks.first(where: { $0.title == "На неделе" })?.primaryFolder == .week)
        }
    }

    @Test func openingExistingV6LibraryPreservesTasksAndSyncState() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ExistingV6-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "Planner.store")
        let payload = Data([0, 127, 255])
        let taskID = UUID()
        // Библиотека создаётся напрямую схемой из основной ветки, без фабрики проверяемой сборки.
        try autoreleasepool {
            let schema = Schema(versionedSchema: PlannerSchemaV6.self)
            let configuration = ModelConfiguration("Planner", schema: schema, url: store, cloudKitDatabase: .none)
            let source = try ModelContainer(for: schema, configurations: [configuration])
            let context = source.mainContext
            let folder = TaskFolder(name: "Папка", sortOrder: 0)
            let task = PlannerTask(title: "Задача", folder: folder)
            task.id = taskID
            context.insert(folder)
            context.insert(task)
            context.insert(TaskChecklistItem(task: task, title: "Пункт", sortOrder: 0))
            let checkpoint = PlannerSchemaV6.SyncCheckpoint(libraryID: "test-library")
            checkpoint.cursor = "20"
            context.insert(checkpoint)
            context.insert(PlannerSchemaV6.SyncReplica(entityID: "entity", payload: payload))
            context.insert(PlannerSchemaV6.SyncQueueItem(operationID: "op", entityID: "entity", sequence: 21, payload: payload))
            try context.save()
        }
        let reopened = try PlannerPersistence.makeContainer(at: store)
        let context = reopened.mainContext
        try PlannerPersistence.bootstrap(context)
        let task = try #require(context.fetch(FetchDescriptor<PlannerTask>()).first)
        #expect(task.id == taskID)
        #expect(task.folder?.name == "Папка")
        #expect(task.orderedChecklistItems.map(\.title) == ["Пункт"])
        #expect(try context.fetch(FetchDescriptor<PlannerSchemaV6.SyncCheckpoint>()).first?.cursor == "20")
        #expect(try context.fetch(FetchDescriptor<PlannerSchemaV6.SyncReplica>()).first?.payload == payload)
        let operation = try #require(context.fetch(FetchDescriptor<PlannerSchemaV6.SyncQueueItem>()).first)
        #expect(operation.operationID == "op" && operation.sequence == 21 && operation.payload == payload)
    }

}
