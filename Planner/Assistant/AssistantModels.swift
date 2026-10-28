import Foundation

/// Единственный переключатель исключает одновременное открытие чата и календаря.
enum RightPanel: String, Codable { case calendar, assistant }

enum AssistantPaths {
    static var root: URL {
        #if SHOWCASE
        return FileManager.default.temporaryDirectory.appending(path: "PlannerAIPreview-Showcase/Assistant", directoryHint: .isDirectory)
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "PlannerAIPreview/Assistant", directoryHint: .isDirectory)
        #endif
    }
    static var model: URL { root.appending(path: "Models/" + ((try? ModelManifest.bundled().id.components(separatedBy: "/").last) ?? "Qwen3.5-2B-4bit"), directoryHint: .isDirectory) }
}
struct AssistantFolder: Codable, Sendable, Identifiable { let id: String; let name: String }
struct AssistantCalendar: Codable, Sendable, Identifiable { let id: String; let name: String }

/// Снимок при отправке: переключение окна не меняет уже подготовленное предложение.
struct AssistantContext: Codable, Sendable {
    var now: Date
    var timeZoneID: String
    var language: String
    var folders: [AssistantFolder]
    var calendars: [AssistantCalendar]
    var defaultFolderID: String
    var defaultCalendarID: String?
    var taskID: String?
    var taskTitle: String?
    var durationMinutes: Int
    var reminderMinutes: Int?
}
struct AssistantQuestion: Codable, Sendable, Identifiable {
    var text: String
    var options: [String]
    var id: String { text }
}

/// Только разрешённые поля. Неизвестный вид действия отклоняется декодером.
struct AssistantProposal: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case task, event }
    var key: String
    var kind: Kind
    var title: String
    var folderID: String?
    var description: String?
    var checklist: [String]?
    var date: String?
    var time: String?
    var endDate: String?
    var endTime: String?
    var durationMinutes: Int?
    var allDay: Bool?
    var today: Bool?
    var calendarID: String?
    var reminderMinutes: Int?
    // UUID выбранной задачи или key новой задачи из того же предложения.
    var linkTo: String?
}
struct AssistantResponse: Codable, Sendable {
    var message: String
    var questions: [AssistantQuestion]?
    var actions: [AssistantProposal]?
}
enum AssistantActionStatus: String, Codable { case pending, applying, created, failed, needsReview }
struct AssistantAction: Codable, Identifiable {
    var id = UUID()
    var proposal: AssistantProposal
    var context: AssistantContext
    var included = true
    var status: AssistantActionStatus = .pending
    var error: String?
    var createdTaskID: UUID?
    var createdEventID: String?
    var createdEventExternalID: String?
    var linked = false
}
struct AssistantMessage: Codable, Identifiable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
    var questions: [AssistantQuestion] = []
    var createdAt = Date()
}
struct AssistantThread: Codable, Identifiable {
    var id = UUID()
    var title = "Новый разговор"
    var draft = ""
    var clarificationContext: AssistantContext?
    var messages: [AssistantMessage] = []
    var actions: [AssistantAction] = []
    var createdAt = Date()
}
struct AssistantArchive: Codable {
    var version = 1
    var currentID: UUID?
    var threads: [AssistantThread] = []
}
struct AssistantFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
