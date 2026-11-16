import Foundation
import SwiftData

enum BackupError: LocalizedError {
    case invalid, unsupportedVersion, tooLarge, unsavedChanges, busy

    var errorDescription: String? {
        switch self {
        case .invalid: "Файл не является корректной резервной копией Takt."
        case .unsupportedVersion: "Эта резервная копия требует более новой версии Takt."
        case .tooLarge: "Резервная копия превышает 128 МиБ."
        case .unsavedChanges: "Сначала сохраните открытые черновики."
        case .busy: "Дождитесь завершения текущей операции и повторите."
        }
    }
}

struct PlannerBackup: Codable, Sendable {
    private static let magic = "takt.backup"
    private static let maximumBytes = 128 * 1024 * 1024

    var format = Self.magic
    var version = 1
    var createdAt = Date()
    var folders: [Folder]
    var tasks: [Entry]
    var conversations: Data?
    var preferences: BackupPreferences?
    var notes: [PlannerNote]? = nil

    struct Folder: Codable, Sendable {
        let id: UUID
        let name: String
        let sortOrder: Int
    }

    struct Entry: Codable, Sendable {
        let id: UUID
        let title: String
        let description: String
        let createdAt: Date
        let updatedAt: Date
        let completedAt: Date?
        let focusDay: String?
        let planningKind: String?
        let planningAnchor: Date?
        let deadlineDate: Date?
        let deadlineIncludesTime: Bool
        let deadlineTimeZoneID: String?
        let systemFolder: String
        let folderID: UUID?
        let checklist: [ChecklistItem]
        let calendarLinks: [CalendarLink]
    }

    struct ChecklistItem: Codable, Sendable {
        let id: UUID
        let title: String
        let isCompleted: Bool
        let sortOrder: Int
    }

    struct CalendarLink: Codable, Sendable {
        let id: UUID
        let eventIdentifier: String
        let externalIdentifier: String?
        let lastTitle: String
        let lastStart: Date
    }

    @MainActor
    static func capture(from service: TaskService, assistant: AssistantService, preferences: AppPreferences) throws -> Self {
        guard service.notes.flush(), service.flushEditorText(), service.titleDrafts.isEmpty, service.descriptionDrafts.isEmpty,
              service.checklistDrafts.isEmpty else {
            throw BackupError.unsavedChanges
        }
        let history = assistant.storageFailed && assistant.archive.threads.isEmpty
            ? nil : try JSONEncoder().encode(assistant.archive)
        let context = service.context
        let folders = try context.fetch(FetchDescriptor<TaskFolder>()).map {
            Folder(id: $0.id, name: $0.name, sortOrder: $0.sortOrder)
        }
        let tasks = try context.fetch(FetchDescriptor<PlannerTask>()).map { task in
            Entry(id: task.id, title: task.title, description: task.descriptionText,
                createdAt: task.createdAt, updatedAt: task.updatedAt, completedAt: task.completedAt,
                focusDay: task.focusDay, planningKind: task.planningKind, planningAnchor: task.planningAnchor,
                deadlineDate: task.deadlineDate, deadlineIncludesTime: task.deadlineIncludesTime,
                deadlineTimeZoneID: task.deadlineTimeZoneID, systemFolder: task.systemFolderKind,
                folderID: task.folder?.id,
                checklist: task.orderedChecklistItems.map {
                    ChecklistItem(id: $0.id, title: $0.title, isCompleted: $0.isCompleted, sortOrder: $0.sortOrder)
                }, calendarLinks: (task.eventLinks ?? []).filter { !$0.isDeleted }.map {
                    CalendarLink(id: $0.id, eventIdentifier: $0.eventIdentifier, externalIdentifier: $0.externalIdentifier,
                                 lastTitle: $0.lastTitle, lastStart: $0.lastStart)
                })
        }
        var notes = service.notes.notes
        let validFolders = Set(folders.map { "folder-" + $0.id.uuidString })
        for index in notes.indices where notes[index].folder.hasPrefix("folder-") && !validFolders.contains(notes[index].folder) {
            notes[index].folder = "inbox"
        }
        return Self(version: notes.isEmpty ? 1 : 2, folders: folders, tasks: tasks, conversations: history,
                    preferences: BackupPreferences(preferences), notes: notes)
    }

    func write(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw BackupError.tooLarge }
        try data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw BackupError.invalid }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw BackupError.tooLarge }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        struct Header: Decodable { let format: String; let version: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.format == magic else {
            throw BackupError.invalid
        }
        guard (1...2).contains(header.version) else { throw BackupError.unsupportedVersion }
        guard let backup = try? JSONDecoder().decode(Self.self, from: data) else { throw BackupError.invalid }
        try backup.validate()
        return backup
    }

    func assistantArchive() throws -> AssistantArchive? {
        guard let conversations else { return nil }
        guard let archive = try? JSONDecoder().decode(AssistantArchive.self, from: conversations),
              (1...2).contains(archive.version),
              Set(archive.threads.map(\.id)).count == archive.threads.count,
              archive.currentID.map({ id in archive.threads.contains { $0.id == id } }) ?? true else {
            throw BackupError.invalid
        }
        return archive
    }

    func validate() throws {
        guard format == Self.magic else { throw BackupError.invalid }
        guard (1...2).contains(version) else { throw BackupError.unsupportedVersion }
        let folderIDs = Set(folders.map(\.id))
        var ids = folderIDs
        guard ids.count == folders.count else { throw BackupError.invalid }
        for task in tasks {
            guard ids.insert(task.id).inserted, task.folderID.map(folderIDs.contains) ?? true else {
                throw BackupError.invalid
            }
            for item in task.checklist where !ids.insert(item.id).inserted { throw BackupError.invalid }
            for link in task.calendarLinks where !ids.insert(link.id).inserted { throw BackupError.invalid }
        }
        if let notes {
            guard Set(notes.map(\.id)).count == notes.count else { throw BackupError.invalid }
        }
        _ = try assistantArchive()
    }

    @MainActor
    func restore(in context: ModelContext) throws {
        try validate()
        // Restore only into a new library. The original remains available if any step fails.
        guard try context.fetchCount(FetchDescriptor<TaskFolder>()) == 0,
              try context.fetchCount(FetchDescriptor<PlannerTask>()) == 0,
              try context.fetchCount(FetchDescriptor<TaskChecklistItem>()) == 0,
              try context.fetchCount(FetchDescriptor<TaskEventLink>()) == 0 else { throw BackupError.invalid }
        var restoredFolders: [UUID: TaskFolder] = [:]
        for row in folders {
            let folder = TaskFolder(name: row.name, sortOrder: row.sortOrder)
            folder.id = row.id
            context.insert(folder)
            restoredFolders[row.id] = folder
        }
        for row in tasks {
            let task = PlannerTask(title: row.title, folder: row.folderID.flatMap { restoredFolders[$0] }, now: row.createdAt)
            task.id = row.id
            task.descriptionText = row.description
            task.updatedAt = row.updatedAt
            task.completedAt = row.completedAt
            task.focusDay = row.focusDay
            task.planningKind = row.planningKind
            task.planningAnchor = row.planningAnchor
            task.deadlineDate = row.deadlineDate
            task.deadlineIncludesTime = row.deadlineIncludesTime
            task.deadlineTimeZoneID = row.deadlineTimeZoneID
            task.systemFolderKind = row.systemFolder
            context.insert(task)
            for child in row.checklist {
                let item = TaskChecklistItem(task: task, title: child.title, sortOrder: child.sortOrder)
                item.id = child.id
                item.isCompleted = child.isCompleted
                context.insert(item)
            }
            for child in row.calendarLinks {
                let event = CalendarEvent(identifier: child.eventIdentifier, externalIdentifier: child.externalIdentifier,
                    calendarID: "", title: child.lastTitle, start: child.lastStart, end: child.lastStart)
                let link = TaskEventLink(task: task, event: event)
                link.id = child.id
                context.insert(link)
            }
        }
        do { try context.save() }
        catch { context.rollback(); throw error }
    }
}
