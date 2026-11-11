import Foundation
import PlannerLocalization

/// Срок с точностью до дня или минуты. Для дня сохраняем пояс, чтобы поездка не сдвигала дату.
struct TaskDeadline: Equatable {
    let date: Date
    let includesTime: Bool
    let timeZoneID: String

    init(date: Date, includesTime: Bool, calendar: Calendar = .current) {
        self.date = includesTime ? (calendar.dateInterval(of: .minute, for: date)?.start ?? date)
            : calendar.startOfDay(for: date)
        self.includesTime = includesTime
        timeZoneID = calendar.timeZone.identifier
    }

    init(date: Date, includesTime: Bool, timeZoneID: String) {
        self.date = date
        self.includesTime = includesTime
        self.timeZoneID = timeZoneID
    }

    func localDate(in calendar: Calendar = .current) -> Date {
        guard !includesTime, let zone = TimeZone(identifier: timeZoneID) else { return date }
        var source = calendar
        source.timeZone = zone
        let day = source.dateComponents([.era, .year, .month, .day], from: date)
        return calendar.date(from: day) ?? date
    }

    func label(now: Date, strings: Translations, locale: Locale, calendar: Calendar = .current) -> String {
        let local = localDate(in: calendar)
        let day: String
        if calendar.isDate(local, inSameDayAs: now) {
            day = strings["Сегодня"]
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                  calendar.isDate(local, inSameDayAs: tomorrow) {
            day = strings["Завтра"]
        } else {
            var format = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .day().month(.abbreviated)
            if !calendar.isDate(local, equalTo: now, toGranularity: .year) { format = format.year() }
            day = local.formatted(format)
        }
        guard includesTime else { return day }
        let time = local.formatted(Date.FormatStyle(date: .omitted, time: .shortened,
            locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        return day + " · " + time
    }
}

/// Черновик живёт только в редакторе; выбор дня сохраняет время, а выключение времени сохраняет день.
struct TaskDeadlineDraft {
    var selection: Date
    var includesTime: Bool

    init(deadline: TaskDeadline?, now: Date = .now, calendar: Calendar = .current) {
        let day = deadline?.localDate(in: calendar) ?? now
        includesTime = deadline?.includesTime ?? false
        selection = includesTime ? day
            : (calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day)
    }

    mutating func chooseDay(_ day: Date, calendar: Calendar = .current) {
        let time = calendar.dateComponents([.hour, .minute], from: selection)
        selection = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0,
                                  second: 0, of: day) ?? day
    }

    func value(calendar: Calendar = .current) -> TaskDeadline {
        TaskDeadline(date: selection, includesTime: includesTime, calendar: calendar)
    }
}

extension PlannerTask {
    var deadline: TaskDeadline? {
        guard let deadlineDate else { return nil }
        return TaskDeadline(date: deadlineDate, includesTime: deadlineIncludesTime,
                            timeZoneID: deadlineTimeZoneID ?? TimeZone.current.identifier)
    }
}
