import Foundation
import PlannerLocalization

/// Группа списка имеет постоянный идентификатор, не зависящий от перевода и выделения.
struct PlannerTaskSection: Identifiable {
    enum Heading {
        case active, inbox, week, month, folder(String), completed
    }

    let id: String
    let heading: Heading
    let tasks: [PlannerTask]

    func title(using strings: Translations) -> String? {
        switch heading {
        case .active: nil
        case .inbox: strings["Входящие"]
        case .week: strings["На неделе"]
        case .month: strings["Месяц"]
        case .folder(let name): name
        case .completed: strings["Выполнено"]
        }
    }
}

/// Общая проекция для отображения и навигации: их порядок всегда совпадает.
struct TaskListSnapshot {
    let sections: [PlannerTaskSection]
    var activeSections: [PlannerTaskSection] { sections.filter { $0.id != "completed" } }
    var activeTasks: [PlannerTask] { activeSections.flatMap(\.tasks) }
    var completedTasks: [PlannerTask] { sections.first { $0.id == "completed" }?.tasks ?? [] }
    var tasks: [PlannerTask] { sections.flatMap(\.tasks) }
    var taskIDs: [UUID] { tasks.map(\.id) }
    var activeCount: Int { activeTasks.count }

    init(tasks: [PlannerTask], filter: TaskFilter, search: String = "", now: Date, calendar: Calendar = .current) {
        // updatedAt остаётся историей изменений, но не участвует ни в сортировке, ни в группировке.
        let ordered = tasks.filter {
            filter.matches($0, now: now, calendar: calendar)
                && (search.isEmpty || $0.title.localizedStandardContains(search) || $0.descriptionText.localizedStandardContains(search))
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }

        let isSingleFolder: Bool
        switch filter {
        case .inbox, .week, .month, .folder, .all: isSingleFolder = true
        default: isSingleFolder = false
        }

        func group(for task: PlannerTask) -> (id: String, heading: PlannerTaskSection.Heading, order: Int) {
            // Внутри папки — непрерывный список без заголовков дней и месяцев создания.
            if isSingleFolder { return ("active", .active, 0) }
            if let folder = task.folder { return ("folder-\(folder.id)", .folder(folder.name), folder.sortOrder) }
            switch task.primaryFolder {
            case .week: return ("week", .week, -2)
            case .month: return ("month", .month, -1)
            default: return ("inbox", .inbox, .min)
            }
        }

        var orderedGroups: [(id: String, heading: PlannerTaskSection.Heading, order: Int)] = []
        var groupedTasks: [String: [PlannerTask]] = [:]
        var completed: [PlannerTask] = []
        for task in ordered {
            if task.isCompleted { completed.append(task); continue }
            let group = group(for: task)
            if groupedTasks[group.id] == nil { orderedGroups.append(group) }
            groupedTasks[group.id, default: []].append(task)
        }
        // Группы папок не зависят от самой новой видимой задачи: снятие звезды не двигает соседние группы.
        orderedGroups.sort {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id < $1.id
        }
        var sections = orderedGroups.map {
            PlannerTaskSection(id: $0.id, heading: $0.heading, tasks: groupedTasks[$0.id] ?? [])
        }
        if !completed.isEmpty {
            sections.append(.init(id: "completed", heading: .completed, tasks: completed))
        }
        self.sections = sections
    }
}
