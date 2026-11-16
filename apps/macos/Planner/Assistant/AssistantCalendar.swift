import Foundation

/// Модель возвращает намерение. Поиск, выбор календаря и запись выполняются локально.
struct AssistantCalendarRequest: Codable, Sendable {
    enum Operation: String, Codable, Sendable { case create, agenda, move }
    let operation: Operation
    var title: String?
    var fromDate: String?
    var throughDate: String?
    var date: String?
    var time: String?
    var endDate: String?
    var endTime: String?
    var durationMinutes: Int?
    var allDay: Bool?
    var calendarName: String?
    var notes: String?
    var reminderMinutes: Int?
    var noReminder: Bool?
    var linkCurrentTask: Bool?
    var continueCurrent: Bool?
}

struct AssistantCalendarItem: Codable, Identifiable, Sendable {
    let identifier: String
    let calendarID: String
    let calendarName: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool

    init(_ event: CalendarEvent, calendarName: String) {
        identifier = event.identifier; calendarID = event.calendarID; self.calendarName = calendarName
        title = event.title; start = event.start; end = event.end; allDay = event.allDay
    }

    var id: String { identifier + ":" + String(start.timeIntervalSince1970) }

    func matches(_ event: CalendarEvent) -> Bool {
        id == event.id && calendarID == event.calendarID && end == event.end && allDay == event.allDay && title == event.title
    }
}

struct AssistantCalendarSelection: Codable, Sendable {
    let request: AssistantCalendarRequest
    let candidates: [AssistantCalendarItem]
    let context: AssistantContext
}

struct AssistantCalendarMove: Codable, Sendable {
    let source: AssistantCalendarItem
    let start: Date
    let end: Date
    let timeZoneID: String

    func editorEnd(calendar: Calendar) -> Date {
        guard source.allDay else { return end }
        return calendar.date(byAdding: .day, value: -1, to: end) ?? end
    }

    func draft(for latest: CalendarEvent) throws -> EventDraft {
        guard source.matches(latest) else {
            throw AssistantFailure(message: "Событие изменилось. Найдите его снова перед переносом.")
        }
        if let reason = latest.readOnlyReason { throw AssistantFailure(message: reason) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        var draft = EventDraft(event: latest, calendar: calendar)
        draft.timeZoneID = timeZoneID
        draft.start = start
        draft.end = editorEnd(calendar: calendar)
        return draft
    }
}

extension AssistantService {
    static func calendarReply(_ request: AssistantCalendarRequest, to original: AssistantThread,
                              context: AssistantContext, calendar: CalendarService, visibleIDs: Set<String>?,
                              usage: AssistantCloudUsage?) -> AssistantThread {
        var thread = original
        var message = AssistantMessage(role: .assistant, text: "", cloudUsage: usage, calendarTimeZoneID: context.timeZoneID)
        do {
            switch request.operation {
            case .create:
                try proposeEvent(request, context: context, thread: &thread, message: &message)
            case .agenda:
                guard request.fromDate != nil else {
                    message.questions = [.init(text: "На какую дату показать расписание?", options: [])]
                    break
                }
                let events = try calendar.load(calendarRange(request, context: context), visibleIDs: visibleIDs)
                message.calendarAgenda = events.prefix(20).map { calendarItem($0, calendar: calendar) }
                message.text = events.count > 20 ? "Показаны первые 20 событий." :
                    (events.isEmpty ? "В этот период событий нет." : "События за выбранный период")
            case .move:
                guard request.date != nil || request.time != nil else {
                    message.questions = [.init(text: "На какую дату или время перенести событие?", options: [])]
                    break
                }
                if request.continueCurrent == true, let previous = thread.focusedEvent?.calendarMove {
                    guard let event = calendar.resolve(identifier: previous.source.identifier, externalIdentifier: nil),
                          previous.source.matches(event) else {
                        throw AssistantFailure(message: "Событие изменилось. Найдите его снова перед переносом.")
                    }
                    try proposeMove(request, event: event, context: context, calendar: calendar, thread: &thread, message: &message)
                } else {
                    let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard title?.isEmpty == false || request.fromDate != nil else {
                        message.questions = [.init(text: "Какое событие перенести? Укажите название или исходную дату.", options: [])]
                        break
                    }
                    let events = try calendar.load(calendarRange(request, context: context), visibleIDs: visibleIDs)
                    let matches = matchingEvents(events, title: title)
                    if matches.count == 1, let event = matches.first {
                        try proposeMove(request, event: event, context: context, calendar: calendar, thread: &thread, message: &message)
                    } else if matches.isEmpty {
                        message.text = "Событие не найдено. Уточните название или исходную дату."
                    } else if matches.count > 12 {
                        message.text = "Найдено слишком много событий. Уточните исходную дату или название."
                    } else {
                        let items = matches.map { calendarItem($0, calendar: calendar) }
                        message.calendarSelection = .init(request: request, candidates: items, context: context)
                        let options = items.enumerated().map { index, item in
                            "\(index + 1). \(item.title) · \(item.start.formatted(date: .abbreviated, time: item.allDay ? .omitted : .shortened)) · \(item.calendarName)"
                        }
                        message.questions = [.init(text: "Какое из событий перенести?", options: options)]
                    }
                }
            }
        } catch {
            message.text = error.localizedDescription
            if calendar.access != .full { message.calendarAccessRequired = true }
        }
        thread.messages.append(message)
        return thread
    }

    func handleCalendarChoice(_ text: String, calendar: CalendarService) -> Bool {
        guard lastCloudMessageIsCurrent, let index = currentIndex, var thread = current,
              let previous = thread.messages.last, let question = previous.questions.first,
              !question.options.isEmpty else { return false }
        let options = question.options
        let matching = options.indices.filter { AssistantIntentPolicy.folded(options[$0]) == AssistantIntentPolicy.folded(text) }
        guard let option = Int(text).flatMap({ $0 > 0 && $0 <= options.count ? $0 - 1 : nil })
                ?? (matching.count == 1 ? matching.first : nil) else { return false }

        guard let selection = previous.calendarSelection else {
            return chooseCreationCalendar(options[option], thread: &thread, at: index, calendar: calendar, previous: previous)
        }
        guard selection.candidates.indices.contains(option) else { return false }
        var message = AssistantMessage(role: .assistant, text: "", calendarTimeZoneID: selection.context.timeZoneID)
        do {
            let item = selection.candidates[option]
            guard calendar.access == .full else { throw AssistantFailure(message: "Нет доступа к календарям.") }
            guard let event = calendar.resolve(identifier: item.identifier, externalIdentifier: nil),
                  item.matches(event) else {
                throw AssistantFailure(message: "Событие изменилось. Найдите его снова перед переносом.")
            }
            try Self.proposeMove(selection.request, event: event, context: selection.context, calendar: calendar,
                                 thread: &thread, message: &message)
        } catch {
            message.text = error.localizedDescription
            if calendar.access != .full { message.calendarAccessRequired = true }
        }
        // В историю облачного запроса попадёт только номер, без названия из календаря.
        recordLocalReply(String(option + 1), reply: message, thread: thread, at: index)
        return true
    }

    private func chooseCreationCalendar(_ name: String, thread: inout AssistantThread, at index: Int,
                                        calendar: CalendarService, previous: AssistantMessage) -> Bool {
        guard previous.calendarTimeZoneID != nil, previous.questions.first?.text == "В какой календарь добавить событие?",
              let action = thread.focusedEvent, action.id == previous.resultActionID else { return false }
        let matches = calendar.calendars.filter { $0.writable && AssistantIntentPolicy.folded($0.title) == AssistantIntentPolicy.folded(name) }
        guard matches.count == 1, let destination = matches.first else { return false }
        var updated = action
        updated.proposal.calendarID = destination.id
        var message = AssistantMessage(role: .assistant, text: "Проверьте событие перед созданием.",
                                       calendarTimeZoneID: action.context.timeZoneID)
        Self.putEvent(updated, in: &thread, message: &message)
        recordLocalReply(name, reply: message, thread: thread, at: index)
        return true
    }

    private static func calendarItem(_ event: CalendarEvent, calendar: CalendarService) -> AssistantCalendarItem {
        .init(event, calendarName: calendar.calendars.first { $0.id == event.calendarID }?.title ?? "")
    }

    static func calendarRange(_ request: AssistantCalendarRequest, context: AssistantContext) throws -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(identifier: context.timeZoneID) else { throw AssistantFailure(message: "Проверьте дату и время.") }
        calendar.timeZone = zone
        let first = try request.fromDate.map { try ActionPlanValidator.date($0, time: nil, zone: zone.identifier) }
            ?? calendar.startOfDay(for: context.now)
        let last = try request.throughDate.map { try ActionPlanValidator.date($0, time: nil, zone: zone.identifier) } ?? first
        let dayCount = request.fromDate == nil && request.operation == .move && request.throughDate == nil ? 30 : 1
        guard let end = calendar.date(byAdding: .day, value: dayCount, to: last), end > first,
              let days = calendar.dateComponents([.day], from: first, to: end).day, days <= 31 else {
            throw AssistantFailure(message: "Укажите период до 31 дня.")
        }
        return DateInterval(start: first, end: end)
    }

    static func matchingEvents(_ events: [CalendarEvent], title: String?) -> [CalendarEvent] {
        guard let title, !title.isEmpty else { return events }
        let query = AssistantIntentPolicy.folded(title)
        let exact = events.filter { AssistantIntentPolicy.folded($0.title) == query }
        return exact.isEmpty ? events.filter { AssistantIntentPolicy.folded($0.title).contains(query) } : exact
    }

    private static func putEvent(_ action: AssistantAction, in thread: inout AssistantThread, message: inout AssistantMessage) {
        if let index = thread.actions.firstIndex(where: { $0.id == action.id }) { thread.actions[index] = action }
        else { thread.actions.append(action) }
        thread.cloud?.draftIDs?.insert(action.id)
        thread.focusedEventID = action.id
        thread.focusedDraftID = nil
        thread.activeTextEditID = nil
        message.resultActionID = action.id
    }

    private static func proposeEvent(_ request: AssistantCalendarRequest, context: AssistantContext,
                                     thread: inout AssistantThread, message: inout AssistantMessage) throws {
        let previous = request.continueCurrent == true ? thread.focusedEvent.flatMap {
            $0.calendarMove == nil && $0.createdEventID == nil ? $0 : nil
        } : nil
        let savedContext = previous?.context
        var actionContext = context
        if let savedContext { actionContext.timeZoneID = savedContext.timeZoneID }
        var p = previous?.proposal ?? AssistantProposal(key: UUID().uuidString, kind: .event, title: "")
        if request.linkCurrentTask == true {
            guard let id = context.taskID else {
                message.text = "Выберите задачу и включите «Использовать задачу»."
                return
            }
            p.linkTo = id
        } else if request.linkCurrentTask == false { p.linkTo = nil }
        if request.linkCurrentTask != true, p.linkTo == savedContext?.taskID, p.linkTo != nil {
            actionContext.taskID = savedContext?.taskID
            actionContext.taskTitle = savedContext?.taskTitle
        }
        p.title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? previous?.proposal.title ?? (p.linkTo == nil ? "" : actionContext.taskTitle ?? "")
        if p.title.isEmpty {
            message.questions = [.init(text: "Как назвать событие?", options: [])]
            return
        }
        p.date = request.date ?? p.date
        p.description = request.notes ?? p.description
        if let name = request.calendarName {
            let matches = context.calendars.filter { AssistantIntentPolicy.folded($0.name) == AssistantIntentPolicy.folded(name) }
            p.calendarID = matches.count == 1 ? matches.first?.id : nil
        } else if previous == nil { p.calendarID = context.defaultCalendarID }
        if request.noReminder == true { p.reminderMinutes = nil }
        else if let offset = request.reminderMinutes { p.reminderMinutes = offset }
        else if previous == nil { p.reminderMinutes = context.reminderMinutes }

        if request.allDay == true {
            p.allDay = true
            p.time = nil
            p.endTime = nil
            p.endDate = request.endDate ?? (request.date == nil ? p.endDate : nil)
            p.durationMinutes = nil
        } else {
            if request.allDay == false { p.allDay = false }
            if let time = request.time { p.time = time; p.allDay = false }
            if let duration = request.durationMinutes {
                p.durationMinutes = duration
                p.endTime = nil
                p.endDate = nil
            } else if let endTime = request.endTime {
                p.endTime = endTime
                p.endDate = request.endDate ?? p.date
                if request.endDate == nil, let time = p.time, endTime < time,
                   let start = try? ActionPlanValidator.date(p.date, time: time, zone: actionContext.timeZoneID),
                   let zone = TimeZone(identifier: actionContext.timeZoneID) {
                    var local = Calendar(identifier: .gregorian)
                    local.timeZone = zone
                    if let next = local.date(byAdding: .day, value: 1, to: start) {
                        p.endDate = LocalDay.key(for: next, calendar: local)
                    }
                }
            } else if (request.date != nil || request.time != nil), let previous,
                      previous.proposal.endTime != nil, let old = try? ActionPlanValidator.eventDraft(previous) {
                p.durationMinutes = Int(old.end.timeIntervalSince(old.start) / 60)
                p.endTime = nil
                p.endDate = nil
            }
        }
        var action = previous ?? AssistantAction(proposal: p, context: actionContext)
        action.proposal = p; action.context = actionContext; action.error = nil; action.status = .pending
        putEvent(action, in: &thread, message: &message)
        if p.date == nil { message.questions = [.init(text: "На какую дату запланировать событие?", options: [])] }
        else if p.allDay != true && p.time == nil { message.questions = [.init(text: "Во сколько запланировать событие?", options: [])] }
        else if p.calendarID == nil && !context.calendars.isEmpty {
            message.questions = [.init(text: "В какой календарь добавить событие?", options: context.calendars.map(\.name))]
        } else { message.text = "Проверьте событие перед созданием." }
    }

    private static func proposeMove(_ request: AssistantCalendarRequest, event: CalendarEvent, context: AssistantContext,
                                    calendar service: CalendarService, thread: inout AssistantThread,
                                    message: inout AssistantMessage) throws {
        if let reason = event.readOnlyReason { throw AssistantFailure(message: reason) }
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(identifier: context.timeZoneID) else { throw AssistantFailure(message: "Проверьте дату и время.") }
        calendar.timeZone = zone
        let previous = request.continueCurrent == true ? thread.focusedEvent.flatMap {
            $0.calendarMove?.source.matches(event) == true ? $0 : nil
        } : nil
        let start = previous?.calendarMove?.start ?? event.start
        let day = request.date ?? LocalDay.key(for: start, calendar: calendar)
        let timeFormat = DateFormatter()
        timeFormat.calendar = calendar; timeFormat.timeZone = zone
        timeFormat.locale = Locale(identifier: "en_US_POSIX"); timeFormat.dateFormat = "HH:mm"
        if event.allDay && request.time != nil {
            throw AssistantFailure(message: "Для события на весь день укажите новую дату.")
        }
        let time = event.allDay ? nil : (request.time ?? timeFormat.string(from: start))
        let target = try ActionPlanValidator.date(day, time: time, zone: zone.identifier)
        guard target != event.start else {
            message.text = "У события уже указаны эта дата и время."
            return
        }
        var draft = EventDraft(event: event, calendar: calendar)
        draft.timeZoneID = zone.identifier
        if let move = previous?.calendarMove {
            draft.start = move.start
            draft.end = move.editorEnd(calendar: calendar)
        }
        draft.setStart(target, calendar: calendar)
        let interval = try draft.interval(calendar: calendar)
        let move = AssistantCalendarMove(source: calendarItem(event, calendar: service),
                                         start: interval.start, end: interval.end, timeZoneID: zone.identifier)
        let proposal = AssistantProposal(key: previous?.proposal.key ?? UUID().uuidString, kind: .event, title: event.title,
                                         date: day, time: time, allDay: event.allDay, calendarID: event.calendarID)
        var action = previous ?? AssistantAction(proposal: proposal, context: context)
        action.proposal = proposal; action.context = context; action.calendarMove = move; action.error = nil; action.status = .pending
        putEvent(action, in: &thread, message: &message)
        message.text = "Подтвердите перенос события."
    }
}
