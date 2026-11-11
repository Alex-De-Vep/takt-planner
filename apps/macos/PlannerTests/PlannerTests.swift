import Foundation
import SwiftData
import Testing
@testable import Planner

/// Проверки бизнес-логики и реального дискового сохранения без управления интерфейсом.
@MainActor
struct PlannerTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Moscow")!
        value.firstWeekday = 2
        value.minimumDaysInFirstWeek = 4
        return value
    }

    private func date(_ day: Int, _ hour: Int = 12, year: Int = 2026, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func starRemainsAfterLocalMidnightUntilManuallyRemoved() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        let task = try #require(service.createTask(in: .inbox, folders: [], now: date(25, 23)))
        service.toggleToday(task, now: date(25, 23), calendar: calendar)
        #expect(TaskFilter.today.matches(task, now: date(25, 23), calendar: calendar))
        #expect(TaskFilter.today.matches(task, now: date(26, 0), calendar: calendar))
        #expect(TaskFilter.inbox.matches(task, now: date(26)))
        service.toggleToday(task, now: date(26), calendar: calendar)
        #expect(!TaskFilter.today.matches(task, now: date(26), calendar: calendar))
    }

    @Test func onlyActiveLegacyStarsArePreserved() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        let active = try #require(service.createTask(in: .inbox, folders: []))
        let expired = try #require(service.createTask(in: .inbox, folders: []))
        active.focusDay = LocalDay.key(for: date(25), calendar: calendar)
        expired.focusDay = LocalDay.key(for: date(24), calendar: calendar)
        try container.mainContext.save()

        service.preserveLegacyTodayMarks(in: [active, expired], now: date(25), calendar: calendar)
        let reopened = try ModelContext(container).fetch(FetchDescriptor<PlannerTask>())
        let tomorrow = TaskListSnapshot(tasks: reopened, filter: .today, now: date(26), calendar: calendar)
        #expect(tomorrow.taskIDs == [active.id])
        #expect(expired.focusDay == LocalDay.key(for: date(24), calendar: calendar))
    }

    @Test func localDayUsesTimeZone() {
        let instant = Date(timeIntervalSince1970: 0)
        var west = calendar
        west.timeZone = TimeZone(secondsFromGMT: -8 * 3600)!
        #expect(LocalDay.key(for: instant, calendar: west) == "1969-12-31")
        #expect(LocalDay.key(for: instant, calendar: calendar) == "1970-01-01")
    }

    @Test func systemFoldersStayExclusiveAcrossWeeksAndMonths() {
        let task = PlannerTask(now: date(25))
        task.systemFolderKind = "week"
        #expect(TaskFilter.week.matches(task, now: date(26), calendar: calendar))
        #expect(TaskFilter.week.matches(task, now: date(1, month: 11), calendar: calendar))
        #expect(!TaskFilter.month.matches(task, now: date(25), calendar: calendar))
        #expect(!TaskFilter.inbox.matches(task, now: date(25), calendar: calendar))
        task.systemFolderKind = "month"
        #expect(TaskFilter.month.matches(task, now: date(1, month: 11), calendar: calendar))
        #expect(!TaskFilter.week.matches(task, now: date(25), calendar: calendar))
    }

    @Test func completionAndStarAreIndependentAndReversible() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        let folder = try service.saveFolder(name: "Работа")
        let task = try #require(service.createTask(in: .folder(folder.id), folders: [folder]))
        service.toggleToday(task, now: date(25), calendar: calendar)
        service.toggleCompleted(task, now: date(25))
        #expect(task.isCompleted)
        #expect(task.folder?.id == folder.id)
        #expect(task.isFocused(on: date(25), calendar: calendar))
        service.toggleCompleted(task)
        #expect(!task.isCompleted)
        service.toggleToday(task, now: date(25), calendar: calendar)
        #expect(!task.isFocused(on: date(25), calendar: calendar))
        #expect(task.folder?.id == folder.id)
    }

    @Test func newTaskBelongsToItsSelectedSmartFilter() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        for filter in [TaskFilter.today, .week, .month] {
            let task = try #require(service.createTask(in: filter, folders: [], now: date(25)))
            #expect(filter.matches(task, now: date(25)))
            #expect(task.folder == nil)
        }
    }

    @Test func deletingFolderPreservesItsTasks() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        let folder = try service.saveFolder(name: "Проект")
        let task = try #require(service.createTask(in: .folder(folder.id), folders: [folder]))
        service.rename(task, to: "Важная задача")
        #expect(service.deleteFolder(folder))
        let tasks = try container.mainContext.fetch(FetchDescriptor<PlannerTask>())
        #expect(tasks.count == 1)
        #expect(tasks.first?.title == "Важная задача")
        #expect(tasks.first?.folder == nil)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<TaskFolder>()) == 0)
    }

    @Test func freshLibraryHasNoPresetFolders() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        try PlannerPersistence.bootstrap(container.mainContext)
        let folders = try container.mainContext.fetch(FetchDescriptor<TaskFolder>())
        #expect(folders.isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PlannerTask>()) == 0)
        try PlannerPersistence.bootstrap(container.mainContext)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<TaskFolder>()) == 0)
    }

    @Test func legacyFolderCleanupPreservesTasksAndRunsOnlyOnce() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let oldFolder = TaskFolder(name: "Работа", sortOrder: 0)
        let renamedFolder = TaskFolder(name: "Мой проект", sortOrder: 1)
        context.insert(oldFolder)
        context.insert(renamedFolder)
        context.insert(LibraryState())
        let task = PlannerTask(title: "Сохранить задачу", folder: oldFolder)
        context.insert(task)
        try context.save()

        try PlannerPersistence.bootstrap(context)
        #expect(task.folder == nil)
        #expect(try context.fetchCount(FetchDescriptor<PlannerTask>()) == 1)
        #expect(try context.fetch(FetchDescriptor<TaskFolder>()).map(\.name) == ["Мой проект"])
        #expect(try context.fetchCount(FetchDescriptor<LibraryState>()) == 0)

        // Пользователь может снова создать «Работу»: после миграции её больше не удаляем.
        context.insert(TaskFolder(name: "Работа", sortOrder: 0))
        try context.save()
        try PlannerPersistence.bootstrap(context)
        #expect(try context.fetchCount(FetchDescriptor<TaskFolder>()) == 2)
    }

    @Test func folderNamesAreTrimmedAndUniqueIgnoringCase() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        let folder = try service.saveFolder(name: "  Работа \n")
        #expect(folder.name == "Работа")
        #expect(throws: FolderValidationError.self) { try service.saveFolder(name: "работа") }
        #expect(throws: FolderValidationError.self) { try service.saveFolder(name: "  ") }
        let renamed = try service.saveFolder(name: "РАБОТА", editing: folder)
        #expect(renamed.id == folder.id)
    }

    @Test func taskDeletionIsPersisted() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        let task = try #require(service.createTask(in: .inbox, folders: []))
        #expect(service.delete(task))
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PlannerTask>()) == 0)
    }

    @Test func diskStoreSurvivesContainerRecreation() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "RoundTrip.store")
        let taskID: UUID = try autoreleasepool {
            let container = try PlannerPersistence.makeContainer(at: url)
            let service = TaskService(context: container.mainContext)
            let folder = try service.saveFolder(name: "Долгий проект")
            let task = try #require(service.createTask(in: .folder(folder.id), folders: [folder], now: date(25)))
            service.rename(task, to: "Сохранить первую версию")
            service.toggleToday(task, now: date(25), calendar: calendar)
            service.toggleCompleted(task, now: date(25))
            #expect(service.error == nil)
            return task.id
        }
        try autoreleasepool {
            let reopened = try PlannerPersistence.makeContainer(at: url)
            let task = try #require(reopened.mainContext.fetch(FetchDescriptor<PlannerTask>()).first)
            #expect(task.id == taskID)
            #expect(task.title == "Сохранить первую версию")
            #expect(task.folder?.name == "Долгий проект")
            #expect(task.isCompleted)
            #expect(task.isFocused(on: date(25), calendar: calendar))
            #expect(task.primaryFolder == .folder(task.folder!.id))
            #expect(task.planningKind == nil && task.planningAnchor == nil)
        }
    }
}
