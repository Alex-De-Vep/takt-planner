import Foundation
import SwiftData
import Testing
@testable import Planner

@MainActor
struct BackupTests {
    @Test func restoredLibraryReopensWithoutCloudProfile() throws {
        let suite = "local.planner.restore.test." + UUID().syncID
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = SyncAccount(id: UUID().syncID, email: "old@example.test", libraryId: UUID().syncID)
        defaults.set(try JSONEncoder().encode(SyncProfile(account: account, sessionID: UUID().syncID)),
                     forKey: "planner.cloud.profile")
        let runtime = AppRuntime(defaults: defaults, loadOnInit: false)
        let preferences = AppPreferences(defaults: defaults)
        let entry = PlannerBackup.Entry(id: UUID(), title: "Восстановленная задача", description: "Из файла",
            createdAt: .now, updatedAt: .now, completedAt: nil, focusDay: nil, planningKind: nil,
            planningAnchor: nil, deadlineDate: nil, deadlineIncludesTime: false, deadlineTimeZoneID: nil,
            systemFolder: "inbox", folderID: nil, checklist: [], calendarLinks: [])
        var thread = AssistantThread()
        thread.draft = "Восстановленный черновик"
        let conversations = try JSONEncoder().encode(AssistantArchive(currentID: thread.id, threads: [thread]))
        try runtime.restore(PlannerBackup(folders: [], tasks: [entry], conversations: conversations), preferences: preferences)
        let id = try #require(defaults.string(forKey: PlannerPersistence.restoredLibraryKey).flatMap(UUID.init(uuidString:)))
        let directory = try PlannerPersistence.restoredLibraryDirectory(id)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(runtime.cloud.profile == nil && runtime.cloud.engine == nil)

        let reopened = AppRuntime(defaults: defaults)
        #expect(reopened.cloud.engine == nil && reopened.service?.syncRepository == nil)
        let context = try #require(reopened.service?.context)
        #expect(try context.fetch(FetchDescriptor<PlannerTask>()).map(\.id) == [entry.id])
        #expect(reopened.assistant?.current?.draft == "Восстановленный черновик")
    }

    @Test func offlineBackupRestoresLatestEditsAndCanSeedAnEmptyCloudLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaktBackup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: source.mainContext, textSaveDelay: .seconds(60))
        let sourceRepo = try SyncRepository(context: source.mainContext, libraryID: UUID().syncID, deviceID: UUID().syncID)
        service.syncRepository = sourceRepo
        let folder = try service.saveFolder(name: "Проект")
        let task = try #require(service.createTask(in: .folder(folder.id), folders: [folder]))
        let item = try #require(service.addChecklistItem(to: task))
        service.editTitle(task, text: "Изменение без интернета")
        service.editDescription(task, text: "Последний текст\n🙂")
        service.editChecklistTitle(item, text: "Проверить копию")
        #expect(service.toggleChecklistItem(item))
        #expect(service.markToday(task))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(service.setDeadline(task, to: TaskDeadline(date: date, includesTime: true, timeZoneID: "Europe/Moscow")))
        #expect(service.link(CalendarEvent(identifier: "event", externalIdentifier: "external",
            calendarID: "test", title: "Встреча", start: date, end: date.addingTimeInterval(1800)), to: task))

        let assistant = AssistantService(store: AssistantStore(url: directory.appending(path: "source/chat.json")))
        assistant.setDraft("Неотправленное сообщение")
        let suite = "local.planner.backup.test." + UUID().syncID
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("do-not-export", forKey: "planner.cloud.profile")
        let preferences = AppPreferences(defaults: defaults)
        preferences.reviewNotificationMinutes = 750
        let url = directory.appending(path: "copy.json")
        try PlannerBackup.capture(from: service, assistant: assistant, preferences: preferences).write(to: url)
        let backup = try PlannerBackup.read(from: url)
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("do-not-export"))
        #expect(try backup.assistantArchive()?.threads.first?.draft == "Неотправленное сообщение")
        #expect(backup.preferences?.reviewMinutes == 750)
        #expect(try sourceRepo.counts().pending > 0)

        let localURL = directory.appending(path: "restored/Planner.store")
        try autoreleasepool {
            let restored = try PlannerPersistence.makeContainer(at: localURL)
            try backup.restore(in: restored.mainContext)
        }
        let restored = try PlannerPersistence.makeContainer(at: localURL)
        let restoredTask = try #require(restored.mainContext.fetch(FetchDescriptor<PlannerTask>()).first)
        #expect(restoredTask.id == task.id && restoredTask.folder?.id == folder.id)
        #expect(restoredTask.title == "Изменение без интернета")
        #expect(restoredTask.descriptionText == "Последний текст\n🙂")
        #expect(restoredTask.deadline == task.deadline && restoredTask.focusDay == task.focusDay)
        #expect(restoredTask.updatedAt == task.updatedAt && restoredTask.createdAt == task.createdAt)
        #expect(restoredTask.orderedChecklistItems.first?.id == item.id)
        #expect(restoredTask.orderedChecklistItems.first?.title == "Проверить копию")
        #expect(restoredTask.orderedChecklistItems.first?.isCompleted == true)
        #expect(restoredTask.eventLinks?.first?.externalIdentifier == "external")
        #expect(try restored.mainContext.fetchCount(FetchDescriptor<PlannerSchemaV6.SyncQueueItem>()) == 0)

        let cloud = try PlannerPersistence.makeContainer(inMemory: true)
        let repo = try SyncRepository(context: cloud.mainContext, libraryID: UUID().syncID, deviceID: UUID().syncID)
        let empty = SyncSnapshot(protocolVersion: 1, libraryId: repo.libraryID, cursor: "0", initialized: true, entities: [])
        try repo.applySnapshot(empty)
        try repo.mergeLocal(from: restored.mainContext)
        try repo.mergeLocal(from: restored.mainContext)
        try repo.applySnapshot(empty)
        let pending = try repo.pendingOperations()
        #expect(pending.map(\.entityType) == [.folder, .task, .checklistItem])
        #expect(pending.allSatisfy { $0.libraryId == repo.libraryID && $0.kind == .create })
        #expect(pending.first { $0.entityId == task.id.syncID }?.changes?["description"]?.value == .text("Последний текст\n🙂"))
        #expect(try cloud.mainContext.fetchCount(FetchDescriptor<PlannerTask>()) == 1)
    }

    @Test func unexpectedServerResetPreservesLocalDataButExplicitDeletionStillWorks() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let repo = try SyncRepository(context: container.mainContext, libraryID: UUID().syncID, deviceID: UUID().syncID)
        let model = try #require(SyncLocalEntity(PlannerTask(title: "Keep me")))
        var entity = SyncEntity(id: model.id, type: .task, fields: model.fields, versions: [:], deleted: false, revision: "5")
        try repo.applySnapshot(.init(protocolVersion: 1, libraryId: repo.libraryID, cursor: "5", initialized: true, entities: [entity]))

        for cursor in ["0", "5", "7"] {
            #expect(throws: SyncProblem.libraryReset) {
                try repo.applySnapshot(.init(protocolVersion: 1, libraryId: repo.libraryID,
                    cursor: cursor, initialized: true, entities: []))
            }
        }
        #expect(repo.cursor == "5")
        #expect(try container.mainContext.fetch(FetchDescriptor<PlannerTask>()).first?.title == "Keep me")

        entity.deleted = true
        entity.revision = "6"
        try repo.applySnapshot(.init(protocolVersion: 1, libraryId: repo.libraryID, cursor: "6", initialized: true, entities: [entity]))
        #expect(repo.cursor == "6")
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PlannerTask>()) == 0)
    }

    @Test func invalidAndFutureBackupsDoNotRestoreData() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "InvalidBackup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "copy.json")
        try Data("{\"format\":\"takt.backup\",\"version\":99}".utf8).write(to: url)
        #expect(throws: BackupError.unsupportedVersion) { try PlannerBackup.read(from: url) }
        try Data("{\"format\":\"takt.backup\",\"version\":1}".utf8).write(to: url)
        #expect(throws: BackupError.invalid) { try PlannerBackup.read(from: url) }

        let row = PlannerBackup.Folder(id: UUID(), name: "Duplicate", sortOrder: 0)
        let invalid = PlannerBackup(folders: [row, row], tasks: [])
        let destination = try PlannerPersistence.makeContainer(inMemory: true)
        #expect(throws: BackupError.invalid) { try invalid.restore(in: destination.mainContext) }
        #expect(try destination.mainContext.fetchCount(FetchDescriptor<TaskFolder>()) == 0)
    }
}
