import Foundation
import PlannerLocalization

/// Значения прежнего планирования сохраняем для совместимости старых библиотек.
enum PlanningPeriod: String, CaseIterable, Identifiable {
    case week, month
    var id: String { rawValue }
    func title(using strings: Translations) -> String { strings[self == .week ? "На неделе" : "В этом месяце"] }
    var component: Calendar.Component { self == .week ? .weekOfYear : .month }
}

/// Основные папки не пересекаются. «Сегодня» и «Все задачи» — общие представления без копирования.
enum TaskFilter: Hashable, Identifiable {
    case inbox, today, week, month, all
    case folder(UUID)

    static let smartFilters: [TaskFilter] = [.today, .inbox, .week, .month, .all]
    static let systemFolders: [TaskFilter] = [.inbox, .week, .month]

    var isPrimaryFolder: Bool {
        switch self {
        case .inbox, .week, .month, .folder: true
        case .today, .all: false
        }
    }
    var acceptsTaskDrop: Bool { self != .all }
    var creationFolder: TaskFilter { isPrimaryFolder ? self : .inbox }
    var id: String {
        switch self {
        case .inbox: "inbox"
        case .today: "today"
        case .week: "week"
        case .month: "month"
        case .all: "all"
        case .folder(let id): "folder-\(id.uuidString)"
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .today: "star"
        case .week: "calendar"
        case .month: "calendar.badge.clock"
        case .all: "square.stack"
        case .folder: "folder"
        }
    }

    func title(in folders: [TaskFolder], using strings: Translations) -> String {
        switch self {
        case .inbox: strings["Входящие"]
        case .today: strings["Сегодня"]
        case .week: strings["На неделе"]
        case .month: strings["Месяц"]
        case .all: strings["Все задачи"]
        case .folder(let id): folders.first { $0.id == id }?.name ?? strings["Папка"]
        }
    }

    func matches(_ task: PlannerTask, now: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .today: return task.isFocused(on: now, calendar: calendar)
        case .all: return true
        default: return task.primaryFolder == self
        }
    }
}

enum LocalDay {
    // Формат ключа всегда григорианский, часовой пояс берём из пользовательского календаря.
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension PlannerTask {
    // Зарезервированный ключ для постоянной звезды в существующем формате хранения и синхронизации.
    static let persistentTodayMark = "9999-12-31"

    var primaryFolder: TaskFilter {
        if let folder { return .folder(folder.id) }
        switch systemFolderKind {
        case "week": return .week
        case "month": return .month
        default: return .inbox
        }
    }

    func isFocused(on date: Date, calendar: Calendar = .current) -> Bool {
        focusDay == Self.persistentTodayMark || focusDay == LocalDay.key(for: date, calendar: calendar)
    }
}
