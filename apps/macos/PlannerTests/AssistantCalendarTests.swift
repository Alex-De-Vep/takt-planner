import Foundation
import Testing
@testable import Planner

@MainActor struct AssistantCalendarTests {
    private let zone = "Europe/Moscow"
    private let day = "2026-11-12"

    private func context(task: PlannerTask? = nil) throws -> AssistantContext {
        .init(now: try date(day, "10:00"), timeZoneID: zone, language: "ru", folders: [],
              calendars: [.init(id: "work", name: "Работа")], defaultFolderID: "inbox", defaultCalendarID: "work",
              taskID: task?.id.uuidString, taskTitle: task?.title, durationMinutes: 60)
    }

    private func date(_ day: String, _ time: String) throws -> Date {
        try ActionPlanValidator.date(day, time: time, zone: zone)
    }

    private func event(_ id: String, hour: String = "12:00", calendarID: String = "work",
                       title: String = "Личный заголовок для теста") throws -> CalendarEvent {
        let start = try date(day, hour)
        return CalendarEvent(identifier: id, calendarID: calendarID, title: title, start: start,
                             end: start.addingTimeInterval(2700), notes: "Личные заметки", reminder: -600)
    }

    private func makeService() -> (AssistantService, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AssistantCalendarTests-\(UUID())")
        return (AssistantService(store: AssistantStore(url: directory.appending(path: "chat.json"))), directory)
    }

    @Test func agendaUsesSelectedCalendarsAndKeepsEventDetailsLocal() throws {
        let fake = FakeCalendarStore()
        fake.calendarList.append(.init(id: "hidden", title: "Скрытый", colorHex: "", writable: true))
        fake.values = try [event("one"), event("two", calendarID: "hidden")]
        let calendar = CalendarService(store: fake)
        let thread = AssistantService.calendarReply(.init(operation: .agenda, fromDate: day), to: .init(),
            context: try context(), calendar: calendar, visibleIDs: ["work"], usage: nil)
        #expect(thread.messages.last?.calendarAgenda?.map(\.identifier) == ["one"])
        #expect(fake.saves == 0)
        let cloud = try AssistantCloudRequest(thread: thread, text: "Спасибо", context: context(), edit: nil, modelID: "fixture")
        let payload = String(decoding: cloud.body, as: UTF8.self)
        #expect(!payload.contains("Личный заголовок"))
        #expect(!payload.contains("Личные заметки"))
    }

    @Test func creationClarifiesThenSavesOneEventLinkedToCurrentTask() async throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let task = PlannerTask(title: "Подготовить отчёт")
        container.mainContext.insert(task)
        try container.mainContext.save()
        let tasks = TaskService(context: container.mainContext)
        let fake = FakeCalendarStore(), calendar = CalendarService(store: fake)
        let (service, directory) = makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try #require(service.current)
        let incomplete = AssistantService.calendarReply(.init(operation: .create, date: day, linkCurrentTask: true),
            to: original, context: try context(task: task), calendar: calendar, visibleIDs: nil, usage: nil)
        let pending = try #require(incomplete.actions.first)
        #expect(incomplete.messages.last?.questions.first?.text == "Во сколько запланировать событие?")
        #expect(fake.saves == 0)
        let completed = AssistantService.calendarReply(.init(operation: .create, time: "14:00", durationMinutes: 30, continueCurrent: true),
            to: incomplete, context: try context(), calendar: calendar, visibleIDs: nil, usage: nil)
        let ready = try #require(completed.actions.first)
        #expect(ready.id == pending.id)
        #expect(ready.proposal.linkTo == task.id.uuidString)
        service.archive.threads[0] = completed
        await service.apply(taskService: tasks, calendar: calendar, folders: [], actionID: ready.id)
        await service.apply(taskService: tasks, calendar: calendar, folders: [], actionID: ready.id)
        #expect(fake.saves == 1)
        #expect(fake.values.first?.title == task.title)
        #expect(task.eventLinks?.count == 1)
        #expect(service.current?.visibleActions.isEmpty == true)
    }

    @Test func editedTaskDisappearsAndStillLinksToEventOnRetry() async throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        var rejectSave = false
        let tasks = TaskService(context: container.mainContext, saveContext: {
            if rejectSave { throw AssistantFailure(message: "Test write failure") }
            try $0.save()
        })
        let fake = FakeCalendarStore(), calendar = CalendarService(store: fake)
        let (service, directory) = makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try context()
        let taskAction = AssistantAction(proposal: .init(key: "task", kind: .task, title: "Draft", folderID: "inbox"), context: context)
        let eventAction = AssistantAction(proposal: .init(key: "event", kind: .event, title: "Draft event",
            date: day, time: "14:00", calendarID: "work", linkTo: "task"), context: context)
        service.archive.threads[0].actions = [taskAction, eventAction]
        service.archive.threads[0].messages = [.init(role: .assistant, text: "Draft task and event", resultActionID: taskAction.id)]

        var editedTask = taskAction
        editedTask.proposal.title = "Updated title"
        editedTask.proposal.folderID = "week"
        editedTask.proposal.description = "Updated description"
        editedTask.proposal.checklist = ["Step one", "Step two"]
        editedTask.proposal.date = day
        editedTask.proposal.time = "16:00"
        editedTask.proposal.today = true
        #expect(service.updateAction(editedTask))
        #expect(try tasks.assistantTask(id: taskAction.id) == nil)

        await service.apply(taskService: tasks, calendar: calendar, folders: [], actionID: taskAction.id)
        #expect(service.current?.visibleActions.map(\.id) == [eventAction.id])
        #expect(!service.updateAction(editedTask))
        let savedTask = try tasks.assistantTask(id: taskAction.id)
        let task = try #require(savedTask)
        #expect(task.title == "Updated title")
        #expect(task.systemFolderKind == "week")
        #expect(task.descriptionText == "Updated description")
        #expect(task.orderedChecklistItems.map(\.title) == ["Step one", "Step two"])
        #expect(task.deadlineDate == (try date(day, "16:00")))
        #expect(task.focusDay == PlannerTask.persistentTodayMark)

        var editedEvent = eventAction
        editedEvent.proposal.title = "Updated event"
        editedEvent.proposal.description = "Updated notes"
        editedEvent.proposal.endTime = "14:45"
        editedEvent.proposal.reminderMinutes = 25
        #expect(service.updateAction(editedEvent))

        rejectSave = true
        await service.apply(taskService: tasks, calendar: calendar, folders: [], actionID: eventAction.id)
        let failed = try #require(service.current?.visibleActions.first)
        #expect(failed.status == .failed)
        #expect(failed.createdEventID != nil)
        #expect(!failed.isEditable)

        rejectSave = false
        await service.apply(taskService: tasks, calendar: calendar, folders: [], actionID: eventAction.id)
        #expect(fake.saves == 1)
        #expect(fake.values.first?.title == "Updated event")
        #expect(fake.values.first?.notes == "Updated notes")
        #expect(fake.values.first?.end == (try date(day, "14:45")))
        #expect(fake.values.first?.reminder == -25 * 60)
        #expect(task.eventLinks?.count == 1)
        let reloaded = AssistantService(store: AssistantStore(url: directory.appending(path: "chat.json")))
        #expect(reloaded.current?.visibleActions.isEmpty == true)
        #expect(reloaded.current?.actions.count == 2)
        #expect(reloaded.current?.messages.last?.resultActionID == taskAction.id)
    }

    @Test func moveRequiresConfirmationAndPreservesDurationAndAlerts() async throws {
        let original = try event("meeting")
        let fake = FakeCalendarStore(), calendar = CalendarService(store: fake)
        fake.values = [original]
        let (service, directory) = makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        let thread = try #require(service.current)
        let move = AssistantCalendarRequest(operation: .move, title: original.title, fromDate: day, time: "16:00")
        let proposed = AssistantService.calendarReply(move, to: thread, context: try context(), calendar: calendar,
                                                       visibleIDs: nil, usage: nil)
        let action = try #require(proposed.actions.first)
        #expect(fake.values.first?.start == original.start && fake.saves == 0)
        service.archive.threads[0] = proposed
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        await service.apply(taskService: .init(context: container.mainContext), calendar: calendar, folders: [], actionID: action.id)
        let updated = try #require(fake.values.first)
        #expect(updated.start == (try date(day, "16:00")))
        #expect(updated.end.timeIntervalSince(updated.start) == original.end.timeIntervalSince(original.start))
        #expect(updated.alarms == original.alarms && updated.notes == original.notes)
        #expect(fake.saves == 1)
        #expect(service.current?.actions.first?.status == .created)
        #expect(service.current?.visibleActions.isEmpty == true)
        #expect(throws: AssistantFailure.self) { try action.calendarMove?.draft(for: updated) }
    }

    @Test func editedAllDayMoveUsesTheSelectedLastDay() throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try #require(TimeZone(identifier: zone))
        let original = CalendarEvent(identifier: "all-day", calendarID: "work", title: "All day",
            start: try date(day, "00:00"), end: try date("2026-11-13", "00:00"), allDay: true)
        let move = AssistantCalendarMove(source: .init(original, calendarName: "Work"),
            start: try date("2026-11-15", "00:00"), end: try date("2026-11-18", "00:00"), timeZoneID: zone)
        let draft = try move.draft(for: original)
        #expect(draft.end == (try date("2026-11-17", "00:00")))
        #expect(try draft.interval(calendar: local) == DateInterval(start: move.start, end: move.end))
    }

    @Test func ambiguousMoveAsksForSelectionAndDoesNotWrite() throws {
        let fake = FakeCalendarStore(), calendar = CalendarService(store: fake)
        fake.values = try [event("one"), event("two", hour: "13:00")]
        let proposal = AssistantCalendarRequest(operation: .move, title: fake.values.first?.title, fromDate: day, time: "16:00")
        let thread = AssistantService.calendarReply(proposal, to: .init(), context: try context(),
                                                     calendar: calendar, visibleIDs: nil, usage: nil)
        #expect(thread.actions.isEmpty && fake.saves == 0)
        #expect(thread.messages.last?.calendarSelection?.candidates.map(\.identifier) == ["one", "two"])
        #expect(thread.messages.last?.questions.first?.options.count == 2)
    }
}
