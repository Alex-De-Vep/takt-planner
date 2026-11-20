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
    let localModel: ModelManager?
    let cloud = AssistantCloudConnection()
    let gateways: AssistantGatewayConnections
    var cloudPreview = ""
    @ObservationIgnored private let store: AssistantStore
    @ObservationIgnored private var unsavedDrafts: [UUID: AssistantStore.Draft] = [:]
    @ObservationIgnored var generation: Task<Void, Never>?
    var requestID = UUID()
    var currentIndex: Int? { archive.threads.firstIndex { $0.id == archive.currentID } }
    var current: AssistantThread? { currentIndex.map { archive.threads[$0] } }

    init(model: ModelManager? = nil, store: AssistantStore = AssistantStore(),
         gateways: AssistantGatewayConnections = AssistantGatewayConnections()) {
        self.gateways = gateways
        // Локальный движок доступен только при явной подстановке в тестах.
        self.localModel = model; self.store = store
        model?.cancelGeneration = { [weak self] in self?.stop() }
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
    func disableModel() async {
        guard let model = localModel else { return }
        stop()
        if let generation { await generation.value }
        await model.disable()
    }
    func send(_ text: String, context: AssistantContext, taskService: TaskService? = nil) {
        if current?.usesCloudModel == true { sendCloud(text, context: context, tasks: taskService); return }
        guard let model = localModel else { return }
        if let taskService, routeTextRequest(text, context: context, tasks: taskService) { return }
        guard current?.textEdits?.contains(where: { $0.target == .proposal && $0.status == .pending && $0.hasChanges }) != true else {
            error = "Сначала примите или отмените предложенные правки."; return
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 8000 else { error = "Сообщение слишком длинное. Сократите его до 8000 символов."; return }
        guard !text.isEmpty, !generating, !applying, !storageFailed,
              model.canChat, let i = currentIndex else { return }
        error = nil
        let previous = archive
        var context = context
        if archive.threads[i].messages.last?.questions.isEmpty == false,
           let previous = archive.threads[i].clarificationContext {
            context.now = previous.now; context.timeZoneID = previous.timeZoneID
        }
        archive.threads[i].clarificationContext = context
        archive.threads[i].draft = ""
        archive.threads[i].messages.append(AssistantMessage(role: .user, text: text))
        if archive.threads[i].messages.count == 1 { archive.threads[i].title = String(text.prefix(60)) }
        guard persist() else { archive = previous; return }
        var snapshot = archive.threads[i]
        let protectedIDs = snapshot.protectedLocalActionIDs ?? []
        let protected = snapshot.actions.filter { protectedIDs.contains($0.id) }
        snapshot.actions.removeAll { protectedIDs.contains($0.id) }
        let token = UUID(); requestID = token; generating = true
        generation = Task { [weak self] in
            guard let self else { return }
            var acquired = false
            do {
                try await model.beginUse()
                acquired = true
                let input = try AssistantPrompt.request(context: context, thread: snapshot)
                let output = try await model.backend.respond(instructions: AssistantPrompt.instructions, prompt: input)
                try Task.checkCancellation()
                let response = AssistantResponsePolicy.normalize(try ActionPlanValidator.decode(output), thread: snapshot, context: context)
                guard token == requestID, let index = archive.threads.firstIndex(where: { $0.id == snapshot.id }) else { throw CancellationError() }
                let completed = snapshot.actions.filter { $0.status == .created || $0.createdEventID != nil || $0.status == .needsReview }
                let incoming = response.actions ?? []
                guard !incoming.contains(where: { p in completed.contains { $0.proposal.key == p.key && $0.status != .created } }) else {
                    throw AssistantFailure(message: "Сначала завершите сохранение связи или проверьте результат предыдущей операции.")
                }
                // Ключ модели не является UUID операции. Новый запрос после применения может снова вернуть task1.
                // Разводим такие ключи, сохраняя ссылки внутри нового плана и готовые результаты в истории.
                let occupied = Set((completed + protected).map { $0.proposal.key })
                var remapped: [String: String] = [:]
                for p in incoming where occupied.contains(p.key) { remapped[p.key] = p.key + "-" + UUID().uuidString }
                let proposed = incoming.map { original -> AssistantAction in
                    var p = original
                    p.key = remapped[p.key] ?? p.key
                    if let link = p.linkTo { p.linkTo = remapped[link] ?? link }
                    // Уточнение сохраняет UUID и часовой пояс исходной карточки.
                    if var old = snapshot.actions.first(where: { $0.proposal.key == p.key && $0.proposal.kind == p.kind && $0.status != .created }) {
                        old.proposal = p; old.error = nil; old.status = .pending; return old
                    }
                    return AssistantAction(proposal: p, context: context)
                }
                archive.threads[index].actions = protected + completed + proposed
                archive.threads[index].messages.append(AssistantMessage(role: .assistant, text: response.message, questions: response.questions ?? []))
                persist()
            } catch {
                if token == requestID, !Task.isCancelled, !(error is CancellationError) { self.error = error is DecodingError ? "Не удалось проверить ответ модели. Упростите запрос и повторите." : error.localizedDescription }
            }
            if acquired { await model.endUse() }
            if token == requestID { generating = false; generation = nil }
        }
    }
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
