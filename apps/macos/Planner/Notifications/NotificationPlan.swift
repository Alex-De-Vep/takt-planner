import Foundation
import PlannerLocalization

struct NotificationSchedule: Equatable {
    var deadlinesEnabled = true
    var dateOnlyMinutes = 9 * 60
    var reviewEnabled = false
    var reviewMinutes = 9 * 60
    var reviewWeekdaysOnly = false
}

struct PlannerNotification: Equatable, Sendable {
    enum Trigger: Equatable, Sendable {
        case once(Date)
        case daily(hour: Int, minute: Int, weekday: Int?)
    }
    let id: String
    let title: String
    let body: String
    let trigger: Trigger
    var taskID: UUID?
    var usesLocalTime = false

    static let prefix = "planner."
    static let deadlinePrefix = "planner.deadline."
    static let reviewPrefix = "planner.review."
    static func deadlineID(_ id: UUID) -> String { deadlinePrefix + id.uuidString }

    static func deadlines(tasks: [PlannerTask], schedule: NotificationSchedule, strings: Translations,
                          now: Date, calendar: Calendar = .current) -> [Self] {
        guard schedule.deadlinesEnabled else { return [] }
        return tasks.compactMap { task in
            guard !task.isDeleted, !task.isCompleted, let deadline = task.deadline else { return nil }
            let date: Date
            if deadline.includesTime { date = deadline.date }
            else {
                guard let value = calendar.date(bySettingHour: schedule.dateOnlyMinutes / 60,
                    minute: schedule.dateOnlyMinutes % 60, second: 0, of: deadline.localDate(in: calendar)) else { return nil }
                date = value
            }
            guard date > now else { return nil }
            return Self(id: deadlineID(task.id), title: strings["Срок задачи"],
                        body: task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? strings["Новая задача"] : task.title,
                        trigger: .once(date), taskID: task.id, usesLocalTime: !deadline.includesTime)
        }.sorted {
            guard case .once(let a) = $0.trigger, case .once(let b) = $1.trigger else { return $0.id < $1.id }
            return a == b ? $0.id < $1.id : a < b
        }
    }

    static func reviews(schedule: NotificationSchedule, strings: Translations) -> [Self] {
        guard schedule.reviewEnabled else { return [] }
        let days: [Int?] = schedule.reviewWeekdaysOnly ? (2...6).map { Optional($0) } : [nil]
        return days.map { weekday in
            Self(id: reviewPrefix + (weekday.map(String.init) ?? "daily"), title: strings["Пора проверить задачи"],
                 body: strings["Откройте «Задачи», чтобы посмотреть планы и выбрать главное."],
                 trigger: .daily(hour: schedule.reviewMinutes / 60, minute: schedule.reviewMinutes % 60, weekday: weekday))
        }
    }
}
