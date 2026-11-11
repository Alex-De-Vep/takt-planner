import SwiftUI

/// Редактор предложения не меняет библиотеку, пока пользователь не применит план в чате.
struct AssistantActionEditor: View {
    @Environment(\.translations) private var strings
    @State var action: AssistantAction
    let folders: [AssistantFolder]
    let calendars: [AssistantCalendar]
    let actions: [AssistantAction]
    let save: (AssistantAction) -> Void
    let cancel: () -> Void
    @State private var hasDate = false
    @State private var includesTime = false
    @State private var start = Date()
    @State private var end = Date()
    @State private var checklist = ""
    /// Начальные даты задаём до первого показа: onAppear не должен выглядеть как перенос события.
    init(action: AssistantAction, folders: [AssistantFolder], calendars: [AssistantCalendar], actions: [AssistantAction],
         save: @escaping (AssistantAction) -> Void, cancel: @escaping () -> Void) {
        self._action = State(initialValue: action)
        self.folders = folders; self.calendars = calendars; self.actions = actions
        self.save = save; self.cancel = cancel
        let p = action.proposal
        let event = try? ActionPlanValidator.eventDraft(action)
        let initial = event?.start ?? (try? ActionPlanValidator.date(p.date, time: p.time, zone: action.context.timeZoneID)) ?? .now
        self._start = State(initialValue: initial)
        self._end = State(initialValue: event?.end ?? initial.addingTimeInterval(3600))
        self._hasDate = State(initialValue: p.date != nil)
        self._includesTime = State(initialValue: p.time != nil)
        self._checklist = State(initialValue: (p.checklist ?? []).joined(separator: "\n"))
    }
    private var isEvent: Bool { action.proposal.kind == .event }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                TextField(strings["Название"], text: $action.proposal.title)
                if isEvent {
                    Picker(strings["Календарь"], selection: Binding(get: { action.proposal.calendarID ?? "" }, set: { action.proposal.calendarID = $0.isEmpty ? nil : $0 })) {
                        Text(strings["Не выбран"]).tag("")
                        ForEach(calendars) { Text($0.name).tag($0.id) }
                    }
                    Toggle(strings["Весь день"], isOn: Binding(get: { action.proposal.allDay ?? false }, set: { action.proposal.allDay = $0 }))
                    DatePicker(strings["Начало"], selection: $start, displayedComponents: action.proposal.allDay == true ? [.date] : [.date, .hourAndMinute])
                        .onChange(of: start) { old, new in
                            var calendar = Calendar(identifier: .gregorian)
                            calendar.timeZone = TimeZone(identifier: action.context.timeZoneID) ?? .current
                            var draft = EventDraft(day: old, calendarID: action.proposal.calendarID ?? "")
                            draft.start = old; draft.end = end; draft.allDay = action.proposal.allDay ?? false
                            draft.setStart(new, calendar: calendar)
                            end = draft.end
                        }
                    DatePicker(strings["Окончание"], selection: $end, displayedComponents: action.proposal.allDay == true ? [.date] : [.date, .hourAndMinute])
                    Picker(strings["Напоминание"], selection: Binding(get: { action.proposal.reminderMinutes ?? -1 }, set: { action.proposal.reminderMinutes = $0 < 0 ? nil : $0 })) {
                        Text(strings["Без напоминания"]).tag(-1)
                        ForEach([0, 5, 10, 15, 30, 60, 1440], id: \.self) { Text(strings.format("За %d мин", $0)).tag($0) }
                    }
                    Picker(strings["Связанная задача"], selection: Binding(get: { action.proposal.linkTo ?? "" }, set: { action.proposal.linkTo = $0.isEmpty ? nil : $0 })) {
                        Text(strings["Без связи"]).tag("")
                        if let id = action.context.taskID { Text(action.context.taskTitle ?? strings["Задача"]).tag(id) }
                        ForEach(actions.filter { $0.proposal.kind == .task }) { Text($0.proposal.title).tag($0.proposal.key) }
                    }
                } else {
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
                    Text(strings["Подзадачи — каждая с новой строки"]).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $checklist).frame(height: 80)
                }
                Text(strings["Описание"]).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { action.proposal.description ?? "" }, set: { action.proposal.description = $0 })).frame(height: 80)
            }.textFieldStyle(.roundedBorder)
            HStack {
                Button(strings["Отмена"], action: cancel)
                Spacer()
                Button(strings["Готово"]) { commit() }.buttonStyle(.borderedProminent)
            }.padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .environment(\.timeZone, TimeZone(identifier: action.context.timeZoneID) ?? .current)
    }

    private func commit() {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = TimeZone(identifier: action.context.timeZoneID)
        format.dateFormat = "yyyy-MM-dd"
        action.proposal.date = isEvent || hasDate ? format.string(from: start) : nil
        action.proposal.endDate = isEvent ? format.string(from: end) : nil
        format.dateFormat = "HH:mm"
        action.proposal.time = (isEvent ? action.proposal.allDay != true : hasDate && includesTime) ? format.string(from: start) : nil
        action.proposal.endTime = isEvent && action.proposal.allDay != true ? format.string(from: end) : nil
        if isEvent { action.proposal.durationMinutes = max(1, Int(end.timeIntervalSince(start) / 60)) }
        else { action.proposal.reminderMinutes = nil; action.proposal.checklist = checklist.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        action.error = nil; action.status = .pending
        save(action)
    }
}
