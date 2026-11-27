import Foundation

/// Единственный переключатель исключает одновременное открытие чата и календаря.
enum RightPanel: String, Codable { case calendar, assistant }

enum AssistantPaths {
    static var root: URL {
        #if SHOWCASE
        return FileManager.default.temporaryDirectory.appending(path: "PlannerAIPreview-Showcase/Assistant", directoryHint: .isDirectory)
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Planner/Assistant", directoryHint: .isDirectory)
        #endif
    }
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
    var textEdit: AssistantTextChange? = nil
    var calendarRequest: AssistantCalendarRequest? = nil
    var noteEdit: String? = nil
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
    var calendarMove: AssistantCalendarMove? = nil

    var isEditable: Bool {
        [.pending, .failed].contains(status) && createdTaskID == nil && createdEventID == nil
    }
}
struct AssistantMessage: Codable, Identifiable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
    var questions: [AssistantQuestion] = []
    var createdAt = Date()
    var cloudUsage: AssistantCloudUsage? = nil
    var resultActionID: UUID? = nil
    var resultEditID: UUID? = nil
    var resultNoteProposalID: UUID? = nil
    var taskLookup: AssistantTaskLookup? = nil
    var calendarAgenda: [AssistantCalendarItem]? = nil
    var calendarSelection: AssistantCalendarSelection? = nil
    var calendarAccessRequired: Bool? = nil
    var calendarTimeZoneID: String? = nil
}
struct AssistantTaskLookup: Codable {
    let request: String
    let taskIDs: [UUID]
}

struct AssistantThread: Codable, Identifiable {
    var id = UUID()
    var title = "Новый разговор"
    var draft = ""
    var clarificationContext: AssistantContext?
    var messages: [AssistantMessage] = []
    var actions: [AssistantAction] = []
    var createdAt = Date()
    var textEdits: [AssistantTextEdit]? = nil
    var attachedNoteID: UUID? = nil
    var noteProposal: AssistantNoteProposal? = nil
    var activeTextEditID: UUID? = nil
    var focusedDraftID: UUID? = nil
    var focusedEventID: UUID? = nil
    var cloud: AssistantCloudThread? = nil

    var visibleActions: [AssistantAction] { actions.filter { $0.status != .created } }
    var numberedTaskDrafts: [AssistantAction] { actions.filter { $0.proposal.kind == .task } }

    var focusedDraft: AssistantAction? {
        numberedTaskDrafts.first { $0.id == focusedDraftID && [.pending, .failed].contains($0.status) }
    }

    var focusedEvent: AssistantAction? {
        actions.first { $0.id == focusedEventID && $0.proposal.kind == .event && [.pending, .failed].contains($0.status) }
    }

    func taskDraftNumber(_ id: UUID) -> Int? {
        numberedTaskDrafts.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    var usesCloudModel: Bool { cloud != nil }

    mutating func chooseModel(id: String, efforts: [String] = [], accountID: String? = nil,
                              gateway: AssistantGateway? = nil, profileID: UUID? = nil) {
        let switchingProvider = cloud == nil || cloud?.gateway != gateway || cloud?.gatewayProfileID != profileID
            || (gateway == nil && accountID != nil && cloud?.accountID != nil && cloud?.accountID != accountID)
        var settings = cloud ?? AssistantCloudThread()
        if switchingProvider {
            if cloud != nil { attachedNoteID = nil }
            activeTextEditID = nil
            focusedDraftID = nil
            focusedEventID = nil
            clarificationContext = nil
            settings.historyStart = messages.count
            settings.draftIDs = []
            settings.effort = nil
        }
        settings.modelID = id
        settings.accountID = gateway == nil ? (accountID ?? (settings.gateway == nil ? settings.accountID : nil)) : nil
        settings.gateway = gateway
        settings.gatewayProfileID = profileID
        if let effort = settings.effort, !efforts.contains(effort) { settings.effort = nil }
        cloud = settings
    }
}
struct AssistantArchive: Codable {
    var version = 2
    var currentID: UUID?
    var threads: [AssistantThread] = []
}
extension AssistantArchive {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        currentID = try values.decodeIfPresent(UUID.self, forKey: .currentID)
        var records = try values.nestedUnkeyedContainer(forKey: .threads)
        // Older archives kept the previous provider even after switching to on-device inference.
        // A new provider choice must start its own history segment.
        enum LegacyKey: String, CodingKey { case localModelSelected }
        while !records.isAtEnd {
            let record = try records.superDecoder()
            var thread = try AssistantThread(from: record)
            let legacy = try record.container(keyedBy: LegacyKey.self)
            if try legacy.decodeIfPresent(Bool.self, forKey: .localModelSelected) == true {
                thread.cloud = nil
            }
            threads.append(thread)
        }
    }
}
struct AssistantFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
