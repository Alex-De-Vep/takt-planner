import Foundation

enum CalendarAccess: Equatable { case notDetermined, full, denied, restricted, writeOnly }

enum CalendarAgendaLayout: String {
    case vertical, horizontal

    var title: String { self == .vertical ? "Вертикальный список" : "Горизонтальные колонки" }
    var switchTitle: String { self == .vertical ? "Показать дни горизонтально" : "Показать дни вертикально" }
    var switchSymbol: String { self == .vertical ? "rectangle.split.2x1" : "rectangle.split.1x2" }
    var toggled: Self { self == .vertical ? .horizontal : .vertical }
}

enum CalendarAgendaMode: String, CaseIterable {
    case day, threeDays, week

    var title: String {
        switch self { case .day: "День"; case .threeDays: "3 дня"; case .week: "Неделя" }
    }
    var dayCount: Int {
        switch self { case .day: 1; case .threeDays: 3; case .week: 7 }
    }
    func days(containing date: Date, calendar: Calendar = .current) -> [Date] {
        let start = self == .week ? calendar.dateInterval(of: .weekOfYear, for: date)!.start : calendar.startOfDay(for: date)
        return (0..<dayCount).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }
}

/// В переносе нет заголовка и заметок: свежие сведения читаются из хранилища перед записью.
struct CalendarMoveRequest: Codable, Sendable {
    let identifier: String
    let start: Date
    let end: Date
    let allDay: Bool
    let sourceDay: Date

    init(event: CalendarEvent, sourceDay: Date) {
        identifier = event.identifier; start = event.start; end = event.end
        allDay = event.allDay; self.sourceDay = sourceDay
    }

    func matches(_ event: CalendarEvent) -> Bool {
        identifier == event.identifier && start == event.start && end == event.end && allDay == event.allDay
    }

    func draft(for event: CalendarEvent, to day: Date, calendar: Calendar = .current) throws -> EventDraft {
        guard matches(event), CalendarDates.occurs(event, on: sourceDay, calendar: calendar) else {
            throw CalendarFailure(message: "Время события изменилось. Обновите расписание и повторите перенос.")
        }
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: sourceDay), to: calendar.startOfDay(for: day)).day!
        // При переносе продолжения многодневного события сдвигаем весь интервал на разницу дней.
        guard let newDay = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: start)) else {
            throw CalendarFailure(message: "Не удалось определить дату переноса.")
        }
        var draft = EventDraft(event: event, calendar: calendar)
        if allDay {
            draft.setStart(newDay, calendar: calendar)
        } else {
            let time = calendar.dateComponents([.hour, .minute, .second], from: start)
            // Несуществующий час при переводе часов сдвигается вперёд с сохранением минут.
            guard let newStart = calendar.nextDate(after: newDay.addingTimeInterval(-1), matching: time,
                                                  matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first),
                  calendar.isDate(newStart, inSameDayAs: newDay) else {
                throw CalendarFailure(message: "Не удалось определить дату переноса.")
            }
            draft.setStart(newStart, calendar: calendar)
        }
        return draft
    }
}

struct CalendarEventMove {
    let before: CalendarEvent
    let after: CalendarEvent
}

struct CalendarInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let colorHex: String
    let writable: Bool
}

/// Значения интерфейса отделены от изменяемых объектов EventKit и личных календарей в тестах.
struct CalendarEvent: Identifiable, Equatable {
    var identifier: String
    var externalIdentifier: String?
    var calendarID: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool = false
    var notes: String = ""
    var alarms: [CalendarAlarm] = []
    // Совместимость со старым одиночным напоминанием; редактор использует полный массив alarms.
    var reminder: Int? {
        get { CalendarAlarm.firstOffset(alarms) }
        set { alarms = CalendarAlarm.legacy(newValue) }
    }
    var recurring: Bool = false
    var writable: Bool = true
    init(identifier: String, externalIdentifier: String? = nil, calendarID: String, title: String, start: Date, end: Date,
         allDay: Bool = false, notes: String = "", reminder: Int? = nil, recurring: Bool = false, writable: Bool = true,
         alarms: [CalendarAlarm]? = nil) {
        self.identifier = identifier; self.externalIdentifier = externalIdentifier; self.calendarID = calendarID
        self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.notes = notes
        self.alarms = alarms ?? CalendarAlarm.legacy(reminder); self.recurring = recurring; self.writable = writable
    }
    var id: String { identifier + ":" + String(start.timeIntervalSince1970) }
    var readOnlyReason: String? {
        if recurring { return "Повторяющиеся события и их исключения доступны только для просмотра." }
        if !writable { return "Этот календарь доступен только для чтения." }
        return nil
    }
}

struct CalendarFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct EventDraft: Equatable {
    // Помощник фиксирует пояс предложения; обычный редактор использует текущий пояс.
    var timeZoneID: String?
    var title = ""
    var start: Date
    // В форме последний день включён; EventKit получает исключительную верхнюю границу.
    var end: Date
    var allDay = false
    var calendarID: String
    var notes = ""
    var alarms: [CalendarAlarm] = []
    var reminder: Int? {
        get { CalendarAlarm.firstOffset(alarms) }
        set { alarms = CalendarAlarm.legacy(newValue) }
    }

    init(day: Date, calendarID: String, title: String = "", now: Date = .now, calendar: Calendar = .current) {
        self.calendarID = calendarID; self.title = title
        if calendar.isDate(day, inSameDayAs: now) {
            start = calendar.dateInterval(of: .hour, for: now)!.end
        } else {
            start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        }
        end = calendar.date(byAdding: .hour, value: 1, to: start)!
    }

    init(event: CalendarEvent, calendar: Calendar = .current) {
        title = event.title; start = event.start; allDay = event.allDay
        end = event.allDay ? calendar.date(byAdding: .day, value: -1, to: event.end)! : event.end
        calendarID = event.calendarID; notes = event.notes; alarms = event.alarms
    }

    func interval(calendar: Calendar = .current) throws -> DateInterval {
        var calendar = calendar
        if let timeZoneID, let zone = TimeZone(identifier: timeZoneID) { calendar.timeZone = zone }
        let first = allDay ? calendar.startOfDay(for: start) : start
        let last = allDay ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))! : end
        guard last > first else { throw CalendarFailure(message: "Окончание должно быть позже начала.") }
        return DateInterval(start: first, end: last)
    }

    mutating func setStart(_ value: Date, calendar: Calendar = .current) {
        guard value != start else { return }
        if allDay {
            // Для событий на весь день сохраняем число календарных дней, а не секунд:
            // переход на летнее или зимнее время не должен добавлять или убирать день.
            let days = max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                                      to: calendar.startOfDay(for: end)).day ?? 0)
            start = calendar.startOfDay(for: value)
            end = calendar.date(byAdding: .day, value: days, to: start) ?? start
        } else {
            // Начало и окончание меняются одной операцией. Ручное изменение окончания
            // задаёт новую длительность, которую сохраняем при следующем переносе.
            let duration = end.timeIntervalSince(start)
            start = value
            end = value.addingTimeInterval(duration > 0 ? duration : 3600)
        }
    }

    mutating func setAllDay(_ value: Bool, calendar: Calendar = .current) {
        guard allDay != value else { return }
        if value {
            // Полночь в окончании временного события уже относится к следующему, исключённому дню.
            let lastIncludedInstant = end > start ? end.addingTimeInterval(-1) : end
            start = calendar.startOfDay(for: start)
            end = max(start, calendar.startOfDay(for: lastIncludedInstant))
        } else {
            end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!
        }
        allDay = value
    }
}

enum CalendarDates {
    static func grid(for month: Date, calendar: Calendar = .current) -> [Date] {
        let first = calendar.dateInterval(of: .month, for: month)!.start
        let offset = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: first)!
        return (0..<42).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }
    static func range(of days: [Date], calendar: Calendar = .current) -> DateInterval {
        DateInterval(start: calendar.startOfDay(for: days.first!), end: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: days.last!))!)
    }
    static func occurs(_ event: CalendarEvent, on day: Date, calendar: Calendar = .current) -> Bool {
        let range = calendar.dateInterval(of: .day, for: day)!
        return event.start < range.end && event.end > range.start
    }
    static func sorted(_ events: [CalendarEvent]) -> [CalendarEvent] {
        events.sorted {
            if $0.allDay != $1.allDay { return $0.allDay }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
    }
}
