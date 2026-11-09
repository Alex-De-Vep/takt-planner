import AppKit
import Foundation
import SwiftData
import Testing
@testable import Planner

/// Все объекты вымышленные, хранилища временные. Реальные календари не используются.
@MainActor struct AssistantTextTests {
    private func task(_ tasks: TaskService) throws -> PlannerTask {
        let task = try #require(tasks.createTask(in: .week, folders: []))
        tasks.rename(task, to: "Подготовить презентацию")
        #expect(tasks.updateDescription(task, text: "Рассказать о проекте."))
        let item = try #require(tasks.addChecklistItem(to: task))
        #expect(tasks.renameChecklistItem(item, to: "Собрать материалы"))
        tasks.toggleChecklistItem(item)
        return task
    }
    private func service() -> AssistantService {
        AssistantService(model: ModelManager(backend: FakeAIBackend()),
            store: AssistantStore(url: FileManager.default.temporaryDirectory.appending(path: "TextTests-\(UUID())/history.json")))
    }
    private func context(task: PlannerTask? = nil) -> AssistantContext {
        .init(now: .now, timeZoneID: "Europe/Moscow", language: "ru", folders: [.init(id: "inbox", name: "Входящие")], calendars: [],
              defaultFolderID: "inbox", taskID: task?.id.uuidString, taskTitle: task?.title, durationMinutes: 60)
    }
    @Test func snapshotAndProposalDoNotWriteAndKeepTaskIdentity() throws {
        let db = try PlannerPersistence.makeContainer(inMemory: true), tasks = TaskService(context: db.mainContext)
        let task = try task(tasks), other = try #require(tasks.createTask(in: .inbox, folders: []))
        let service = service()
        #expect(service.beginTextEdit(task: task, tasks: tasks))
        var edit = try #require(service.activeTextEdit)
        try edit.propose(.init(title: "Презентация проекта", description: "Структура и результат.", checklist: ["Проверить слайды"]))
        service.updateTextEdit(edit)
        #expect(task.title == "Подготовить презентацию" && task.checklistItems?.count == 1)
        #expect(service.activeTextEdit?.before.id == task.id && service.activeTextEdit?.before.id != other.id)
    }
    @Test func partialApplyIsAtomicIdempotentAndPreservesMetadataAndChecklist() throws {
        let db = try PlannerPersistence.makeContainer(inMemory: true), tasks = TaskService(context: db.mainContext)
        let task = try task(tasks)
        let service = service(); service.beginTextEdit(task: task, tasks: tasks)
        let createdAt = task.createdAt, folder = task.systemFolderKind
        task.focusDay = LocalDay.key(for: .now); task.completedAt = .now
        try db.mainContext.save()
        var edit = try #require(service.activeTextEdit)
        let oldItem = try #require(task.orderedChecklistItems.first)
        try edit.propose(.init(title: "Не применять", description: "Цель\nПлан\nРезультат", checklist: ["Проверить слайды", "  СОБРАТЬ   материалы ", "проверить слайды"]))
        #expect(edit.additions.count == 1)
        edit.includeTitle = false
        service.updateTextEdit(edit); service.applyTextEdit(edit.id, tasks: tasks); service.applyTextEdit(edit.id, tasks: tasks)
        #expect(task.title == "Подготовить презентацию" && task.descriptionText == "Цель\nПлан\nРезультат")
        #expect(task.orderedChecklistItems.map(\.title) == ["Собрать материалы", "Проверить слайды"])
        #expect(task.orderedChecklistItems.first?.id == oldItem.id && oldItem.isCompleted)
        #expect(task.createdAt == createdAt && task.systemFolderKind == folder && task.focusDay != nil && task.completedAt != nil)
        #expect(service.current?.textEdits?.first?.status == .applied)
    }
    @Test func conflictsBlockButUnrelatedChangesDoNot() throws {
        let db = try PlannerPersistence.makeContainer(inMemory: true), tasks = TaskService(context: db.mainContext)
        let task = try task(tasks), service = service()
        service.beginTextEdit(task: task, tasks: tasks)
        var edit = try #require(service.activeTextEdit)
        try edit.propose(.init(description: "Новое описание")); service.updateTextEdit(edit)
        tasks.updateDescription(task, text: "Ручное изменение")
        service.applyTextEdit(edit.id, tasks: tasks)
        #expect(task.descriptionText == "Ручное изменение" && service.activeTextEdit?.error == AssistantTextEdit.conflict)
        service.refreshTextEdit(edit.id, tasks: tasks)
        var fresh = try #require(service.activeTextEdit)
        #expect(fresh.id != edit.id && fresh.before.description == "Ручное изменение")
        try fresh.propose(.init(description: "Новая версия")); service.updateTextEdit(fresh)
        tasks.toggleToday(task)
        service.applyTextEdit(fresh.id, tasks: tasks)
        #expect(task.descriptionText == "Новая версия" && task.isFocused(on: .now))
    }
    @Test func checklistConflictAndDeletedTaskNeverRecreateObjects() throws {
        let db = try PlannerPersistence.makeContainer(inMemory: true), tasks = TaskService(context: db.mainContext)
        let task = try task(tasks), service = service()
        service.beginTextEdit(task: task, tasks: tasks)
        var edit = try #require(service.activeTextEdit)
        try edit.propose(.init(checklist: ["Проверить результат"])); service.updateTextEdit(edit)
        _ = tasks.addChecklistItem(to: task)
        service.applyTextEdit(edit.id, tasks: tasks)
        #expect(service.activeTextEdit?.error == AssistantTextEdit.conflict)
        db.mainContext.delete(task); try db.mainContext.save()
        service.applyTextEdit(edit.id, tasks: tasks)
        #expect(service.activeTextEdit?.error == "Задача больше не существует.")
        #expect(try db.mainContext.fetchCount(FetchDescriptor<PlannerTask>()) == 0)
    }
    @Test func failedSaveKeepsProposalAndRollsBackAllFields() throws {
        let db = try PlannerPersistence.makeContainer(inMemory: true)
        let good = TaskService(context: db.mainContext), task = try task(good)
        let failing = TaskService(context: db.mainContext, saveContext: { _ in throw AssistantFailure(message: "disk") })
        let service = service(); service.beginTextEdit(task: task, tasks: failing)
        var edit = try #require(service.activeTextEdit)
        try edit.propose(.init(title: "Новое", description: "Новое описание", checklist: ["Пункт"]))
        service.updateTextEdit(edit); service.applyTextEdit(edit.id, tasks: failing)
        #expect(task.title == edit.before.title && task.descriptionText == edit.before.description && task.checklistItems?.count == 1)
        #expect(service.activeTextEdit?.status == .pending && service.activeTextEdit?.change.description == "Новое описание")
        #expect(failing.error == nil)
        service.applyTextEdit(edit.id, tasks: good)
        #expect(task.title == "Новое" && task.checklistItems?.count == 2)
    }
    @Test func unsavedDraftBlocksSnapshotAndApply() throws {
        let db = try PlannerPersistence.makeContainer(inMemory: true), tasks = TaskService(context: db.mainContext)
        let task = try task(tasks), service = service()
        service.beginTextEdit(task: task, tasks: tasks)
        var edit = try #require(service.activeTextEdit); try edit.propose(.init(title: "Новое")); service.updateTextEdit(edit)
        tasks.descriptionDrafts[task.id] = "Несохранённое"
        #expect(!service.beginTextEdit(task: task, tasks: tasks))
        service.applyTextEdit(edit.id, tasks: tasks)
        #expect(task.title == edit.before.title && tasks.descriptionDrafts[task.id] == "Несохранённое")
    }
    @Test func draftAcceptDoesNotCreateAndPreservesDestinationDateAndStar() throws {
        let db = try PlannerPersistence.makeContainer(inMemory: true), tasks = TaskService(context: db.mainContext), service = service()
        let action = AssistantAction(proposal: .init(key: "a", kind: .task, title: "Макет", folderID: "week", description: "Коротко", checklist: ["Исходный"], date: "2026-11-10", today: true), context: context())
        service.archive.threads[0].actions = [action]
        service.beginTextEdit(proposal: action)
        var edit = try #require(service.activeTextEdit)
        try edit.propose(.init(description: "Цель, шаги, результат", checklist: ["Исходный", "Новый"]))
        service.updateTextEdit(edit)
        #expect(service.hasUnreviewedText(for: action.id))
        service.applyTextEdit(edit.id, tasks: tasks)
        let result = try #require(service.current?.actions.first)
        #expect(result.proposal.folderID == "week" && result.proposal.date == "2026-11-10" && result.proposal.today == true)
        #expect(result.proposal.description == "Цель, шаги, результат" && result.proposal.checklist == ["Исходный", "Новый"])
        #expect(!service.hasUnreviewedText(for: action.id) && service.current?.textEdits?.first?.status == .accepted)
        #expect(try db.mainContext.fetchCount(FetchDescriptor<PlannerTask>()) == 0)
        service.beginTextEdit(proposal: result)
        #expect(service.activeTextEdit?.before.description == "Цель, шаги, результат")
    }
    @Test func followupKeepsBaselineAndStableAdditionIDs() throws {
        let before = AssistantTextSnapshot(id: UUID(), title: "Название", description: "Текст", checklist: [])
        var edit = AssistantTextEdit(target: .savedTask, before: before)
        try edit.propose(.init(title: "Новое", description: "Подробнее", checklist: ["Первый", "Второй"]))
        edit.additions[0].included = false
        let id = edit.additions[0].id
        edit.change.description = "Ручная правка"
        try edit.propose(.init(title: "Короче", checklist: ["Первый", "Третий"]))
        #expect(edit.before == before && edit.change.description == "Ручная правка")
        #expect(edit.additions[0].id == id && !edit.additions[0].included)
    }
    @Test func interruptedJournalRecoversWithoutDuplicatingSubtasks() throws {
        let db = try PlannerPersistence.makeContainer(inMemory: true), tasks = TaskService(context: db.mainContext), task = try task(tasks)
        let service = service(); service.beginTextEdit(task: task, tasks: tasks)
        var edit = try #require(service.activeTextEdit)
        try edit.propose(.init(title: "Новое", checklist: ["Добавление"]))
        edit.committed = edit.selected; edit.status = .applying
        try tasks.applyAssistantText(edit)
        try tasks.applyAssistantText(edit)
        #expect(task.orderedChecklistItems.count == 2)
        #expect(task.orderedChecklistItems.last?.id == edit.additions.first?.id)
    }
    @Test func oldArchiveDecodesAndUnsupportedVersionsArePreserved() throws {
        let service = service()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(service.archive)) as? [String: Any])
        json["version"] = 1
        let url = FileManager.default.temporaryDirectory.appending(path: "old-text-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let reopened = try AssistantStore(url: url).load()
        #expect(reopened.version == 2 && reopened.threads.count == 1 && reopened.threads[0].textEdits == nil)
        json["version"] = 99
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(throws: (any Error).self) { try AssistantStore(url: url).load() }
    }
    @Test func oversizedSourceIsRejectedWithoutTruncation() throws {
        let before = AssistantTextSnapshot(id: UUID(), title: "Название", description: String(repeating: "А", count: 19000), checklist: [])
        #expect(throws: (any Error).self) { try AssistantTextPrompt.request(edit: .init(target: .savedTask, before: before), thread: AssistantThread(), language: "ru") }
        #expect(AssistantTextPrompt.isTextRequest("Распиши открытую задачу"))
        #expect(!AssistantTextPrompt.isTextRequest("Создай задачу и распиши её"))
        let response = try ActionPlanValidator.decode("{\"message\":\"\",\"textEdit\":{\"description\":\"Цель\\nРезультат\"}}")
        #expect(response.textEdit?.description == "Цель\nРезультат")
    }
    @Test func externalTextReplacementKeepsCursorAndNativeUndo() throws {
        let store = TaskEditorStore(), id = UUID(), editor = store.view(taskID: id, title: false)
        editor.synchronizeDocumentText("Исходный текст")
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.synchronizeDocumentText("Развёрнутое описание задачи")
        #expect(editor.selectedRange().location == 3 && editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        #expect(editor.string == "Исходный текст")
        editor.undoManager?.redo()
        #expect(editor.string == "Развёрнутое описание задачи")
        #expect(store.view(taskID: id, title: false) === editor)
        #expect(store.view(taskID: UUID(), title: false) !== editor)
    }
    @Test func draftChecklistCanBeReplacedAndCancelledWithoutCreatingTask() throws {
        let service = service()
        let action = AssistantAction(proposal: .init(key: "draft", kind: .task, title: "План", folderID: "inbox", checklist: ["Первый", "Второй"]), context: context())
        service.archive.threads[0].actions = [action]
        service.beginTextEdit(proposal: action)
        var edit = try #require(service.activeTextEdit)
        try edit.propose(.init(checklist: ["Первый", "Уточнённый третий"]))
        service.updateTextEdit(edit)
        #expect(edit.selected.checklist.map(\.title) == ["Первый", "Уточнённый третий"])
        service.cancelTextEdit(edit.id)
        #expect(service.current?.actions.first?.proposal.checklist == ["Первый", "Второй"])
        #expect(!service.hasUnreviewedText(for: action.id))
    }
    @Test func allDeselectedAdditionsKeepReviewVisible() throws {
        var edit = AssistantTextEdit(target: .savedTask, before: .init(id: UUID(), title: "Текст", description: "", checklist: []))
        try edit.propose(.init(checklist: ["Проверить"]))
        edit.additions[0].included = false
        #expect(edit.hasChanges && !edit.hasSelection && edit.selected.checklist.isEmpty)
    }
    @Test func generationUsesExplicitTargetAndLeavesCreationProposalsIntact() async throws {
        let backend = TextResponseBackend()
        let fixture = try InstalledModelFixture(backend: backend); defer { fixture.clean() }
        let service = AssistantService(model: fixture.manager, store: AssistantStore(url: FileManager.default.temporaryDirectory.appending(path: "TextGeneration-\(UUID())/chat.json")))
        let db = try PlannerPersistence.makeContainer(inMemory: true), tasks = TaskService(context: db.mainContext), task = try task(tasks)
        let action = AssistantAction(proposal: .init(key: "untouched", kind: .task, title: "Другая задача", folderID: "inbox"), context: context())
        service.archive.threads[0].actions = [action]
        service.beginTextEdit(task: task, tasks: tasks)
        service.send("Распиши описание", context: context(), taskService: tasks)
        while service.generating { await Task.yield() }
        #expect(service.activeTextEdit?.change.description == "Цель\nДействия\nРезультат")
        #expect(service.current?.actions.first?.id == action.id && task.descriptionText == "Рассказать о проекте.")
        let prompt = await backend.lastPrompt
        #expect(prompt.contains("Рассказать о проекте.") && prompt.contains("Собрать материалы"))
        #expect(!prompt.contains("Другая задача"))
    }

    @Test func checklistTextUsesOnlyCompleteJsonAndRemovesTextMarkers() throws {
        let response = try ActionPlanValidator.decode(#"{"message":"","textEdit":{"checklistText":"- Первый\n2. Второй\n\nТретий"}}"#)
        #expect(response.textEdit?.checklist == ["Первый", "Второй", "Третий"])
        #expect(throws: (any Error).self) { try ActionPlanValidator.decode(#"{"message":"","textEdit":{"checklistText":"Оборванный"#) }
    }
    @Test func deselectedInvalidTextDoesNotBlockOtherChanges() throws {
        let db = try PlannerPersistence.makeContainer(inMemory: true), tasks = TaskService(context: db.mainContext), task = try task(tasks), service = service()
        service.beginTextEdit(task: task, tasks: tasks)
        var edit = try #require(service.activeTextEdit)
        edit.change.title = ""; edit.includeTitle = false
        edit.change.description = "Подтверждено"
        service.updateTextEdit(edit); service.applyTextEdit(edit.id, tasks: tasks)
        #expect(task.title == edit.before.title && task.descriptionText == "Подтверждено")
    }
    @Test func libraryAndInterruptedJournalReopenWithoutDuplicateItems() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TextReopen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Tasks.store"), store = AssistantStore(url: directory.appending(path: "chat.json"))
        var taskID: UUID!, expectedItemID: UUID!
        do {
            let db = try PlannerPersistence.makeContainer(at: url), tasks = TaskService(context: db.mainContext), task = try task(tasks)
            taskID = task.id
            let service = AssistantService(model: ModelManager(backend: FakeAIBackend()), store: store)
            service.beginTextEdit(task: task, tasks: tasks)
            var edit = try #require(service.activeTextEdit)
            try edit.propose(.init(title: "Готовая презентация", description: "План\nРезультат", checklist: ["Проверить"]))
            expectedItemID = edit.additions.first?.id
            edit.committed = edit.selected; edit.status = .applying
            service.archive.threads[0].textEdits = [edit]
            #expect(service.persist())
            try tasks.applyAssistantText(edit)
        }
        let reopened = try PlannerPersistence.makeContainer(at: url), tasks = TaskService(context: reopened.mainContext)
        let service = AssistantService(model: ModelManager(backend: FakeAIBackend()), store: store)
        let edit = try #require(service.activeTextEdit)
        #expect(edit.status == .pending && edit.committed != nil)
        service.applyTextEdit(edit.id, tasks: tasks)
        let task = try #require(try tasks.assistantTask(id: taskID))
        #expect(task.title == "Готовая презентация" && task.descriptionText == "План\nРезультат")
        #expect(task.orderedChecklistItems.count == 2 && task.orderedChecklistItems.last?.id == expectedItemID)
        #expect(service.current?.textEdits?.first?.status == .applied)
    }

}

actor TextResponseBackend: LocalAIBackend {
    var lastPrompt = ""
    func prepare(directory: URL) async throws {}
    func unload() async {}
    func respond(instructions: String, prompt: String) async throws -> String {
        lastPrompt = prompt
        return #"{"message":"","questions":[],"actions":[],"textEdit":{"description":"Цель\nДействия\nРезультат"}}"#
    }
}
