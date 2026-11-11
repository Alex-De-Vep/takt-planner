import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
import PlannerLocalization
@testable import Planner

@MainActor
struct TaskDeadlineTests {
    private func calendar(_ zone: String = "Europe/Moscow") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        value.firstWeekday = 2
        return value
    }

    private func date(_ day: Int, hour: Int = 9, minute: Int = 0, month: Int = 10,
                      zone: String = "Europe/Moscow") -> Date {
        calendar(zone).date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func migrationFromV3PreservesAllRelationshipsAndDeadlineSurvivesReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Planner.store")
        let taskID = UUID(), folderID = UUID(), checklistID = UUID(), linkID = UUID()
        try autoreleasepool {
            let schema = Schema(versionedSchema: PlannerSchemaV3.self)
            let config = ModelConfiguration("Planner", schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let folder = PlannerSchemaV3.TaskFolder(name: "Проект", sortOrder: 3)
            folder.id = folderID
            let task = PlannerSchemaV3.PlannerTask(title: "Задача", folder: folder, now: date(20))
            task.id = taskID; task.descriptionText = "Описание"; task.updatedAt = date(21)
            task.completedAt = date(22); task.focusDay = "2026-10-26"
            task.planningKind = "month"; task.planningAnchor = date(20)
            let item = PlannerSchemaV3.TaskChecklistItem(task: task, title: "Пункт", sortOrder: 7)
            item.id = checklistID; item.isCompleted = true
            let event = CalendarEvent(identifier: "event", externalIdentifier: "external", calendarID: "calendar",
                                      title: "Встреча", start: date(26), end: date(26, hour: 10))
            let link = PlannerSchemaV3.TaskEventLink(task: task, event: event)
            link.id = linkID
            container.mainContext.insert(task)
            container.mainContext.insert(item)
            container.mainContext.insert(link)
            try container.mainContext.save()
        }
        let expected = TaskDeadline(date: date(27, hour: 14, minute: 30), includesTime: true, calendar: calendar())
        for pass in 0..<2 {
            try autoreleasepool {
                let container = try PlannerPersistence.makeContainer(at: url)
                let task = try #require(container.mainContext.fetch(FetchDescriptor<PlannerTask>()).first)
                #expect(task.id == taskID && task.folder?.id == folderID && task.folder?.name == "Проект")
                #expect(task.title == "Задача" && task.descriptionText == "Описание")
                #expect(task.createdAt == date(20) && task.completedAt == date(22))
                #expect(task.focusDay == "2026-10-26" && task.planningKind == "month" && task.planningAnchor == date(20))
                let item = try #require(task.orderedChecklistItems.first)
                #expect(item.id == checklistID && item.task?.id == taskID && item.isCompleted && item.sortOrder == 7)
                #expect(task.eventLinks?.first?.id == linkID && task.eventLinks?.first?.externalIdentifier == "external")
                if pass == 0 {
                    #expect(task.deadline == nil && !task.deadlineIncludesTime && task.deadlineTimeZoneID == nil)
                    #expect(task.updatedAt == date(21))
                    #expect(TaskService(context: container.mainContext).setDeadline(task, to: expected, now: date(26)))
                } else {
                    #expect(task.deadline == expected && task.updatedAt == date(26))
                }
            }
        }
        try autoreleasepool {
            let container = try PlannerPersistence.makeContainer(at: url)
            let task = try #require(container.mainContext.fetch(FetchDescriptor<PlannerTask>()).first)
            #expect(TaskService(context: container.mainContext).setDeadline(task, to: nil))
        }
        let container = try PlannerPersistence.makeContainer(at: url)
        let task = try #require(container.mainContext.fetch(FetchDescriptor<PlannerTask>()).first)
        #expect(task.deadlineDate == nil && !task.deadlineIncludesTime && task.deadlineTimeZoneID == nil)
    }

    @Test func deadlinesNeverChangeSmartFiltersFolderOrCreationOrder() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        let folder = TaskFolder(name: "Работа", sortOrder: 0)
        let tasks = (0..<4).map { PlannerTask(title: "Задача \($0)", folder: $0 == 3 ? folder : nil, now: date(20 + $0)) }
        tasks[1].focusDay = LocalDay.key(for: date(26), calendar: calendar())
        tasks[2].planningKind = "week"; tasks[2].planningAnchor = date(26)
        tasks[2].systemFolderKind = "week"
        tasks[3].planningKind = "month"; tasks[3].planningAnchor = date(26)
        for task in tasks { container.mainContext.insert(task) }
        try container.mainContext.save()
        let filters = TaskFilter.smartFilters + [.folder(folder.id)]
        let before = filters.map { TaskListSnapshot(tasks: tasks, filter: $0, now: date(26), calendar: calendar()).taskIDs }
        for deadline in [TaskDeadline(date: date(26, hour: 14), includesTime: true, calendar: calendar()),
                         TaskDeadline(date: date(1, month: 12), includesTime: false, calendar: calendar()), nil] {
            for task in tasks { #expect(service.setDeadline(task, to: deadline)) }
            let after = filters.map { TaskListSnapshot(tasks: tasks, filter: $0, now: date(26), calendar: calendar()).taskIDs }
            #expect(after == before)
            #expect(tasks[1].focusDay == "2026-10-26")
            #expect(tasks[2].planningKind == "week" && tasks[2].planningAnchor == date(26))
            #expect(tasks[2].primaryFolder == .week)
            #expect(tasks[3].folder?.id == folder.id && tasks[3].planningKind == "month")
        }
    }

    @Test func failedSaveAndFailedRemovalRestoreThePreviousDeadline() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        var fail = false
        let service = TaskService(context: container.mainContext, saveContext: { context in
            if fail { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        })
        let task = try #require(service.createTask(in: .inbox, folders: [], now: date(20)))
        let deadline = TaskDeadline(date: date(27), includesTime: true, calendar: calendar())
        fail = true
        #expect(!service.setDeadline(task, to: deadline, now: date(26)))
        #expect(task.deadline == nil && task.updatedAt == date(20))
        fail = false
        #expect(service.setDeadline(task, to: deadline, now: date(26)))
        fail = true
        #expect(!service.setDeadline(task, to: nil, now: date(27)))
        #expect(task.deadline == deadline && task.updatedAt == date(26))
    }

    @Test func dateOnlyKeepsItsDayAcrossTimeZonesAndTimedDeadlineKeepsItsInstant() {
        let source = date(27, hour: 0, minute: 30)
        let local = calendar("America/Los_Angeles")
        let day = TaskDeadline(date: source, includesTime: false, calendar: calendar())
        let timed = TaskDeadline(date: source, includesTime: true, calendar: calendar())
        #expect(local.component(.day, from: day.localDate(in: local)) == 27)
        #expect(local.component(.day, from: timed.localDate(in: local)) == 26)
        #expect(timed.localDate(in: local) == source)
        let english = Translations(language: .english)
        #expect(day.label(now: date(26, zone: "America/Los_Angeles"), strings: english,
                          locale: Locale(identifier: "en_US"), calendar: local) == "Tomorrow")
        #expect(timed.label(now: date(26, zone: "America/Los_Angeles"), strings: english,
                            locale: Locale(identifier: "en_US"), calendar: local).hasPrefix("Today · "))
    }

    @Test func changingDayPreservesTimeAndRemovingTimeDoesNotLoseTheDay() {
        let expected = TaskDeadline(date: date(31, hour: 14, minute: 30), includesTime: true, calendar: calendar())
        var draft = TaskDeadlineDraft(deadline: expected, calendar: calendar())
        draft.chooseDay(date(1, month: 11), calendar: calendar())
        #expect(draft.value(calendar: calendar()).date == date(1, hour: 14, minute: 30, month: 11))
        draft.includesTime = false
        let day = draft.value(calendar: calendar())
        #expect(!day.includesTime && day.date == date(1, hour: 0, month: 11))
        let reopened = TaskDeadlineDraft(deadline: day, calendar: calendar())
        #expect(!reopened.includesTime && reopened.value(calendar: calendar()) == day)
    }

    @Test func deadlineButtonIsAfterChecklistAndHiddenWithoutSelection() throws {
        let controller = WorkspaceSplitController(), toolbar = NSToolbar()
        let id = NSToolbarItem.Identifier("Planner.Deadline")
        let item = try #require(controller.toolbar(toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: true))
        #expect(item.isHidden)
        controller.updateDeadline(AnyView(Text("Срок")), title: "Срок задачи", visible: true)
        #expect(!item.isHidden && item.label == "Срок задачи")
        let ids = controller.toolbarDefaultItemIdentifiers(toolbar)
        let deadlineIndex = try #require(ids.firstIndex(of: id))
        let checklistIndex = try #require(ids.firstIndex(of: .init("Planner.Checklist")))
        #expect(deadlineIndex > checklistIndex)
        controller.updateDeadline(AnyView(EmptyView()), title: "Срок задачи", visible: false)
        #expect(item.isHidden)
    }
}
