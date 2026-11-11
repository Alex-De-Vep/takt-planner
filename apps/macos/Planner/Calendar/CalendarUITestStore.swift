#if DEBUG
import Foundation

/// Только явный запуск UI-тестов с отдельной библиотекой; личный EventKit не создаётся.
@MainActor final class CalendarUITestStore: CalendarStore {
    static func makeIfRequested() -> CalendarUITestStore? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PLANNER_UI_TEST_CALENDAR"] == "1",
              let library = environment["PLANNER_UI_TEST_LIBRARY"], UUID(uuidString: library) != nil else { return nil }
        return CalendarUITestStore()
    }
    let access: CalendarAccess = .full
    let defaultCalendarID: String? = "test"
    private var values: [CalendarEvent]

    init() {
        let cal = Calendar.current
        let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: .now)!
        let thirdDay = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: start))!
        values = [
            CalendarEvent(identifier: "ui-meeting", calendarID: "test", title: "Планирование", start: start, end: start.addingTimeInterval(5400)),
            CalendarEvent(identifier: "ui-all-day", calendarID: "test", title: "Поездка", start: thirdDay,
                          end: cal.date(byAdding: .day, value: 2, to: thirdDay)!, allDay: true),
            CalendarEvent(identifier: "ui-recurring", calendarID: "test", title: "Повторяющаяся встреча",
                          start: thirdDay.addingTimeInterval(12 * 3600), end: thirdDay.addingTimeInterval(13 * 3600), recurring: true)
        ]
        if ProcessInfo.processInfo.environment["PLANNER_UI_TEST_CALENDAR_ALARMS"] == "1" {
            values[0].alarms = [CalendarAlarm(id: "ui-relative", relativeOffset: -900),
                                CalendarAlarm(id: "ui-absolute", absoluteDate: start.addingTimeInterval(-1800))]
        }
        if ProcessInfo.processInfo.environment["PLANNER_UI_TEST_CALENDAR_DENSE"] == "1" {
            values += (0..<8).map { index in
                let time = start.addingTimeInterval(Double(index + 2) * 3600)
                return CalendarEvent(identifier: "ui-extra-\(index)", calendarID: "test", title: "Рабочий блок \(index + 1)",
                                     start: time, end: time.addingTimeInterval(1800))
            }
        }
    }
    func requestAccess() async throws -> Bool { true }
    func calendars() -> [CalendarInfo] { [CalendarInfo(id: "test", title: "Тестовый календарь", colorHex: "8050C0", writable: true)] }
    func events(in range: DateInterval, calendarIDs: Set<String>) throws -> [CalendarEvent] {
        values.filter { calendarIDs.contains($0.calendarID) && $0.start < range.end && $0.end > range.start }
    }
    func event(identifier: String) -> CalendarEvent? { values.first { $0.identifier == identifier } }
    func events(externalIdentifier: String) -> [CalendarEvent] { [] }
    func save(_ draft: EventDraft, original: CalendarEvent?) throws -> CalendarEvent {
        if let original, event(identifier: original.identifier)?.readOnlyReason != nil {
            throw CalendarFailure(message: "Этот календарь доступен только для чтения.")
        }
        let interval = try draft.interval()
        let saved = CalendarEvent(identifier: original?.identifier ?? UUID().uuidString, calendarID: draft.calendarID,
            title: draft.title, start: interval.start, end: interval.end, allDay: draft.allDay, notes: draft.notes, alarms: draft.alarms)
        values.removeAll { $0.identifier == saved.identifier }; values.append(saved)
        return saved
    }
    func delete(_ event: CalendarEvent) throws { values.removeAll { $0.identifier == event.identifier } }
}
#endif
