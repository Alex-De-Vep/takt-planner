import SwiftUI

/// Редактор предложения не меняет библиотеку, пока пользователь не применит план в чате.
struct AssistantActionEditor: View {
    @Environment(\.translations) private var strings
    @State private var action: AssistantAction
    let folders: [AssistantFolder]
    let calendars: [AssistantCalendar]
    let actions: [AssistantAction]
    let save: (AssistantAction) -> String?
    let cancel: () -> Void
    @State private var hasDate: Bool
    @State private var includesTime: Bool
    @State private var checklist: String
    @State private var start: Date
    @State private var event: EventDraft
    @State private var hasReminder: Bool
    @State private var reminderMinutes: String
    @State private var error: String?

    init(action: AssistantAction, folders: [AssistantFolder], calendars: [AssistantCalendar], actions: [AssistantAction],
         save: @escaping (AssistantAction) -> String?, cancel: @escaping () -> Void) {
        self._action = State(initialValue: action)
        self.folders = folders
        self.calendars = calendars
        self.actions = actions
        self.save = save
        self.cancel = cancel

        let proposal = action.proposal
        let calendar = Self.calendar(for: action.context.timeZoneID)
        let initial = (try? ActionPlanValidator.date(proposal.date, time: proposal.time, zone: action.context.timeZoneID)) ?? .now
        let validatedEvent = proposal.kind == .event ? try? ActionPlanValidator.eventDraft(action) : nil
        var event = validatedEvent ?? EventDraft(day: initial, calendarID: proposal.calendarID ?? "", calendar: calendar)
        if let move = action.calendarMove {
            event.start = move.start
            event.end = move.editorEnd(calendar: calendar)
            event.allDay = move.source.allDay
        } else if proposal.kind == .event, validatedEvent == nil {
            // Keep usable dates even when the proposal still needs a time or another correction.
            if let day = try? ActionPlanValidator.date(proposal.date, time: nil, zone: action.context.timeZoneID) {
                event.start = proposal.time == nil ? event.start : initial
                if proposal.allDay == true { event.start = day }
            }
            event.allDay = proposal.allDay == true
            event.end = (try? ActionPlanValidator.date(proposal.endDate ?? proposal.date, time: event.allDay ? nil : proposal.endTime, zone: action.context.timeZoneID))
                .flatMap { event.allDay || proposal.endTime != nil ? $0 : nil }
                ?? (event.allDay ? event.start : event.start.addingTimeInterval(TimeInterval(proposal.durationMinutes ?? action.context.durationMinutes) * 60))
        }

        _event = State(initialValue: event)
        _start = State(initialValue: initial)
        _hasDate = State(initialValue: proposal.date != nil)
        _includesTime = State(initialValue: proposal.time != nil)
        _checklist = State(initialValue: (proposal.checklist ?? []).joined(separator: "\n"))
        _hasReminder = State(initialValue: proposal.reminderMinutes != nil)
        _reminderMinutes = State(initialValue: String(proposal.reminderMinutes ?? 15))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(strings["Изменить предложение"]).font(.headline)
            Form {
                if action.calendarMove != nil {
                    Text(action.proposal.title).fontWeight(.semibold)
                    eventDates
                } else {
                    TextField(strings["Название"], text: $action.proposal.title)
                    if action.proposal.kind == .event { eventFields }
                    else { taskFields }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(strings["Описание"]).font(.caption.weight(.semibold))
                        TextEditor(text: Binding(get: { action.proposal.description ?? "" }, set: { action.proposal.description = $0 }))
                            .frame(height: 80)
                            .accessibilityLabel(strings["Описание"])
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: action.calendarMove != nil ? 170 : 410)
            if let error { Text(strings[error]).font(.callout).foregroundStyle(.red) }
            HStack {
                Button(strings["Отмена"], action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(strings["Сохранить предложение"], action: commit).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 470)
        .environment(\.timeZone, calendar.timeZone)
        .environment(\.calendar, calendar)
    }

    private var calendar: Calendar { Self.calendar(for: action.context.timeZoneID) }

    private static func calendar(for zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .current
        return calendar
    }

    private var eventDates: some View {
        Group {
            EventDateTimeRow(title: strings["Начало"], dateTitle: strings["Дата начала"], timeTitle: strings["Время начала"],
                             identifier: "event-start", selection: Binding(get: { event.start }, set: { event.setStart($0, calendar: calendar) }),
                             allDay: event.allDay)
            EventDateTimeRow(title: strings["Окончание"], dateTitle: strings["Дата окончания"], timeTitle: strings["Время окончания"],
                             identifier: "event-end", selection: $event.end, allDay: event.allDay)
        }
    }

    private var eventFields: some View {
        Group {
            Picker(strings["Календарь"], selection: Binding(get: { action.proposal.calendarID ?? "" }, set: { action.proposal.calendarID = $0.isEmpty ? nil : $0 })) {
                Text(strings["Не выбран"]).tag("")
                ForEach(calendars) { Text($0.name).tag($0.id) }
            }
            Toggle(strings["Весь день"], isOn: Binding(get: { event.allDay }, set: { event.setAllDay($0, calendar: calendar) }))
            eventDates
            Toggle(strings["Напоминание"], isOn: $hasReminder)
            if hasReminder {
                TextField(strings["Напомнить за (мин)"], text: $reminderMinutes)
            }
            Picker(strings["Связанная задача"], selection: Binding(get: { action.proposal.linkTo ?? "" }, set: { action.proposal.linkTo = $0.isEmpty ? nil : $0 })) {
                Text(strings["Без связи"]).tag("")
                if let id = action.context.taskID { Text(action.context.taskTitle ?? strings["Задача"]).tag(id) }
                ForEach(actions.filter { $0.proposal.kind == .task }) { Text($0.proposal.title).tag($0.proposal.key) }
            }
        }
    }

    private var taskFields: some View {
        Group {
            Picker(strings["Папка"], selection: Binding(get: { action.proposal.folderID ?? "" }, set: { action.proposal.folderID = $0.isEmpty ? nil : $0 })) {
                Text(strings["Не выбрана"]).tag("")
                ForEach(folders) { Text($0.name).tag($0.id) }
            }
            Toggle(strings["На сегодня"], isOn: Binding(get: { action.proposal.today ?? false }, set: { action.proposal.today = $0 }))
            Toggle(strings["Срок задачи"], isOn: $hasDate)
            if hasDate {
                Toggle(strings["Указать время"], isOn: $includesTime)
                DatePicker(strings["Срок"], selection: $start, displayedComponents: includesTime ? [.date, .hourAndMinute] : [.date])
                Text(strings["Уведомления о сроке зависят от общих настроек приложения."]).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(strings["Подзадачи — каждая с новой строки"]).font(.caption.weight(.semibold))
                TextEditor(text: $checklist).frame(height: 80)
                    .accessibilityLabel(strings["Подзадачи — каждая с новой строки"])
            }
        }
    }

    private func commit() {
        var updated = action
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        let isEvent = updated.proposal.kind == .event
        let first = isEvent ? event.start : start
        format.dateFormat = "yyyy-MM-dd"
        updated.proposal.date = isEvent || hasDate ? format.string(from: first) : nil
        updated.proposal.endDate = isEvent ? format.string(from: event.end) : nil
        format.dateFormat = "HH:mm"
        updated.proposal.time = (isEvent ? !event.allDay : hasDate && includesTime) ? format.string(from: first) : nil
        updated.proposal.endTime = isEvent && !event.allDay ? format.string(from: event.end) : nil

        if let move = updated.calendarMove {
            do {
                let interval = try event.interval(calendar: calendar)
                updated.calendarMove = AssistantCalendarMove(source: move.source, start: interval.start, end: interval.end, timeZoneID: move.timeZoneID)
            } catch {
                self.error = error.localizedDescription
                return
            }
        } else if isEvent {
            let minutes = Int(reminderMinutes.trimmingCharacters(in: .whitespacesAndNewlines))
            if hasReminder, minutes.map({ (0...40320).contains($0) }) != true {
                error = "Проверьте напоминание."
                return
            }
            updated.proposal.allDay = event.allDay
            updated.proposal.durationMinutes = nil
            updated.proposal.reminderMinutes = hasReminder ? minutes : nil
            do { _ = try ActionPlanValidator.eventDraft(updated) }
            catch {
                self.error = error.localizedDescription
                return
            }
        } else {
            updated.proposal.reminderMinutes = nil
            updated.proposal.checklist = checklist.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        updated.error = nil
        updated.status = .pending
        error = save(updated)
    }
}
