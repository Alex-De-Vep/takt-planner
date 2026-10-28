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
        let service = AssistantService(model: ModelManager(backend: FakeAIBackend()), store: store)
        #expect(service.current?.draft == "Черновик")
        #expect(service.current?.actions.first?.status == .needsReview)
    }
    @Test func badHistoryIsNotSilentlyOverwritten() throws {
        let store = tempStore(); defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: store.url)
        let service = AssistantService(model: ModelManager(backend: FakeAIBackend()), store: store)
        service.newConversation()
        #expect(service.storageFailed && service.archive.threads.isEmpty)
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "broken")
    }
    @Test func conversationGenerationAndClarificationKeepActionIdentity() async throws {
        let backend = FakeAIBackend()
        let model = ModelManager(backend: backend); model.state = .ready
        let store = tempStore(); defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let service = AssistantService(model: model, store: store)
        service.send("Создай задачу", context: context())
        while service.generating { await Task.yield() }
        let id = try #require(service.current?.actions.first?.id)
        service.send("Исправь название", context: context())
        while service.generating { await Task.yield() }
        #expect(service.current?.actions.first?.id == id)
        #expect(service.current?.messages.count == 4)
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
        let service = AssistantService(model: ModelManager(backend: FakeAIBackend()), store: store)
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
    @Test func modelInstallationVerifiesAndReusesFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "model-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = ModelManifest.File(name: "test.bin", bytes: 3, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let manifest = ModelManifest(id: "test/model", revision: "fixed", files: [file])
        let download = FakeModelDownload()
        let defaults = UserDefaults(suiteName: "model-test-\(UUID())")!
        let manager = ModelManager(backend: FakeAIBackend(), directory: directory, defaults: defaults, manifest: manifest, downloaderFactory: { download })
        manager.install(); manager.install()
        while manager.busy { await Task.yield() }
        #expect(manager.state == .ready && manager.enabled)
        #expect(try Data(contentsOf: directory.appending(path: "test.bin")) == Data("abc".utf8))
        await manager.disable(); #expect(!manager.enabled)
        manager.install()
        while manager.busy { await Task.yield() }
        #expect(manager.state == .ready)
        await manager.remove()
        #expect(!FileManager.default.fileExists(atPath: directory.path) && !manager.enabled)
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
        let model = ModelManager(backend: FakeAIBackend()); model.state = .ready
        let service = AssistantService(model: model, store: store)
        let tasks = TaskService(context: container.mainContext), calendar = CalendarService(store: FakeCalendarStore())
        service.send("Создай задачу", context: context())
        while service.generating { await Task.yield() }
        await service.apply(taskService: tasks, calendar: calendar, folders: [])
        let previous = try #require(service.current?.actions.first?.id)
        service.send("Создай ещё одну задачу", context: context())
        while service.generating { await Task.yield() }
        #expect(service.current?.actions.count == 2)
        #expect(service.current?.actions.last?.id != previous)
        await service.apply(taskService: tasks, calendar: calendar, folders: [])
        await service.apply(taskService: tasks, calendar: calendar, folders: [])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PlannerTask>()) == 2)
    }
    @Test func modelCannotInventEventReminders() {
        var p = proposal(.event); p.reminderMinutes = 60
        var thread = AssistantThread(); thread.messages = [AssistantMessage(role: .user, text: "Создай встречу завтра в 12:00")]
        let response = AssistantResponse(message: "", actions: [p])
        let corrected = AssistantResponsePolicy.normalize(response, thread: thread, context: context())
        #expect(corrected.actions?.first?.reminderMinutes == nil)
        var english = context(); english.language = "en"
        #expect(AssistantResponsePolicy.normalize(response, thread: thread, context: english).message == "Review the proposals before creating them.")
        thread.messages.append(AssistantMessage(role: .user, text: "Напомни за час"))
        #expect(AssistantResponsePolicy.normalize(response, thread: thread, context: context()).actions?.first?.reminderMinutes == 60)
    }
    @Test func allDayUsesTheProposalsTimeZone() throws {
        var action = AssistantAction(proposal: proposal(.event), context: context())
        action.proposal.allDay = true; action.proposal.time = nil; action.proposal.date = "2026-03-29"
        action.context.timeZoneID = "Europe/Berlin"
        let draft = try ActionPlanValidator.eventDraft(action)
        #expect(try draft.interval().duration == 23 * 3600)
    }
    @Test func modelHashesDetectTampering() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        #expect(try ModelManager.valid(url, file: ModelManifest.File(name: "test", bytes: 3, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")))
        try Data("abd".utf8).write(to: url)
        #expect(try !ModelManager.valid(url, file: ModelManifest.File(name: "test", bytes: 3, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")))
    }
}

actor FakeAIBackend: LocalAIBackend {
    func prepare(directory: URL) async throws {}
    func unload() async {}
    func respond(instructions: String, prompt: String) async throws -> String {
        """
        {"message":"Проверьте предложение","actions":[{"key":"task1","kind":"task","title":"Проверка","folderID":"inbox"}],"questions":[]}
        """
    }
}

final class FakeModelDownload: ModelFileDownloading, @unchecked Sendable {
    func download(url: URL, to target: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try Task.checkCancellation()
        try Data("abc".utf8).write(to: target, options: .atomic)
        progress(3)
    }
    func cancel() {}
}
