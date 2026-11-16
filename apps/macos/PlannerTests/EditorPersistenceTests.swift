import AppKit
import Foundation
import SwiftData
import Testing
@testable import Planner

@MainActor
struct EditorPersistenceTests {
    @Test func taskEditsWaitForPauseAndReopenFromDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaskText-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Planner.store")
        let db = try PlannerPersistence.makeContainer(at: url)
        var saves = 0
        let service = TaskService(context: db.mainContext, textSaveDelay: .milliseconds(75)) {
            saves += 1
            try $0.save()
        }
        let task = try #require(service.createTask(in: .inbox, folders: []))
        let item = try #require(service.addChecklistItem(to: task))
        let originalTitle = task.title
        let baseline = saves
        service.editTitle(task, text: "Чернов")
        service.editTitle(task, text: "Черновик 👋")
        service.editDescription(task, text: "Первая строка")
        service.editDescription(task, text: "Первая строка\nВторая строка")
        service.editChecklistTitle(item, text: "Шаг")
        service.editChecklistTitle(item, text: "Шаг 1")
        #expect(service.title(for: task) == "Черновик 👋")
        #expect(service.description(for: task) == "Первая строка\nВторая строка")
        #expect(service.checklistTitle(for: item) == "Шаг 1")
        #expect(task.title == originalTitle && task.descriptionText.isEmpty && item.title.isEmpty)
        #expect(saves == baseline)

        let timeout = ContinuousClock.now + .seconds(3)
        while saves < baseline + 3 && ContinuousClock.now < timeout {
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(saves == baseline + 3)
        let reopened = try PlannerPersistence.makeContainer(at: url)
        let saved = try #require(reopened.mainContext.fetch(FetchDescriptor<PlannerTask>()).first)
        #expect(saved.title == "Черновик 👋")
        #expect(saved.descriptionText == "Первая строка\nВторая строка")
        #expect(saved.orderedChecklistItems.map(\.title) == ["Шаг 1"])
    }

    @Test func editingEndSavesLatestTextAndFailedSaveCanBeRetried() throws {
        let db = try PlannerPersistence.makeContainer(inMemory: true)
        var fail = false
        let service = TaskService(context: db.mainContext, textSaveDelay: .seconds(60)) {
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try $0.save()
        }
        let task = try #require(service.createTask(in: .inbox, folders: []))
        let other = try #require(service.createTask(in: .inbox, folders: []))
        let store = TaskEditorStore()
        let host = TaskEditorHost(editor: store.view(taskID: task.id, title: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        let coordinator = PlainTextTaskEditor.Coordinator()
        coordinator.host = host
        coordinator.changed = { service.editDescription(task, text: $0) }
        coordinator.endEditing = { service.flushText(.description(task.id)) }
        host.editor.delegate = coordinator
        #expect(window.makeFirstResponder(host.editor))
        host.editor.insertText("Ввод до ухода из поля", replacementRange: NSRange(location: 0, length: 0))
        service.editDescription(other, text: "Другая задача")
        #expect(task.descriptionText.isEmpty)

        fail = true
        #expect(window.makeFirstResponder(nil))
        #expect(task.descriptionText.isEmpty)
        #expect(service.description(for: task) == "Ввод до ухода из поля")
        #expect(service.descriptionDrafts[task.id] == "Ввод до ухода из поля")

        fail = false
        #expect(service.flushEditorText(taskID: task.id))
        #expect(task.descriptionText == "Ввод до ухода из поля")
        #expect(other.descriptionText.isEmpty)
        #expect(service.flushEditorText())
        #expect(other.descriptionText == "Другая задача")
    }

    @Test func assistantDraftsDoNotRewriteHistoryAndFollowTheirConversation() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ChatDraft-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AssistantStore(url: directory.appending(path: "history.json"))
        let service = AssistantService(store: store)
        let first = try #require(service.current?.id)
        let history = try Data(contentsOf: store.url)
        service.setDraft("Первый черновик")
        #expect(try Data(contentsOf: store.url) == history)
        #expect(AssistantService(store: store).current?.draft == "Первый черновик")

        service.newConversation()
        let second = try #require(service.current?.id)
        service.setDraft("Второй черновик")
        service.setDraft("Первый черновик после переключения", for: first)
        #expect(service.current?.draft == "Второй черновик")
        service.selectConversation(first)
        #expect(service.current?.draft == "Первый черновик после переключения")
        service.setDraft("")
        let reopened = AssistantService(store: store)
        #expect(reopened.current?.draft == "")
        reopened.selectConversation(second)
        #expect(reopened.current?.draft == "Второй черновик")
    }

    @Test func legacyDraftSurvivesMigrationAndOnlySuccessfulSendConsumesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "LegacyChatDraft-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AssistantStore(url: directory.appending(path: "history.json"))
        var legacy = AssistantThread()
        legacy.draft = "Старый черновик"
        try JSONEncoder().encode(AssistantArchive(currentID: legacy.id, threads: [legacy])).write(to: store.url)
        let service = AssistantService(store: store)
        #expect(service.current?.draft == legacy.draft)
        #expect(service.persist())
        let history = try JSONDecoder().decode(AssistantArchive.self, from: Data(contentsOf: store.url))
        #expect(history.threads.first?.draft == "")
        #expect(try store.load().threads.first?.draft == legacy.draft)

        let backup = directory.appending(path: "backup.json")
        try FileManager.default.moveItem(at: store.url, to: backup)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        let reply = AssistantMessage(role: .assistant, text: "Ответ")
        let thread = try #require(service.current)
        service.recordLocalReply(thread.draft, reply: reply, thread: thread, at: 0)
        #expect(service.current?.draft == legacy.draft)
        #expect(service.current?.messages.isEmpty == true)
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.moveItem(at: backup, to: store.url)
        #expect(try store.load().threads.first?.draft == legacy.draft)

        service.recordLocalReply(thread.draft, reply: reply, thread: thread, at: 0)
        // Simulate interruption after history commit but before the old draft file was removed.
        try store.saveDraft(AssistantStore.Draft(thread), for: thread.id)
        let reopened = try #require(AssistantService(store: store).current)
        #expect(reopened.draft.isEmpty)
        #expect(reopened.messages.map(\.text) == [legacy.draft, reply.text])
    }
}
