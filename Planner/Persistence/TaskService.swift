import Foundation
import Observation
import SwiftData

struct PlannerError: Identifiable {
    let id = UUID()
    let message: String
}

enum FolderValidationError: LocalizedError {
    case empty, duplicate
    var errorDescription: String? {
        switch self {
        case .empty: "Введите название папки."
        case .duplicate: "Папка с таким названием уже существует."
        }
    }
}

/// Все пользовательские изменения проходят через сервис и сразу сохраняются на диск.
@MainActor @Observable
final class TaskService {
    let context: ModelContext
    private let saveContext: (ModelContext) throws -> Void
    var error: PlannerError?
    var notificationChanged: ((UUID, Bool) -> Void)?
    // Маркер библиотеки защищает от переноса идентификаторов из другого хранилища процесса.
    let dragScopeID = UUID()
    // Неудачно сохранённый ввод принадлежит задаче и не пропадает при переключении между строками.
    var descriptionDrafts: [UUID: String] = [:]
    var titleDrafts: [UUID: String] = [:]
    var checklistDrafts: [UUID: String] = [:]

    init(context: ModelContext, saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.context = context
        self.saveContext = saveContext
        context.autosaveEnabled = false
    }

    @discardableResult
    private func persist(reportError: Bool = true, _ change: () -> Void) -> Bool {
        change()
        do {
            try saveContext(context)
            return true
        } catch {
            // При ошибке возвращаем согласованное состояние и показываем её в интерфейсе.
            context.rollback()
            if reportError { self.error = PlannerError(message: error.localizedDescription) }
            return false
        }
    }

    /// Точка атомарного сохранения для подготовленного плана помощника.
    func persistAssistant(_ change: () -> Void) -> Bool {
        // Помощник показывает ошибку в своей карточке, не открывая системное модальное окно.
        persist(reportError: false, change)
    }

    func createTask(in filter: TaskFilter, folders: [TaskFolder], now: Date = .now) -> PlannerTask? {
        // Общие представления создают задачу во «Входящих»; «Сегодня» дополнительно ставит звезду.
        let destination = filter.creationFolder
        let folder: TaskFolder?
        if case .folder(let id) = destination {
            guard let value = folders.first(where: { $0.id == id && !$0.isDeleted }) else { return nil }
            folder = value
        }
        else { folder = nil }
        let task = PlannerTask(folder: folder, now: now)
        task.systemFolderKind = destination == .week ? "week" : destination == .month ? "month" : "inbox"
        if filter == .today { task.focusDay = LocalDay.key(for: now) }
        return persist { context.insert(task) } ? task : nil
    }

    func rename(_ task: PlannerTask, to title: String, now: Date = .now) {
        // Разрешаем временно пустой заголовок во время ввода; список покажет «Новая задача».
        titleDrafts[task.id] = title
        guard task.title != title else { titleDrafts[task.id] = nil; return }
        if persist({ task.title = title; task.updatedAt = now }) {
            titleDrafts[task.id] = nil
            notificationChanged?(task.id, false)
        }
    }

    func toggleToday(_ task: PlannerTask, now: Date = .now, calendar: Calendar = .current) {
        // Меняется только фокус на день. Папка и статус выполнения остаются независимыми.
        persist {
            task.focusDay = task.isFocused(on: now, calendar: calendar) ? nil : LocalDay.key(for: now, calendar: calendar)
            task.updatedAt = now
        }
    }

    @discardableResult
    func markToday(_ task: PlannerTask, now: Date = .now) -> Bool {
        guard !task.isDeleted else { return false }
        guard !task.isFocused(on: now) else { return true }
        return persist { task.focusDay = LocalDay.key(for: now); task.updatedAt = now }
    }

    func description(for task: PlannerTask) -> String { descriptionDrafts[task.id] ?? task.descriptionText }

    @discardableResult
    func updateDescription(_ task: PlannerTask, text: String, now: Date = .now) -> Bool {
        descriptionDrafts[task.id] = text
        guard text != task.descriptionText else { descriptionDrafts[task.id] = nil; return true }
        let saved = persist { task.descriptionText = text; task.updatedAt = now }
        if saved { descriptionDrafts[task.id] = nil }
        return saved
    }

    func checklistTitle(for item: TaskChecklistItem) -> String { checklistDrafts[item.id] ?? item.title }

    /// Enter вставляет пункт после текущего, а кнопка в шапке — в конец списка.
    func addChecklistItem(to task: PlannerTask, after previous: TaskChecklistItem? = nil, now: Date = .now) -> TaskChecklistItem? {
        guard !task.isDeleted else { return nil }
        var items = task.orderedChecklistItems
        let index = previous.flatMap { previous in items.firstIndex { $0.id == previous.id }.map { $0 + 1 } } ?? items.count
        let item = TaskChecklistItem(task: task, sortOrder: index)
        items.insert(item, at: index)
        return persist {
            context.insert(item)
            for (order, row) in items.enumerated() { row.sortOrder = order }
            task.updatedAt = now
        } ? item : nil
    }

    @discardableResult
    func renameChecklistItem(_ item: TaskChecklistItem, to title: String, now: Date = .now) -> Bool {
        guard !item.isDeleted else { return false }
        checklistDrafts[item.id] = title
        guard item.title != title else { checklistDrafts[item.id] = nil; return true }
        let saved = persist { item.title = title; item.task?.updatedAt = now }
        if saved { checklistDrafts[item.id] = nil }
        return saved
    }

    @discardableResult
    func toggleChecklistItem(_ item: TaskChecklistItem, now: Date = .now) -> Bool {
        // Выполнение пункта не меняет выполнение, звёздочку или положение основной задачи.
        guard !item.isDeleted else { return false }
        return persist { item.isCompleted.toggle(); item.task?.updatedAt = now }
    }

    @discardableResult
    func deleteChecklistItem(_ item: TaskChecklistItem, now: Date = .now) -> Bool {
        let id = item.id
        let saved = persist { item.task?.updatedAt = now; context.delete(item) }
        if saved { checklistDrafts[id] = nil }
        return saved
    }

    @discardableResult
    func link(_ event: CalendarEvent, to task: PlannerTask) -> Bool {
        guard !(task.eventLinks ?? []).contains(where: { $0.eventIdentifier == event.identifier }) else { return true }
        return persist(reportError: false) { context.insert(TaskEventLink(task: task, event: event)) }
    }

    @discardableResult
    func removeLink(_ link: TaskEventLink) -> Bool { persist { context.delete(link) } }

    func refreshLink(_ link: TaskEventLink, event: CalendarEvent) {
        guard link.eventIdentifier != event.identifier || link.externalIdentifier != event.externalIdentifier
                || link.lastTitle != event.title || link.lastStart != event.start else { return }
        persist {
            link.eventIdentifier = event.identifier; link.externalIdentifier = event.externalIdentifier
            link.lastTitle = event.title; link.lastStart = event.start
        }
    }

    /// EventKit уже сохранил перенос; при ошибке повторяем только локальное обновление связей.
    func refreshEventLinks(_ links: [TaskEventLink], event: CalendarEvent) -> Bool {
        guard !links.isEmpty else { return true }
        let snapshots = links.map { (link: $0, identifier: $0.eventIdentifier, external: $0.externalIdentifier,
                                     title: $0.lastTitle, start: $0.lastStart) }
        let saved = persist(reportError: false) {
            for link in links where !link.isDeleted {
                link.eventIdentifier = event.identifier; link.externalIdentifier = event.externalIdentifier
                link.lastTitle = event.title; link.lastStart = event.start
            }
            // Фиксируем изменения в транзакции до save: rollback должен восстановить и живые объекты интерфейса.
            context.processPendingChanges()
        }
        if !saved {
            // SwiftData может оставить старый экземпляр @Query с изменёнными полями после rollback.
            for snapshot in snapshots where !snapshot.link.isDeleted {
                snapshot.link.eventIdentifier = snapshot.identifier; snapshot.link.externalIdentifier = snapshot.external
                snapshot.link.lastTitle = snapshot.title; snapshot.link.lastStart = snapshot.start
            }
        }
        return saved
    }

    func toggleCompleted(_ task: PlannerTask, now: Date = .now) {
        // Дата вместо Bool пригодится для будущей истории выполненных задач.
        if persist({ task.completedAt = task.isCompleted ? nil : now; task.updatedAt = now }) {
            notificationChanged?(task.id, false)
        }
    }

    @discardableResult
    func setDeadline(_ task: PlannerTask, to deadline: TaskDeadline?, now: Date = .now) -> Bool {
        // Ошибку показывает редактор срока, сохраняя черновик для повторной попытки.
        // Папка, звезда и планирование на неделю/месяц здесь не меняются.
        let previous = (task.deadlineDate, task.deadlineIncludesTime, task.deadlineTimeZoneID, task.updatedAt)
        let saved = persist(reportError: false) {
            task.deadlineDate = deadline?.date
            task.deadlineIncludesTime = deadline?.includesTime ?? false
            task.deadlineTimeZoneID = deadline?.timeZoneID
            task.updatedAt = now
        }
        if !saved {
            // SwiftData может обновить наблюдаемую модель после rollback не сразу.
            // Возвращаем прежние поля немедленно, чтобы строка не показывала несохранённый срок.
            (task.deadlineDate, task.deadlineIncludesTime, task.deadlineTimeZoneID, task.updatedAt) = previous
        }
        if saved { notificationChanged?(task.id, deadline != nil && !task.isCompleted) }
        return saved
    }

    @discardableResult
    func move(_ task: PlannerTask, to destination: TaskFilter, folders: [TaskFolder], now: Date = .now) -> Bool {
        guard !task.isDeleted, destination.isPrimaryFolder else { return false }
        let folder: TaskFolder?
        if case .folder(let id) = destination {
            guard let value = folders.first(where: { $0.id == id && !$0.isDeleted }) else { return false }
            folder = value
        } else { folder = nil }
        guard task.primaryFolder != destination else { return true }
        let previous = (task.folder, task.systemFolderKind, task.updatedAt)
        let saved = persist {
            task.folder = folder
            task.systemFolderKind = destination == .week ? "week" : destination == .month ? "month" : "inbox"
            task.updatedAt = now
        }
        // rollback может уведомить SwiftUI позже; сразу возвращаем строке исходную принадлежность.
        if !saved { (task.folder, task.systemFolderKind, task.updatedAt) = previous }
        return saved
    }

    @discardableResult func delete(_ task: PlannerTask) -> Bool {
        let id = task.id
        let checklistIDs = task.orderedChecklistItems.map(\.id)
        let saved = persist { context.delete(task) }
        if saved {
            notificationChanged?(id, false)
            descriptionDrafts[id] = nil; titleDrafts[id] = nil
            for itemID in checklistIDs { checklistDrafts[itemID] = nil }
        }
        return saved
    }

    func saveFolder(name: String, editing folder: TaskFolder? = nil) throws -> TaskFolder {
        // Не создаём пустые имена и дубликаты, отличающиеся только регистром.
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty else { throw FolderValidationError.empty }
        let existing = try context.fetch(FetchDescriptor<TaskFolder>())
        guard !existing.contains(where: { $0.id != folder?.id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw FolderValidationError.duplicate
        }
        let result = folder ?? TaskFolder(name: name, sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1)
        if folder == nil { context.insert(result) }
        result.name = name
        do { try context.save(); return result }
        catch { context.rollback(); throw error }
    }

    @discardableResult func deleteFolder(_ folder: TaskFolder) -> Bool {
        persist {
            // Перед удалением папки явно переносим её задачи во «Входящие».
            for task in folder.tasks ?? [] { task.folder = nil; task.systemFolderKind = "inbox" }
            context.delete(folder)
        }
    }
}
