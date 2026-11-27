import Foundation
import SwiftData
import Testing
@testable import Planner

/// Проверки помощника используют подменяемые модель и календарь; личные данные не читаются.
@MainActor struct AssistantTests {
    private func context() -> AssistantContext {
        AssistantContext(now: Date(timeIntervalSince1970: 1793192400), timeZoneID: "Europe/Moscow", language: "ru",
                         folders: [AssistantFolder(id: "inbox", name: "Входящие")],
                         calendars: [AssistantCalendar(id: "work", name: "Работа")],
                         defaultFolderID: "inbox", defaultCalendarID: "work", taskID: nil, taskTitle: nil,
                         durationMinutes: 60, reminderMinutes: nil)
    }
    private func proposal(_ kind: AssistantProposal.Kind = .task) -> AssistantProposal {
        AssistantProposal(key: kind == .task ? "task1" : "event1", kind: kind, title: "Проверка", folderID: "inbox", date: "2026-10-30", time: kind == .event ? "15:00" : nil, calendarID: "work")
    }
    private func tempStore() -> AssistantStore {
        AssistantStore(url: FileManager.default.temporaryDirectory.appending(path: "assistant-tests-\(UUID())/history.json"))
    }
    @Test func approvedTaskAndChecklistEnterSyncQueue() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let tasks = TaskService(context: container.mainContext)
        let queue = try SyncRepository(context: container.mainContext, libraryID: UUID().syncID, deviceID: UUID().syncID)
        tasks.syncRepository = queue
        var action = AssistantAction(proposal: proposal(), context: context())
        action.proposal.today = true
        action.proposal.checklist = ["Один", "Два"]
        let task = try tasks.createAssistantTask(action, folders: [])
        _ = try tasks.createAssistantTask(action, folders: [])

        let pending = try queue.pendingOperations()
        #expect(pending.map(\.entityType) == [.task, .checklistItem, .checklistItem])
        #expect(pending.first?.changes?["focusDay"]?.value == .text(PlannerTask.persistentTodayMark))
        #expect(pending.dropFirst().allSatisfy { $0.changes?["taskId"]?.value == .text(task.id.syncID) })
    }

    @Test func rejectsInvalidDatesAndMissingEventTime() throws {
        #expect(throws: (any Error).self) { try ActionPlanValidator.date("2026-02-30", time: nil, zone: "Europe/Moscow") }
        #expect(throws: (any Error).self) { try ActionPlanValidator.date("2026-03-29", time: "02:30", zone: "Europe/Berlin") }
        var action = AssistantAction(proposal: proposal(.event), context: context())
        action.proposal.time = nil
        #expect(throws: (any Error).self) { try ActionPlanValidator.eventDraft(action) }
        action.proposal.allDay = true
        let draft = try ActionPlanValidator.eventDraft(action)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        #expect(try draft.interval(calendar: cal).duration == 86400)
    }
    @Test func midnightAndReminderArePreserved() throws {
        var action = AssistantAction(proposal: proposal(.event), context: context())
        action.proposal.time = "23:30"; action.proposal.durationMinutes = 120; action.proposal.reminderMinutes = 10
        let draft = try ActionPlanValidator.eventDraft(action)
        #expect(draft.end.timeIntervalSince(draft.start) == 7200)
        #expect(draft.reminder == -600)
    }
    @Test func readonlyAndUnknownDestinationsAreBlocked() {
        var action = AssistantAction(proposal: proposal(), context: context())
        action.proposal.folderID = UUID().uuidString
        #expect(!ActionPlanValidator.problems(action, folders: context().folders, calendars: []).isEmpty)
        action.proposal = proposal(.event)
        #expect(!ActionPlanValidator.problems(action, folders: [], calendars: []).isEmpty)
    }
    @Test func markdownWrapperDoesNotChangeStructuredValues() throws {
        let response = try ActionPlanValidator.decode("{\"message\":\"Review\",\"actions\":[]}`")
        #expect(response.message == "Review" && response.actions?.isEmpty == true)
    }
    @Test func malformedTruncatedAndUnknownActionsNeverExecute() {
        for output in ["{", "```", "{\"message\":\"ok\",\"actions\":[{\"key\":\"x\",\"kind\":\"delete\",\"title\":\"x\"}]}"] {
            #expect(throws: (any Error).self) { try ActionPlanValidator.decode(output) }
        }
    }
    @Test func taskIsAtomicAndIdempotent() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let tasks = TaskService(context: container.mainContext)
        var action = AssistantAction(proposal: proposal(), context: context())
        action.proposal.description = "Описание"; action.proposal.checklist = ["Первый", "Второй"]; action.proposal.today = true
        let first = try tasks.createAssistantTask(action, folders: [])
        let second = try tasks.createAssistantTask(action, folders: [])
        #expect(first.id == second.id && first.id == action.id)
        #expect(first.descriptionText == "Описание" && first.checklistItems?.count == 2)
        #expect(first.deadlineDate != nil && !first.deadlineIncludesTime && first.isFocused(on: .now))
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PlannerTask>()) == 1)
    }
    @Test func saveFailureRollsBackWholeTask() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let tasks = TaskService(context: container.mainContext, saveContext: { _ in throw AssistantFailure(message: "test") })
        var action = AssistantAction(proposal: proposal(), context: context()); action.proposal.checklist = ["Один"]
        #expect(throws: (any Error).self) { try tasks.createAssistantTask(action, folders: []) }
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PlannerTask>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<TaskChecklistItem>()) == 0)
    }
    @Test func journalSurvivesReopenAndBlocksUncertainEvent() throws {
        let store = tempStore(); defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        var action = AssistantAction(proposal: proposal(.event), context: context()); action.status = .applying
        var thread = AssistantThread(); thread.actions = [action]; thread.draft = "Черновик"
        try store.save(AssistantArchive(currentID: thread.id, threads: [thread]))
        let service = AssistantService(store: store)
        #expect(service.current?.draft == "Черновик")
        #expect(service.current?.actions.first?.status == .needsReview)
    }
    @Test func badHistoryIsNotSilentlyOverwritten() throws {
        let store = tempStore(); defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: store.url)
        let service = AssistantService(store: store)
        service.newConversation()
        #expect(service.storageFailed && service.archive.threads.isEmpty)
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "broken")
    }
    @Test func editingACloudDraftKeepsItsIdentity() throws {
        var thread = AssistantThread()
        thread.chooseModel(id: "test-model")
        var item = proposal()
        thread = try AssistantService.cloudReply(.init(message: "", actions: [item]),
            to: thread, drafts: [:], text: "Создай задачу", context: context(), edit: nil)
        let original = try #require(thread.actions.first)
        let request = try AssistantCloudRequest(thread: thread, text: "Исправь название",
            context: context(), edit: nil, modelID: "test-model")
        item.key = "draft_1"
        item.title = "Новое название"
        thread = try AssistantService.cloudReply(.init(message: "", actions: [item]),
            to: thread, drafts: request.drafts, text: "Исправь название", context: context(), edit: nil)
        #expect(thread.actions.map(\.id) == [original.id])
        #expect(thread.actions.first?.proposal.title == "Новое название")
    }
    @Test func onlyOneRightPanelAndIndependentWidths() throws {
        let name = "assistant.preferences.\(UUID())"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = AppPreferences(defaults: defaults)
        prefs.calendarOpen = true; #expect(prefs.rightPanel == .calendar)
        prefs.rightPanel = .assistant; #expect(!prefs.calendarOpen)
        prefs.calendarOpen = false; #expect(prefs.rightPanel == .assistant)
        prefs.assistantWidth = 440; prefs.calendarWidth = 340
        let reopened = AppPreferences(defaults: defaults)
        #expect(reopened.rightPanel == .assistant && reopened.assistantWidth == 440 && reopened.calendarWidth == 340)
    }
    @Test func applyTwiceDoesNotDuplicateTaskOrEvent() async throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true), store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let service = AssistantService(store: store)
        var task = AssistantAction(proposal: proposal(), context: context())
        task.proposal.date = nil
        var event = AssistantAction(proposal: proposal(.event), context: context()); event.proposal.linkTo = "task1"
        service.archive.threads[0].actions = [event, task]
        let fake = FakeCalendarStore(); let calendar = CalendarService(store: fake)
        let tasks = TaskService(context: container.mainContext)
        await service.apply(taskService: tasks, calendar: calendar, folders: [])
        await service.apply(taskService: tasks, calendar: calendar, folders: [])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PlannerTask>()) == 1)
        #expect(fake.saves == 1)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<TaskEventLink>()) == 1)
    }
    @Test func missingEventTimeAndTaskReminderNeverAppearReady() {
        var action = AssistantAction(proposal: proposal(.event), context: context()); action.proposal.time = nil
        #expect(!ActionPlanValidator.problems(action, folders: context().folders, calendars: context().calendars).isEmpty)
        action.proposal = proposal(); action.proposal.reminderMinutes = 10
        #expect(!ActionPlanValidator.problems(action, folders: context().folders, calendars: context().calendars).isEmpty)
    }
    @Test func nextRequestCanReuseAModelKeyWithoutReapplyingThePreviousTask() async throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true), store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let service = AssistantService(store: store)
        service.archive.threads[0].chooseModel(id: "test-model")
        var item = proposal()
        item.date = nil
        let tasks = TaskService(context: container.mainContext), calendar = CalendarService(store: FakeCalendarStore())
        service.archive.threads[0] = try AssistantService.cloudReply(.init(message: "", actions: [item]),
            to: service.archive.threads[0], drafts: [:], text: "Создай задачу", context: context(), edit: nil)
        await service.apply(taskService: tasks, calendar: calendar, folders: [])
        let previous = try #require(service.current?.actions.first?.id)
        service.archive.threads[0] = try AssistantService.cloudReply(.init(message: "", actions: [item]),
            to: service.archive.threads[0], drafts: [:], text: "Создай ещё одну задачу", context: context(), edit: nil)
        #expect(service.current?.actions.count == 2)
        #expect(service.current?.actions.last?.id != previous)
        await service.apply(taskService: tasks, calendar: calendar, folders: [])
        await service.apply(taskService: tasks, calendar: calendar, folders: [])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PlannerTask>()) == 2)
    }
    @Test func allDayUsesTheProposalsTimeZone() throws {
        var action = AssistantAction(proposal: proposal(.event), context: context())
        action.proposal.allDay = true; action.proposal.time = nil; action.proposal.date = "2026-03-29"
        action.context.timeZoneID = "Europe/Berlin"
        let draft = try ActionPlanValidator.eventDraft(action)
        #expect(try draft.interval().duration == 23 * 3600)
    }
    @Test func unambiguousChecklistTextObjectsAreAcceptedButFlagsAreNotDiscarded() throws {
        let response = try ActionPlanValidator.decode("{\"message\":\"\",\"actions\":[{\"key\":\"task1\",\"kind\":\"task\",\"title\":\"Проверить\",\"checklist\":[{\"text\":\"Первый\"},{\"title\":\"Второй\"}]}]}")
        #expect(response.actions?.first?.checklist == ["Первый", "Второй"])
        #expect(throws: (any Error).self) { try ActionPlanValidator.decode("{\"message\":\"\",\"actions\":[{\"key\":\"task1\",\"kind\":\"task\",\"title\":\"Проверить\",\"checklist\":[{\"text\":\"Первый\",\"done\":true}]}]}") }
    }
}
