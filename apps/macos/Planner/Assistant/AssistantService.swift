import Foundation
import Observation
import SwiftData

/// Одна очередь выполнения на приложение: двойное нажатие и второе окно не дублируют операции.
@MainActor @Observable
final class AssistantService {
    var archive = AssistantArchive()
    var generating = false
    var applying = false
    var error: String?
    var storageFailed = false
    let cloud = AssistantCloudConnection()
    let gateways: AssistantGatewayConnections
    let replyPreview = AssistantReplyPreview()
    @ObservationIgnored private let store: AssistantStore
    @ObservationIgnored private var unsavedDrafts: [UUID: AssistantStore.Draft] = [:]
    @ObservationIgnored var generation: Task<Void, Never>?
    var requestID = UUID()
    var currentIndex: Int? { archive.threads.firstIndex { $0.id == archive.currentID } }
    var current: AssistantThread? { currentIndex.map { archive.threads[$0] } }

    init(store: AssistantStore = AssistantStore(),
         gateways: AssistantGatewayConnections = AssistantGatewayConnections()) {
        self.gateways = gateways
        self.store = store
        do {
            archive = try store.load()
            // После аварии task UUID позволяет восстановление. Неизвестный результат EventKit требует проверки.
            for t in archive.threads.indices {
                for a in archive.threads[t].actions.indices where archive.threads[t].actions[a].status == .applying {
                    let action = archive.threads[t].actions[a]
                    archive.threads[t].actions[a].status = action.proposal.kind == .event && action.createdEventID == nil ? .needsReview : .failed
                }
            }
            for t in archive.threads.indices {
                for e in (archive.threads[t].textEdits ?? []).indices where archive.threads[t].textEdits?[e].status == .applying {
                    archive.threads[t].textEdits?[e].status = .pending
                }
            }
            if currentIndex == nil { newConversation() }
        } catch { self.error = error.localizedDescription; storageFailed = true }
    }
    @discardableResult func persist() -> Bool {
        guard !storageFailed, flushDrafts() else { return false }
        do { try store.save(archive); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func newConversation() {
        guard !generating, !applying, !storageFailed else { return }
        error = nil
        let previous = archive
        let thread = emptyConversation()
        archive.threads.insert(thread, at: 0)
        archive.currentID = thread.id
        if !persist() { archive = previous }
    }
    func selectConversation(_ id: UUID) { guard !generating, !applying else { return }; error = nil; archive.currentID = id; persist() }
    func draft(for id: UUID) -> String { archive.threads.first { $0.id == id }?.draft ?? "" }

    func setDraft(_ text: String, for id: UUID? = nil) {
        guard let id = id ?? archive.currentID,
              let i = archive.threads.firstIndex(where: { $0.id == id }) else { return }
        if archive.threads[i].draft != text {
            archive.threads[i].draft = text
            let thread = archive.threads[i]
            unsavedDrafts[thread.id] = AssistantStore.Draft(thread)
        }
        saveDraft(for: id)
    }

    @discardableResult
    private func saveDraft(for id: UUID) -> Bool {
        guard let draft = unsavedDrafts[id] else { return true }
        do {
            try store.saveDraft(draft, for: id)
            unsavedDrafts[id] = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func flushDrafts() -> Bool {
        var saved = true
        for id in Array(unsavedDrafts.keys) {
            if !saveDraft(for: id) { saved = false }
        }
        return saved
    }
    func clearHistory() {
        guard !generating, !applying else { return }
        let thread = emptyConversation()
        let previous = archive
        archive = AssistantArchive(currentID: thread.id, threads: [thread])
        storageFailed = false
        if persist() {
            for thread in previous.threads { store.discardDraft(for: thread.id) }
            error = nil
        }
        else { archive = previous; storageFailed = true }
    }
    private func emptyConversation() -> AssistantThread {
        var thread = AssistantThread()
        if let current, current.usesCloudModel, let selected = current.cloud {
            // Новый разговор наследует настройки модели и начинает собственную историю.
            thread.cloud = AssistantCloudThread(accountID: selected.accountID, modelID: selected.modelID,
                                                effort: selected.effort, historyStart: 0, draftIDs: [],
                                                gateway: selected.gateway, gatewayProfileID: selected.gatewayProfileID)
        }
        return thread
    }
    // Следующий запрос ждёт фактического завершения отмены, чтобы не запускать две генерации.
    func stop() { generation?.cancel() }
    @discardableResult func updateAction(_ updated: AssistantAction) -> Bool {
        guard !applying, !generating, !storageFailed, updated.isEditable, let i = currentIndex,
              let a = archive.threads[i].actions.firstIndex(where: { $0.id == updated.id && $0.isEditable }) else { return false }
        let previous = archive.threads[i].actions[a]
        error = nil
        archive.threads[i].actions[a] = updated
        if persist() { return true }
        archive.threads[i].actions[a] = previous
        return false
    }
    func problems(_ action: AssistantAction, folders: [AssistantFolder], calendars: [AssistantCalendar]) -> [String] {
        if let move = action.calendarMove {
            return calendars.contains { $0.id == move.source.calendarID } ? [] : ["Нет доступного календаря для переноса события."]
        }
        var issues = ActionPlanValidator.problems(action, folders: folders, calendars: calendars)
        if action.proposal.kind == .event, let link = action.proposal.linkTo, link != action.context.taskID {
            let source = current?.actions.first { $0.proposal.key == link && $0.proposal.kind == .task }
            if let source {
                if source.status != .created && (!source.included || !ActionPlanValidator.problems(source, folders: folders, calendars: calendars).isEmpty) {
                    issues.append("Сначала включите и заполните связанную задачу.")
                }
            } else { issues.append("Связанная задача недоступна. Создайте её или исправьте предложение.") }
        }
        return issues
    }
    func readyCount(folders: [AssistantFolder], calendars: [AssistantCalendar], actionID: UUID? = nil,
                    kind: AssistantProposal.Kind? = nil) -> Int {
        current?.actions.filter { (actionID == nil || $0.id == actionID) && (kind == nil || $0.proposal.kind == kind) && $0.included && [.pending, .failed].contains($0.status) && problems($0, folders: folders, calendars: calendars).isEmpty && !hasUnreviewedText(for: $0.id) }.count ?? 0
    }
    func apply(taskService: TaskService, calendar: CalendarService, folders: [TaskFolder], actionID: UUID? = nil,
               kind: AssistantProposal.Kind? = nil) async {
        guard !applying, !generating, let t = currentIndex, !storageFailed else { return }
        applying = true; error = nil; defer { applying = false }
        let folderSnapshots = Self.folders(folders, preferences: nil)
        let calendars = calendar.calendars.filter(\.writable).map { AssistantCalendar(id: $0.id, name: $0.title) }
        // Новые задачи сохраняются раньше связанных событий, независимо от порядка ответа модели.
        let indices = archive.threads[t].actions.indices.sorted {
            archive.threads[t].actions[$0].proposal.kind == .task && archive.threads[t].actions[$1].proposal.kind == .event
        }
        for a in indices {
            var action = archive.threads[t].actions[a]
            guard actionID == nil || action.id == actionID, kind == nil || action.proposal.kind == kind, action.included, [.pending, .failed].contains(action.status), !hasUnreviewedText(for: action.id) else { continue }
            let problems = problems(action, folders: folderSnapshots, calendars: calendars)
            guard problems.isEmpty else { archive.threads[t].actions[a].error = problems.joined(separator: "\n"); continue }
            action.status = .applying; action.error = nil; archive.threads[t].actions[a] = action
            guard persist() else { archive.threads[t].actions[a].status = .failed; return }
            await Task.yield()
            do {
                if action.proposal.kind == .task {
                    let task = try taskService.createAssistantTask(action, folders: folders)
                    action.createdTaskID = task.id
                } else if let move = action.calendarMove {
                    guard let latest = calendar.resolve(identifier: move.source.identifier, externalIdentifier: nil) else {
                        throw AssistantFailure(message: "Событие изменилось. Найдите его снова перед переносом.")
                    }
                    let saved = try calendar.save(move.draft(for: latest), original: latest)
                    action.createdEventID = saved.identifier
                    action.createdEventExternalID = saved.externalIdentifier
                } else {
                    let linkedTask: PlannerTask?
                    if let link = action.proposal.linkTo {
                        let taskID: UUID?
                        if link == action.context.taskID { taskID = UUID(uuidString: link) }
                        else { taskID = archive.threads[t].actions.first(where: { $0.proposal.key == link && $0.proposal.kind == .task && $0.status == .created })?.createdTaskID }
                        guard let taskID, let task = try taskService.assistantTask(id: taskID) else {
                            throw AssistantFailure(message: "Связанная задача недоступна. Создайте её или исправьте предложение.")
                        }
                        linkedTask = task
                    } else { linkedTask = nil }
                    let event: CalendarEvent
                    if let identifier = action.createdEventID {
                        guard let existing = calendar.resolve(identifier: identifier, externalIdentifier: action.createdEventExternalID) else {
                            throw AssistantFailure(message: "Созданное событие недоступно. Повторное событие не создаётся.")
                        }
                        event = existing
                    } else {
                        event = try calendar.save(ActionPlanValidator.eventDraft(action), original: nil)
                        action.createdEventID = event.identifier; action.createdEventExternalID = event.externalIdentifier
                        archive.threads[t].actions[a] = action
                        // При ошибке журнала сохраняем известный ID в памяти и запрещаем новые записи.
                        guard persist() else { archive.threads[t].actions[a].status = .needsReview; storageFailed = true; return }
                    }
                    if let linkedTask, !action.linked {
                        if !(linkedTask.eventLinks ?? []).contains(where: { $0.eventIdentifier == event.identifier }) {
                            guard taskService.link(event, to: linkedTask) else { throw AssistantFailure(message: "Событие создано, но связь не сохранена. Повторите сохранение связи.") }
                        }
                        action.linked = true
                    }
                }
                action.status = .created
            } catch { action.status = .failed; action.error = error.localizedDescription }
            archive.threads[t].actions[a] = action
            guard persist() else { return }
        }
        persist()
    }
    static func folders(_ folders: [TaskFolder], preferences: AppPreferences?) -> [AssistantFolder] {
        // Переводим только системные подписи; пользовательские названия сохраняем буквально.
        let system = [("inbox", "Входящие"), ("week", "На неделе"), ("month", "Месяц")].map { id, name in
            AssistantFolder(id: id, name: preferences?.translations[name] ?? name)
        }
        return system + folders.filter { !$0.isDeleted }.map { AssistantFolder(id: $0.id.uuidString, name: $0.name) }
    }
}

/// Render the first delta immediately, then present arriving text in batches.
@MainActor @Observable
final class AssistantReplyPreview {
    private(set) var text = ""
    @ObservationIgnored private var pending = ""
    @ObservationIgnored private var nextUpdate = ContinuousClock.now
    @ObservationIgnored private var scheduled: Task<Void, Never>?

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        pending += delta
        guard scheduled == nil else { return }
        if ContinuousClock.now >= nextUpdate {
            publish()
        } else {
            let deadline = nextUpdate
            scheduled = Task { [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                guard !Task.isCancelled else { return }
                self?.publish()
            }
        }
    }

    private func publish() {
        text += pending
        pending = ""
        nextUpdate = .now + .milliseconds(100)
        scheduled = nil
    }

    func reset() {
        scheduled?.cancel()
        scheduled = nil
        pending = ""
        text = ""
        nextUpdate = .now
    }
}
