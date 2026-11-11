import AppKit
import EventKit
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Planner

/// Ни одна из этих проверок не создаёт EKEventStore и не читает личные календари.
@MainActor
struct CalendarAndEditorTests {
    private func calendar(_ zone: String = "Europe/Moscow") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        value.firstWeekday = 2
        return value
    }
    private func date(_ day: Int, hour: Int = 9, month: Int = 10, zone: String = "Europe/Moscow") -> Date {
        calendar(zone).date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    private func event(_ id: String = "event", start: Date? = nil) -> CalendarEvent {
        let first = start ?? date(25)
        return CalendarEvent(identifier: id, externalIdentifier: "external-" + id, calendarID: "work", title: "Встреча", start: first, end: first.addingTimeInterval(3600))
    }

    @Test func migrationPreservesV1AndSurvivesReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Planner.store")
        let id = UUID(), folderID = UUID()
        try autoreleasepool {
            let schema = Schema(versionedSchema: PlannerSchemaV1.self)
            let config = ModelConfiguration("Planner", schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let folder = PlannerSchemaV1.TaskFolder(name: "Проект", sortOrder: 5)
            folder.id = folderID
            let task = PlannerSchemaV1.PlannerTask(title: "Старое название\nВторая строка", folder: folder, now: date(20))
            task.id = id; task.updatedAt = date(24); task.completedAt = date(23)
            task.focusDay = "2026-10-25"; task.planningKind = "week"; task.planningAnchor = date(25)
            container.mainContext.insert(task)
            try container.mainContext.save()
        }
        for pass in 0..<2 {
            try autoreleasepool {
                let container = try PlannerPersistence.makeContainer(at: url)
                let task = try #require(container.mainContext.fetch(FetchDescriptor<PlannerTask>()).first)
                #expect(task.id == id && task.folder?.id == folderID)
                #expect(task.title == "Старое название\nВторая строка")
                #expect(task.createdAt == date(20) && task.completedAt == date(23))
                #expect(task.focusDay == "2026-10-25" && task.planningKind == "week")
                #expect(task.planningAnchor == date(25))
                #expect(task.folder?.sortOrder == 5)
                #expect(task.descriptionText == (pass == 0 ? "" : "Описание после миграции"))
                if pass == 0 {
                    #expect(task.updatedAt == date(24))
                    let service = TaskService(context: container.mainContext)
                    #expect(service.updateDescription(task, text: "Описание после миграции"))
                    #expect(service.link(event(), to: task))
                } else { #expect(task.eventLinks?.count == 1) }
            }
        }
    }

    @Test func descriptionSearchKeepsCreationOrder() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        let a = try #require(service.createTask(in: .inbox, folders: [], now: date(25)))
        let b = try #require(service.createTask(in: .inbox, folders: [], now: date(25)))
        let before = TaskListSnapshot(tasks: [a, b], filter: .inbox, now: date(25)).taskIDs
        #expect(service.updateDescription(a, text: "Несколько строк\nСкрытый термин", now: date(26)))
        service.rename(a, to: "Изменено", now: date(27))
        #expect(TaskListSnapshot(tasks: [a, b], filter: .inbox, now: date(25)).taskIDs == before)
        #expect(TaskListSnapshot(tasks: [a, b], filter: .inbox, search: "скрытый", now: date(25)).taskIDs == [a.id])
        #expect(a.createdAt == date(25) && a.updatedAt == date(27))
    }

    @Test func failedTextSaveRetainsDraftPerTaskAndCanRetry() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        var fail = false
        let service = TaskService(context: container.mainContext, saveContext: {
            if fail { throw CalendarFailure(message: "Искусственная ошибка записи") }
            try $0.save()
        })
        let a = try #require(service.createTask(in: .inbox, folders: []))
        let b = try #require(service.createTask(in: .inbox, folders: []))
        fail = true
        #expect(!service.updateDescription(a, text: "Несохранённый текст"))
        service.rename(a, to: "Несохранённое название")
        #expect(service.description(for: a) == "Несохранённый текст")
        #expect(service.description(for: b).isEmpty && a.descriptionText.isEmpty)
        #expect(service.titleDrafts[a.id] == "Несохранённое название")
        fail = false
        service.rename(a, to: service.titleDrafts[a.id]!)
        #expect(service.updateDescription(a, text: service.description(for: a)))
        #expect(a.descriptionText == "Несохранённый текст" && service.descriptionDrafts.isEmpty)
        #expect(a.title == "Несохранённое название" && service.titleDrafts.isEmpty)
    }

    @Test func textualListRulesAndUnicode() {
        for (input, expected) in [("- Текст", "\n- "), ("* Текст", "\n* "), ("• Текст", "\n• "), ("9. Текст", "\n10. "), ("  1. 📅", "\n  2. ")] {
            let range = NSRange(location: (input as NSString).length, length: 0)
            #expect(PlainTextLists.newline(in: input, selection: range, shift: false).text == expected)
            #expect(PlainTextLists.newline(in: input, selection: range, shift: true).text == "\n")
        }
        let empty = PlainTextLists.newline(in: "Строка\n- ", selection: NSRange(location: 9, length: 0), shift: false)
        #expect(empty.text == "" && empty.range == NSRange(location: 7, length: 2))
        #expect(PlainTextLists.newline(in: "Текст", selection: NSRange(location: 5, length: 0), shift: false).text == "\n")
    }

    @Test func nativeEditorKeepsDocumentsAndUndoIndependent() {
        let store = TaskEditorStore(), firstID = UUID(), secondID = UUID()
        let first = store.view(taskID: firstID, title: false)
        let second = store.view(taskID: secondID, title: false)
        first.undoManager?.groupsByEvent = false
        first.undoManager?.beginUndoGrouping()
        first.insertText("Первая\nВторая", replacementRange: NSRange(location: 0, length: 0))
        first.undoManager?.endUndoGrouping()
        second.insertText("Другая задача", replacementRange: NSRange(location: 0, length: 0))
        #expect(store.view(taskID: firstID, title: false) === first)
        #expect(first.string == "Первая\nВторая" && !first.isRichText)
        first.undoManager?.undo()
        #expect(first.string.isEmpty && second.string == "Другая задача")
        first.undoManager?.redo()
        #expect(first.string == "Первая\nВторая")
    }

    @Test func editorMeasuresWrappingWithoutChangingLiveLayout() throws {
        let view = TaskEditorStore().view(taskID: UUID(), title: false)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 44)
        view.string = "Собрать всё необходимое к запуску.\nНачать с главного, а детали проверить перед публикацией.\n\nОставить время для спокойной финальной проверки."
        view.setSelectedRange(NSRange(location: 12, length: 5))
        let container = try #require(view.textContainer)
        let liveWidth = container.containerSize.width
        let wide = view.fittingSize(width: 600, minimumHeight: 44)
        let narrow = view.fittingSize(width: 280, minimumHeight: 44)
        #expect(narrow.height > wide.height)
        #expect(container.containerSize.width == liveWidth)
        #expect(view.selectedRange() == NSRange(location: 12, length: 5))
        // После пробных замеров реальный текст целиком помещается в выделенную ему область.
        view.frame.size = narrow
        let layout = try #require(view.layoutManager)
        layout.ensureLayout(for: container)
        #expect(layout.usedRect(for: container).maxY <= narrow.height)
        #expect(view.frame.height == narrow.height)
        view.string = "Строка\n"
        let endingWithNewline = view.fittingSize(width: 280, minimumHeight: 0)
        view.string = "Строка"
        #expect(endingWithNewline.height > view.fittingSize(width: 280, minimumHeight: 0).height)
    }

    @Test func eventDefaultsAndAllDayDST() throws {
        let cal = calendar("America/New_York")
        let spring = date(8, month: 3, zone: "America/New_York")
        var draft = EventDraft(day: spring, calendarID: "work", now: date(1), calendar: cal)
        draft.allDay = true; draft.start = spring; draft.end = spring
        let interval = try draft.interval(calendar: cal)
        #expect(interval.duration == 23 * 3600)
        #expect(cal.component(.hour, from: interval.end) == 0)
        let beforeMidnight = date(25, hour: 23).addingTimeInterval(30 * 60)
        let next = EventDraft(day: beforeMidnight, calendarID: "work", now: beforeMidnight, calendar: calendar())
        #expect(next.start == date(26, hour: 0) && next.end == date(26, hour: 1))
        let other = EventDraft(day: date(28), calendarID: "work", now: date(25), calendar: calendar())
        #expect(other.start == date(28, hour: 9))
        var midnight = EventDraft(event: event("night", start: date(25, hour: 23)), calendar: calendar())
        midnight.setAllDay(true, calendar: calendar())
        #expect(midnight.start == date(25, hour: 0) && midnight.end == date(25, hour: 0))
        #expect(try midnight.interval(calendar: calendar()).end == date(26, hour: 0))
    }

    @Test func eventsAcrossMidnightHaveExclusiveEndAndStableOrder() {
        let overnight = event("night", start: date(25, hour: 23))
        #expect(CalendarDates.occurs(overnight, on: date(25), calendar: calendar()))
        #expect(!CalendarDates.occurs(overnight, on: date(26), calendar: calendar()))
        var allDay = event("all"); allDay.allDay = true
        let sorted = CalendarDates.sorted([overnight, event(), allDay])
        #expect(sorted.map(\.identifier) == ["all", "event", "night"])
        let grid = CalendarDates.grid(for: date(25), calendar: calendar())
        #expect(grid.count == 42 && CalendarDates.range(of: grid, calendar: calendar()).duration == 42 * 86400)
    }

    @Test func movingEventStartMovesEndAndPreservesTheEditedDuration() throws {
        var draft = EventDraft(event: event(start: date(25, hour: 9)))
        draft.setStart(date(28, hour: 9), calendar: calendar())
        #expect(draft.end == date(28, hour: 10))
        draft.setStart(date(28, hour: 14), calendar: calendar())
        #expect(draft.end == date(28, hour: 15))
        // Пользователь увеличил длительность, затем перенёс событие на более ранний день.
        draft.end = date(28, hour: 16)
        draft.setStart(date(20, hour: 14), calendar: calendar())
        #expect(draft.end == date(20, hour: 16))
        #expect(try draft.interval(calendar: calendar()).duration == 7200)
    }

    @Test func movingTimedEventAcrossMidnightOrDSTKeepsItsDuration() throws {
        var draft = EventDraft(event: event(start: date(25, hour: 22)))
        draft.setStart(date(28, hour: 23).addingTimeInterval(1800), calendar: calendar())
        #expect(draft.end == date(29, hour: 0).addingTimeInterval(1800))

        let cal = calendar("America/New_York")
        draft.setStart(date(8, hour: 1, month: 3, zone: "America/New_York").addingTimeInterval(1800), calendar: cal)
        #expect(try draft.interval(calendar: cal).duration == 3600)
        #expect(cal.component(.hour, from: draft.end) == 3)
        #expect(cal.component(.minute, from: draft.end) == 30)
    }

    @Test func movingAllDayEventKeepsInclusiveCalendarDaysAcrossDST() throws {
        let cal = calendar("America/New_York")
        var draft = EventDraft(day: date(1, month: 3, zone: "America/New_York"), calendarID: "work", calendar: cal)
        draft.setAllDay(true, calendar: cal)
        let spring = date(8, hour: 0, month: 3, zone: "America/New_York")
        draft.setStart(spring, calendar: cal)
        #expect(draft.start == spring && draft.end == spring)
        #expect(try draft.interval(calendar: cal).duration == 23 * 3600)

        // Три дня остаются тремя днями после переноса через осенний перевод часов.
        draft.end = cal.date(byAdding: .day, value: 2, to: spring)!
        let autumn = date(31, hour: 0, month: 10, zone: "America/New_York")
        draft.setStart(autumn, calendar: cal)
        #expect(draft.end == date(2, hour: 0, month: 11, zone: "America/New_York"))
        #expect(try draft.interval(calendar: cal).duration == 73 * 3600)
    }

    @Test func permissionsRevocationAndCalendarSelection() async throws {
        let store = FakeCalendarStore()
        store.access = .notDetermined
        let service = CalendarService(store: store)
        #expect(service.calendars.isEmpty && store.requests == 0)
        store.grantsAccess = false
        await service.connect()
        #expect(service.access == .denied && store.requests == 1)
        store.grantsAccess = true
        await service.connect()
        #expect(service.access == .full)
        #expect(service.creationCalendar(preferred: nil) == "work")
        store.calendarList = [CalendarInfo(id: "read", title: "Read", colorHex: "000000", writable: false)]
        service.refresh()
        #expect(service.creationCalendar(preferred: "read") == nil)
        store.access = .denied; service.refresh()
        #expect(service.calendars.isEmpty)
        #expect(throws: CalendarFailure.self) { try service.load(DateInterval(start: date(25), duration: 3600), visibleIDs: nil) }
    }

    @Test func externalIdentifierMustResolveUnambiguously() {
        let store = FakeCalendarStore()
        let service = CalendarService(store: store)
        var moved = event("new"); moved.externalIdentifier = "shared"
        store.values = [moved]
        #expect(service.resolve(identifier: "old", externalIdentifier: "shared") == moved)
        var other = event("other"); other.externalIdentifier = "shared"
        store.values.append(other)
        #expect(service.resolve(identifier: "old", externalIdentifier: "shared") == nil)
        store.values = []
        #expect(service.resolve(identifier: "new", externalIdentifier: "shared") == nil)
    }

    @Test func occurrenceDateAloneDoesNotBlockEditingAnExistingOneOffEvent() throws {
        // Объект только в памяти: личное хранилище EventKit не создаётся и не читается.
        let source = RecurrenceEventStub()
        source.originalDate = date(25)
        #expect(source.occurrenceDate != nil)
        #expect(!EventKitAdapter.isRecurring(source))

        let store = FakeCalendarStore(), service = CalendarService(store: store)
        var original = event("existing")
        original.recurring = EventKitAdapter.isRecurring(source)
        store.values = [original]
        var draft = EventDraft(event: original)
        draft.title = "Изменённое событие"
        draft.notes = "Новое описание"
        let saved = try service.save(draft, original: original)
        #expect(saved.identifier == original.identifier && saved.title == draft.title && saved.notes == draft.notes)
        #expect(store.values.count == 1 && store.saves == 1)

        source.repeats = true
        #expect(EventKitAdapter.isRecurring(source))
        source.repeats = false; source.detached = true
        #expect(EventKitAdapter.isRecurring(source))
    }

    @Test func externallyRemovedOrReadOnlyEventsAreNeverRecreated() throws {
        let store = FakeCalendarStore(), original = event()
        let service = CalendarService(store: store)
        let draft = EventDraft(event: original)
        #expect(throws: CalendarFailure.self) { try service.save(draft, original: original) }
        #expect(store.saves == 0)
        var repeating = original; repeating.recurring = true
        store.values = [repeating]
        #expect(throws: CalendarFailure.self) { try service.save(draft, original: original) }
        #expect(throws: CalendarFailure.self) { try service.delete(original) }
        var readOnly = original; readOnly.writable = false
        store.values = [readOnly]
        #expect(throws: CalendarFailure.self) { try service.save(draft, original: original) }
        #expect(throws: CalendarFailure.self) { try service.delete(original) }
        store.values = [original]
        var edited = draft; edited.title = "Новое имя"
        #expect(try service.save(edited, original: original).title == "Новое имя")
        #expect(store.saves == 1 && store.values.count == 1)
    }

    @Test func visibleCalendarsAndRequestedRangeLimitResults() throws {
        let store = FakeCalendarStore(), service = CalendarService(store: store)
        var hidden = event("hidden"); hidden.calendarID = "private"
        store.values = [event(), hidden, event("outside", start: date(28))]
        let range = DateInterval(start: date(25, hour: 0), end: date(26, hour: 0))
        #expect(try service.load(range, visibleIDs: ["work"]).map(\.identifier) == ["event"])
        #expect(try service.load(range, visibleIDs: []).isEmpty)
    }

    @Test func partialLinkFailureNeverCreatesDuplicateEvent() throws {
        let store = FakeCalendarStore(), session = EventSaveSession()
        let service = CalendarService(store: store)
        let draft = EventDraft(day: date(25), calendarID: "work", title: "Встреча")
        #expect(throws: CalendarFailure.self) { try session.save(draft: draft, original: nil, calendar: service, link: { _ in false }) }
        let result = try session.save(draft: draft, original: nil, calendar: service, link: { _ in true })
        #expect(store.saves == 1 && store.values.count == 1 && result == session.savedEvent)
    }

    @Test func standaloneAndSeveralLinkedEventsRemainIndependent() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let tasks = TaskService(context: container.mainContext)
        let store = FakeCalendarStore(), service = CalendarService(store: store)
        _ = try service.save(EventDraft(day: date(25), calendarID: "work", title: "Самостоятельное"), original: nil)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PlannerTask>()) == 0)
        let task = try #require(tasks.createTask(in: .inbox, folders: []))
        for _ in 0..<2 {
            _ = try EventSaveSession().save(draft: EventDraft(day: date(25), calendarID: "work", title: "Время задачи"), original: nil, calendar: service, link: { tasks.link($0, to: task) })
        }
        #expect(task.eventLinks?.count == 2)
        tasks.toggleCompleted(task); tasks.toggleToday(task)
        #expect(store.saves == 3)
        try service.delete(store.values[1])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PlannerTask>()) == 1)
        #expect(tasks.delete(task))
        #expect(try container.mainContext.fetchCount(FetchDescriptor<TaskEventLink>()) == 0)
        #expect(store.values.count == 2)
    }

    @Test func panelLayoutAndLinkedNavigationDoNotDisturbSelection() {
        #expect(!CalendarPanelLayout.isColumn(width: 1100, sidebarVisible: true))
        #expect(CalendarPanelLayout.isColumn(width: 1400, sidebarVisible: true))
        #expect(CalendarPanelLayout.isColumn(width: 1100, sidebarVisible: false))
        #expect(CalendarPanelLayout.panelWidth(500) == 500 && CalendarPanelLayout.panelWidth(100) == 320)
        let state = WorkspaceState(), panel = CalendarPanelState(), task = PlannerTask(title: "Задача")
        let folder = TaskFolder(name: "Другая", sortOrder: 0); task.folder = folder
        state.updateSearch("Запрос", visibleIDs: [])
        state.openLinkedTask(task, visibleIDs: [])
        #expect(state.filter == .folder(folder.id) && state.search.isEmpty && state.selectedTaskID == task.id)
        panel.today(); panel.show(event())
        #expect(state.selectedTaskID == task.id && panel.selectedDate == event().start)
    }

    @Test func nativeCalendarReusesControllersWhenChangingPresentation() throws {
        // Проверяем структуру без создания окна, запуска приложения и доступа к EventKit.
        let container = WorkspaceContainerController()
        container.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 700)
        let original = container.workspace.splitViewItems.map { ObjectIdentifier($0.viewController) }
        container.update(calendar: AnyView(EmptyView()), visible: true, width: 340, sidebarVisible: true,
                         widthChanged: { _ in }, visibilityChanged: { _ in })
        let sidebar = try #require(container.workspace.splitViewItems.dropFirst(3).first)
        let calendarController = sidebar.viewController
        #expect(container.workspace.splitViewItems.count == 5)
        #expect(sidebar.behavior == .sidebar && sidebar.allowsFullHeightLayout)
        #expect(sidebar.canCollapse && sidebar.minimumThickness == 320 && sidebar.maximumThickness == 1200)
        let toolbarIDs = container.workspace.toolbarDefaultItemIdentifiers(NSToolbar())
        let menuIndex = try #require(toolbarIDs.firstIndex(of: NSToolbarItem.Identifier("Planner.TaskActions")))
        #expect(toolbarIDs[menuIndex - 1] == .space)
        #expect(toolbarIDs[menuIndex - 2] == NSToolbarItem.Identifier("Planner.Deadline"))
        #expect(toolbarIDs[menuIndex + 1] == .flexibleSpace)
        #expect(toolbarIDs[menuIndex + 2] == NSToolbarItem.Identifier("Planner.RightPanelSwitch"))
        #expect(toolbarIDs[menuIndex + 3] == NSToolbarItem.Identifier("Planner.CalendarBoundary"))

        container.view.frame.size.width = 900
        container.update(calendar: AnyView(EmptyView()), visible: true, width: 340, sidebarVisible: true,
                         widthChanged: { _ in }, visibilityChanged: { _ in })
        #expect(container.workspace.splitViewItems.map { ObjectIdentifier($0.viewController) } == original)
        #expect(calendarController.parent === container)
        #expect(calendarController.view.frame.height == container.view.bounds.height)

        container.view.frame.size.width = 1400
        container.update(calendar: AnyView(EmptyView()), visible: true, width: 340, sidebarVisible: true,
                         widthChanged: { _ in }, visibilityChanged: { _ in })
        #expect(container.workspace.splitViewItems[3].viewController === calendarController)
        #expect(container.workspace.splitViewItems.prefix(3).map { ObjectIdentifier($0.viewController) } == original)
    }
}

/// Подмена признаков события без EKEventStore, календарей пользователя и запросов разрешения.
private final class RecurrenceEventStub: EKEvent {
    var repeats = false
    var detached = false
    var originalDate: Date?
    override var hasRecurrenceRules: Bool { repeats }
    override var isDetached: Bool { detached }
    override var occurrenceDate: Date! { originalDate }
}

@MainActor
final class FakeCalendarStore: CalendarStore {
    var access: CalendarAccess = .full
    var grantsAccess = true
    var requests = 0
    var saves = 0
    var failSave = false
    var replacementIdentifier: String?
    var values: [CalendarEvent] = []
    var calendarList = [CalendarInfo(id: "work", title: "Работа", colorHex: "8050C0", writable: true)]
    var defaultCalendarID: String? { "work" }
    func requestAccess() async throws -> Bool { requests += 1; access = grantsAccess ? .full : .denied; return grantsAccess }
    func calendars() -> [CalendarInfo] { calendarList }
    func events(in range: DateInterval, calendarIDs: Set<String>) throws -> [CalendarEvent] {
        values.filter { calendarIDs.contains($0.calendarID) && $0.start < range.end && $0.end > range.start }
    }
    func event(identifier: String) -> CalendarEvent? { values.first { $0.identifier == identifier } }
    func events(externalIdentifier: String) -> [CalendarEvent] { values.filter { $0.externalIdentifier == externalIdentifier } }
    func save(_ draft: EventDraft, original: CalendarEvent?) throws -> CalendarEvent {
        if failSave { throw CalendarFailure(message: "Ошибка записи") }
        if let original {
            guard let latest = event(identifier: original.identifier), latest.readOnlyReason == nil else { throw CalendarFailure(message: "Недоступно") }
        }
        saves += 1
        let interval = try draft.interval()
        let event = CalendarEvent(identifier: replacementIdentifier ?? original?.identifier ?? UUID().uuidString,
            externalIdentifier: original?.externalIdentifier, calendarID: draft.calendarID, title: draft.title,
            start: interval.start, end: interval.end, allDay: draft.allDay, notes: draft.notes, alarms: draft.alarms)
        values.removeAll { $0.identifier == (original?.identifier ?? event.identifier) }; values.append(event)
        return event
    }
    func delete(_ event: CalendarEvent) throws { values.removeAll { $0.identifier == event.identifier } }
}
