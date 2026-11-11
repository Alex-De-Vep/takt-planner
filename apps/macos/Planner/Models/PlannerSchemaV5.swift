import Foundation
import SwiftData
import PlannerLocalization

/// Основная папка отделена от старого планирования; схемы V1–V4 сохраняем неизменными.
enum PlannerSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(5, 0, 0) }
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
        // Основная системная папка используется, когда пользовательская связь folder пуста.
        var systemFolderKind: String = "inbox"
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
