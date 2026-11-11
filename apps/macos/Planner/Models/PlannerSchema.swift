import Foundation
import SwiftData
import PlannerLocalization

/// Фиксируем первую версию схемы, чтобы будущие изменения можно было переносить миграциями.
enum PlannerSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [PlannerTask.self, TaskFolder.self, LibraryState.self] }

    @Model
    final class PlannerTask {
        var id: UUID = UUID()
        var title: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var completedAt: Date?
        // Звёздочка привязана к местной календарной дате и не остаётся активной навсегда.
        var focusDay: String?
        var planningKind: String?
        var planningAnchor: Date?
        var folder: TaskFolder?

        init(title: String = "", folder: TaskFolder? = nil, now: Date = .now) {
            self.title = title
            self.folder = folder
            createdAt = now
            updatedAt = now
        }

        func displayTitle(using strings: Translations) -> String {
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? strings["Новая задача"] : title
        }

        var isCompleted: Bool { completedAt != nil }
    }

    @Model
    // Удаление папки не удаляет задачи: связь обнуляется, задачи остаются во «Входящих».
    final class TaskFolder {
        var id: UUID = UUID()
        var name: String = ""
        var sortOrder: Int = 0
        @Relationship(deleteRule: .nullify, inverse: \PlannerTask.folder)
        var tasks: [PlannerTask]? = []

        init(name: String, sortOrder: Int) {
            self.name = name
            self.sortOrder = sortOrder
        }
    }

    @Model
    final class LibraryState {
        // Маркер ранней версии. Сохраняем тип в схеме для разовой уборки старых стартовых папок.
        var initializedAt: Date = Date()
        init() {}
    }
}

/// Новая схема добавляет описание и связи, не меняя зафиксированную структуру V1.
enum PlannerSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [PlannerTask.self, TaskFolder.self, LibraryState.self, TaskEventLink.self] }

    @Model final class PlannerTask {
        var id: UUID = UUID()
        var title: String = ""
        var descriptionText: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var completedAt: Date?
        var focusDay: String?
        var planningKind: String?
        var planningAnchor: Date?
        var folder: TaskFolder?
        @Relationship(deleteRule: .cascade, inverse: \TaskEventLink.task)
        var eventLinks: [TaskEventLink]? = []

        init(title: String = "", folder: TaskFolder? = nil, now: Date = .now) {
            self.title = title; self.folder = folder
            createdAt = now; updatedAt = now
        }
        func displayTitle(using strings: Translations) -> String {
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? strings["Новая задача"] : title
        }
        var isCompleted: Bool { completedAt != nil }
    }

    @Model final class TaskFolder {
        var id: UUID = UUID()
        var name: String = ""
        var sortOrder: Int = 0
        @Relationship(deleteRule: .nullify, inverse: \PlannerTask.folder)
        var tasks: [PlannerTask]? = []
        init(name: String, sortOrder: Int) { self.name = name; self.sortOrder = sortOrder }
    }

    @Model final class LibraryState {
        var initializedAt: Date = Date()
        init() {}
    }

    @Model final class TaskEventLink {
        var id: UUID = UUID()
        var eventIdentifier: String = ""
        var externalIdentifier: String?
        // Последние известные данные нужны для понятной строки при недоступном календаре.
        var lastTitle: String = ""
        var lastStart: Date = Date()
        var task: PlannerTask?
        init(task: PlannerTask, event: CalendarEvent) {
            self.task = task; eventIdentifier = event.identifier
            externalIdentifier = event.externalIdentifier
            lastTitle = event.title; lastStart = event.start
        }
    }
}

/// Подзадачи добавлены отдельной версией; опубликованные V1 и V2 остаются неизменными.
enum PlannerSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(3, 0, 0) }
    static var models: [any PersistentModel.Type] { [PlannerTask.self, TaskFolder.self, LibraryState.self, TaskEventLink.self, TaskChecklistItem.self] }

    @Model final class PlannerTask {
        var id: UUID = UUID()
        var title: String = ""
        var descriptionText: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var completedAt: Date?
        var focusDay: String?
        var planningKind: String?
        var planningAnchor: Date?
        var folder: TaskFolder?
        @Relationship(deleteRule: .cascade, inverse: \TaskEventLink.task)
        var eventLinks: [TaskEventLink]? = []
        @Relationship(deleteRule: .cascade, inverse: \TaskChecklistItem.task)
        var checklistItems: [TaskChecklistItem]? = []

        init(title: String = "", folder: TaskFolder? = nil, now: Date = .now) {
            self.title = title; self.folder = folder
            createdAt = now; updatedAt = now
        }
        func displayTitle(using strings: Translations) -> String {
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? strings["Новая задача"] : title
        }
        var isCompleted: Bool { completedAt != nil }
    }

    @Model final class TaskFolder {
        var id: UUID = UUID()
        var name: String = ""
        var sortOrder: Int = 0
        @Relationship(deleteRule: .nullify, inverse: \PlannerTask.folder)
        var tasks: [PlannerTask]? = []
        init(name: String, sortOrder: Int) { self.name = name; self.sortOrder = sortOrder }
    }

    @Model final class LibraryState {
        var initializedAt: Date = Date()
        init() {}
    }

    @Model final class TaskEventLink {
        var id: UUID = UUID()
        var eventIdentifier: String = ""
        var externalIdentifier: String?
        // Последние известные данные нужны для понятной строки при недоступном календаре.
        var lastTitle: String = ""
        var lastStart: Date = Date()
        var task: PlannerTask?
        init(task: PlannerTask, event: CalendarEvent) {
            self.task = task; eventIdentifier = event.identifier
            externalIdentifier = event.externalIdentifier
            lastTitle = event.title; lastStart = event.start
        }
    }

    /// Пункты принадлежат задаче; порядок сохраняется независимо от отметки выполнения.
    @Model final class TaskChecklistItem {
        var id: UUID = UUID()
        var title: String = ""
        var isCompleted: Bool = false
        var sortOrder: Int = 0
        var task: PlannerTask?

        init(task: PlannerTask, title: String = "", sortOrder: Int) {
            self.task = task
            self.title = title
            self.sortOrder = sortOrder
        }
    }
}

/// Срок задачи добавляется без изменения опубликованной схемы V3.
enum PlannerSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(4, 0, 0) }
    static var models: [any PersistentModel.Type] { [PlannerTask.self, TaskFolder.self, LibraryState.self, TaskEventLink.self, TaskChecklistItem.self] }

    @Model final class PlannerTask {
        var id: UUID = UUID()
        var title: String = ""
        var descriptionText: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var completedAt: Date?
        var focusDay: String?
        var planningKind: String?
        var planningAnchor: Date?
        // Срок независим от звезды и периодов планирования.
        var deadlineDate: Date?
        var deadlineIncludesTime: Bool = false
        var deadlineTimeZoneID: String?
        var folder: TaskFolder?
        @Relationship(deleteRule: .cascade, inverse: \TaskEventLink.task)
        var eventLinks: [TaskEventLink]? = []
        @Relationship(deleteRule: .cascade, inverse: \TaskChecklistItem.task)
        var checklistItems: [TaskChecklistItem]? = []

        init(title: String = "", folder: TaskFolder? = nil, now: Date = .now) {
            self.title = title; self.folder = folder
            createdAt = now; updatedAt = now
        }
        func displayTitle(using strings: Translations) -> String {
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? strings["Новая задача"] : title
        }
        var isCompleted: Bool { completedAt != nil }
    }

    @Model final class TaskFolder {
        var id: UUID = UUID()
        var name: String = ""
        var sortOrder: Int = 0
        @Relationship(deleteRule: .nullify, inverse: \PlannerTask.folder)
        var tasks: [PlannerTask]? = []
        init(name: String, sortOrder: Int) { self.name = name; self.sortOrder = sortOrder }
    }

    @Model final class LibraryState {
        var initializedAt: Date = Date()
        init() {}
    }

    @Model final class TaskEventLink {
        var id: UUID = UUID()
        var eventIdentifier: String = ""
        var externalIdentifier: String?
        // Последние известные данные нужны для понятной строки при недоступном календаре.
        var lastTitle: String = ""
        var lastStart: Date = Date()
        var task: PlannerTask?
        init(task: PlannerTask, event: CalendarEvent) {
            self.task = task; eventIdentifier = event.identifier
            externalIdentifier = event.externalIdentifier
            lastTitle = event.title; lastStart = event.start
        }
    }

    /// Пункты принадлежат задаче; порядок сохраняется независимо от отметки выполнения.
    @Model final class TaskChecklistItem {
        var id: UUID = UUID()
        var title: String = ""
        var isCompleted: Bool = false
        var sortOrder: Int = 0
        var task: PlannerTask?

        init(task: PlannerTask, title: String = "", sortOrder: Int) {
            self.task = task
            self.title = title
            self.sortOrder = sortOrder
        }
    }
}

typealias PlannerTask = PlannerSchemaV5.PlannerTask
typealias TaskFolder = PlannerSchemaV5.TaskFolder
typealias LibraryState = PlannerSchemaV5.LibraryState
typealias TaskEventLink = PlannerSchemaV5.TaskEventLink
typealias TaskChecklistItem = PlannerSchemaV5.TaskChecklistItem

extension PlannerTask {
    var orderedChecklistItems: [TaskChecklistItem] {
        (checklistItems ?? []).sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

enum PlannerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [PlannerSchemaV1.self, PlannerSchemaV2.self, PlannerSchemaV3.self, PlannerSchemaV4.self, PlannerSchemaV5.self, PlannerSchemaV6.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: PlannerSchemaV1.self, toVersion: PlannerSchemaV2.self),
         .lightweight(fromVersion: PlannerSchemaV2.self, toVersion: PlannerSchemaV3.self),
         .lightweight(fromVersion: PlannerSchemaV3.self, toVersion: PlannerSchemaV4.self),
         .custom(fromVersion: PlannerSchemaV4.self, toVersion: PlannerSchemaV5.self,
                 willMigrate: nil, didMigrate: { context in
                     // Своя папка важнее прежней отметки периода. Даты, идентификаторы и связи не меняем.
                     for task in try context.fetch(FetchDescriptor<PlannerSchemaV5.PlannerTask>()) {
                         if task.folder == nil, ["week", "month"].contains(task.planningKind ?? "") {
                             task.systemFolderKind = task.planningKind!
                         }
                     }
                     try context.save()
                 }),
         .lightweight(fromVersion: PlannerSchemaV5.self, toVersion: PlannerSchemaV6.self)]
    }
}
