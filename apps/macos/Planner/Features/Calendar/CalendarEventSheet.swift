import SwiftUI

/// Собственная нативная форма macOS: EventKitUI не предоставляет здесь редактор событий.
struct CalendarEventSheet: View {
    @Environment(\.translations) private var strings
    @Environment(\.dismiss) private var dismiss
    let request: EventPresentation
    let calendar: CalendarService
    let preferences: AppPreferences
    let link: ((CalendarEvent) -> Bool)?
    @State private var draft: EventDraft
    @State private var current: CalendarEvent?
    @State private var editing: Bool
    @State private var error: String?
    @State private var unavailable = false
    @State private var deleting = false
    @State private var session = EventSaveSession()

    init(request: EventPresentation, calendar: CalendarService, preferences: AppPreferences, link: ((CalendarEvent) -> Bool)?) {
        self.request = request; self.calendar = calendar; self.preferences = preferences; self.link = link
        _current = State(initialValue: request.event)
        _editing = State(initialValue: request.event == nil)
        _draft = State(initialValue: request.event.map { EventDraft(event: $0) }
            ?? EventDraft(day: request.day, calendarID: calendar.creationCalendar(preferred: preferences.creationCalendarID) ?? "", title: request.title))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(strings[request.event == nil ? "Новое событие" : "Событие"]).font(.title2.bold())
            if editing { ScrollView { form }.frame(maxHeight: 480) } else { details }
            if let error { Text(strings[error]).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                // У существующего события удаление доступно и прямо из редактора.
                if let current, current.readOnlyReason == nil, !unavailable, session.savedEvent == nil {
                    Button(strings["Удалить"], role: .destructive) { deleting = true }
                }
                Spacer()
                Button(strings[session.savedEvent != nil ? "Оставить без связи" : "Отмена"]) { dismiss() }.keyboardShortcut(.cancelAction)
                if editing {
                    Button(strings[session.savedEvent == nil ? "Сохранить" : "Повторить сохранение связи"]) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(unavailable || calendar.access != .full || (session.savedEvent == nil && calendar.creationCalendar(preferred: draft.calendarID) == nil))
                } else if current?.readOnlyReason == nil, !unavailable {
                    Button(strings["Редактировать"]) { beginEditing() }.keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 480)
            .interactiveDismissDisabled(session.savedEvent != nil)
            .alert(strings["Удалить событие?"], isPresented: $deleting) {
                Button(strings["Удалить"], role: .destructive) {
                    guard let current else { return }
                    do { try calendar.delete(current); dismiss() } catch { self.error = error.localizedDescription }
                }
                Button(strings["Отмена"], role: .cancel) {}
            } message: { Text(strings["Событие будет удалено из системного календаря. Задача сохранится."]) }
            // Сразу открываем редактор после проверки актуальных прав. Для повторов и
            // календарей только для чтения остаются сведения с объяснением ограничения.
            .onAppear { beginEditing() }
            .onChange(of: calendar.revision) { refreshDetails() }
    }
    private var form: some View {
        Form {
            TextField(strings["Название события"], text: $draft.title)
            Toggle(strings["Весь день"], isOn: Binding(get: { draft.allDay }, set: { draft.setAllDay($0) }))
            EventDateTimeRow(title: strings["Начало"], dateTitle: strings["Дата начала"], timeTitle: strings["Время начала"],
                             identifier: "event-start", selection: Binding(get: { draft.start }, set: { draft.setStart($0) }),
                             allDay: draft.allDay)
            EventDateTimeRow(title: strings["Окончание"], dateTitle: strings["Дата окончания"], timeTitle: strings["Время окончания"],
                             identifier: "event-end", selection: $draft.end, allDay: draft.allDay)
            Picker(strings["Календарь"], selection: $draft.calendarID) {
                if !calendar.calendars.contains(where: { $0.id == draft.calendarID && $0.writable }) {
                    Text(strings["Выберите календарь"]).tag(draft.calendarID)
                }
                ForEach(calendar.calendars.filter(\.writable)) { item in Text(item.title).tag(item.id) }
            }
            CalendarAlarmsEditor(alarms: $draft.alarms, eventStart: draft.start)
                .frame(width: 280, alignment: .leading)
            TextField(strings["Заметки к событию"], text: $draft.notes, axis: .vertical).lineLimit(3...8)
        }.disabled(session.savedEvent != nil)
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let event = current {
                Text(event.title).font(.headline).textSelection(.enabled)
                if event.allDay {
                    Text(strings["Весь день"])
                    Text(draft.start, format: .dateTime.day().month(.wide).year())
                    if !Calendar.current.isDate(draft.start, inSameDayAs: draft.end) {
                        Text(draft.end, format: .dateTime.day().month(.wide).year())
                    }
                } else {
                    Text(event.start, format: .dateTime.day().month(.wide).year().hour().minute())
                    Text(event.end, format: .dateTime.day().month(.wide).year().hour().minute())
                }
                Text(calendar.calendars.first { $0.id == event.calendarID }?.title ?? strings["Календарь"])
                    .foregroundStyle(.secondary)
                CalendarAlarmsSummary(alarms: event.alarms)
                if !event.notes.isEmpty { ScrollView { Text(event.notes).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 180) }
                if let reason = event.readOnlyReason { Text(strings[reason]).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }
    private func beginEditing() {
        // Повторное появление формы не должно сбрасывать уже введённые изменения.
        guard !editing else { return }
        refreshDetails()
        guard !unavailable, current?.readOnlyReason == nil, let current else { return }
        draft = EventDraft(event: current); editing = true
    }
    private func refreshDetails() {
        guard !editing, let event = current else { return }
        guard let latest = calendar.resolve(identifier: event.identifier, externalIdentifier: event.externalIdentifier) else {
            unavailable = true; error = "Событие больше недоступно. Возможно, оно удалено или перемещено."; return
        }
        current = latest; draft = EventDraft(event: latest); unavailable = false; error = nil
    }
    private func save() {
        do {
            _ = try session.save(draft: draft, original: current, calendar: calendar, link: link)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
