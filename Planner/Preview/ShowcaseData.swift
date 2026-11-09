#if SHOWCASE
import AppKit
import SwiftData

/// Только для сборки с отдельным флагом SHOWCASE. В обычный Debug и Release не включается.
@MainActor enum ShowcaseData {
    static var english: Bool { Bundle.main.object(forInfoDictionaryKey: "ShowcaseLanguage") as? String == "en" }
    static func text(_ ru: String, _ en: String) -> String { english ? en : ru }
    static func time(_ hour: Int, dayOffset: Int = 0) -> Date {
        let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: .now)!
        return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    static func makePreferences() -> UserDefaults {
        let suite = "local.planner.showcase.preferences"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(english ? "en" : "ru", forKey: "appLanguage")
        defaults.set(true, forKey: "calendarOpen")
        defaults.set(340.0, forKey: "calendarWidth")
        let dark = Bundle.main.object(forInfoDictionaryKey: "ShowcaseAppearance") as? String == "dark"
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return defaults
    }

    static func populate(_ context: ModelContext) throws {
        let project = TaskFolder(name: text("Проекты", "Projects"), sortOrder: 0)
        let personal = TaskFolder(name: text("Личное", "Personal"), sortOrder: 1)
        let ideas = TaskFolder(name: text("Идеи", "Ideas"), sortOrder: 2)
        [project, personal, ideas].forEach { context.insert($0) }
        let titles = [
            text("Подготовить новую коллекцию", "Prepare the new collection"),
            text("Собрать идеи для выходных", "Collect ideas for the weekend"),
            text("Разобрать заметки со встречи", "Review the meeting notes"),
            text("Выбрать книгу на ноябрь", "Choose a book for November"),
            text("Навести порядок на рабочем столе", "Tidy up the workspace")
        ]
        for (index, title) in titles.enumerated() {
            let task = PlannerTask(title: title, now: Date.now.addingTimeInterval(-Double(index + 1) * 3600))
            context.insert(task)
            if index < 2 { task.focusDay = PlannerTask.persistentTodayMark }
            if index == 0 {
                task.descriptionText = text(
                    "Собрать всё необходимое к запуску. Начать с главного, а детали проверить перед публикацией.\n\nОставить время для спокойной финальной проверки.",
                    "Bring everything together for launch. Start with the essentials and check the details before publishing.\n\nLeave time for a thoughtful final review.")
                task.deadlineDate = time(18, dayOffset: 1)
                task.deadlineIncludesTime = true
                task.deadlineTimeZoneID = TimeZone.current.identifier
                let items = [text("Собрать референсы", "Gather references"), text("Подготовить фотографии", "Prepare photographs"), text("Проверить описание", "Review the description")]
                for (order, title) in items.enumerated() {
                    let item = TaskChecklistItem(task: task, title: title, sortOrder: order)
                    item.isCompleted = order == 0
                    context.insert(item)
                }
                context.insert(TaskEventLink(task: task, event: events[0]))
            }
            if index == 4 { task.completedAt = .now }
        }
        for (index, folder) in [project, personal, ideas].enumerated() {
            let task = PlannerTask(title: [text("Обновить портфолио", "Update the portfolio"), text("Запланировать поездку", "Plan a trip"), text("Набросок нового проекта", "Sketch a new project")][index], folder: folder)
            context.insert(task)
        }
        for (kind, title) in [("week", text("Подготовить план недели", "Prepare the week plan")),
                              ("month", text("Подвести итоги месяца", "Review the month"))] {
            let task = PlannerTask(title: title)
            task.systemFolderKind = kind
            context.insert(task)
        }
        try context.save()
    }

    static var events: [CalendarEvent] {
        [CalendarEvent(identifier: "showcase-focus", calendarID: "work", title: text("Работа над коллекцией", "Collection focus time"), start: time(10), end: time(12)),
         CalendarEvent(identifier: "showcase-review", calendarID: "work", title: text("Обсуждение идей", "Review ideas"), start: time(14), end: time(15)),
         CalendarEvent(identifier: "showcase-walk", calendarID: "personal", title: text("Прогулка без телефона", "A walk without the phone"), start: time(18), end: time(19))]
    }
}

/// Календарь в памяти: демонстрация не читает системные аккаунты и не запрашивает доступ.
@MainActor final class ShowcaseCalendarStore: CalendarStore {
    var access: CalendarAccess { .full }
    var defaultCalendarID: String? { "work" }
    private var values = ShowcaseData.events
    func requestAccess() async throws -> Bool { true }
    func calendars() -> [CalendarInfo] {
        [CalendarInfo(id: "work", title: ShowcaseData.text("Проекты", "Projects"), colorHex: "8050C0", writable: true),
         CalendarInfo(id: "personal", title: ShowcaseData.text("Личное", "Personal"), colorHex: "4A9E86", writable: true)]
    }
    func events(in range: DateInterval, calendarIDs: Set<String>) throws -> [CalendarEvent] {
        values.filter { calendarIDs.contains($0.calendarID) && $0.start < range.end && $0.end > range.start }
    }
    func event(identifier: String) -> CalendarEvent? { values.first { $0.identifier == identifier } }
    func events(externalIdentifier: String) -> [CalendarEvent] { [] }
    func save(_ draft: EventDraft, original: CalendarEvent?) throws -> CalendarEvent {
        let interval = try draft.interval()
        let event = CalendarEvent(identifier: original?.identifier ?? UUID().uuidString, calendarID: draft.calendarID,
            title: draft.title, start: interval.start, end: interval.end, allDay: draft.allDay, notes: draft.notes, reminder: draft.reminder)
        values.removeAll { $0.identifier == event.identifier }
        values.append(event)
        return event
    }
    func delete(_ event: CalendarEvent) throws { values.removeAll { $0.identifier == event.identifier } }
}
#endif
