import AppKit
import EventKit
import Observation
import Combine

@MainActor
protocol CalendarStore {
    var access: CalendarAccess { get }
    var defaultCalendarID: String? { get }
    func requestAccess() async throws -> Bool
    func calendars() -> [CalendarInfo]
    func events(in range: DateInterval, calendarIDs: Set<String>) throws -> [CalendarEvent]
    func event(identifier: String) -> CalendarEvent?
    func events(externalIdentifier: String) -> [CalendarEvent]
    func save(_ draft: EventDraft, original: CalendarEvent?) throws -> CalendarEvent
    func delete(_ event: CalendarEvent) throws
}

@MainActor @Observable
final class CalendarService {
    private let store: any CalendarStore
    @ObservationIgnored private var observations: Set<AnyCancellable> = []
    private(set) var access: CalendarAccess = .notDetermined
    private(set) var calendars: [CalendarInfo] = []
    private(set) var revision = 0
    var connecting = false
    var connectionError: String?

    init(store: (any CalendarStore)? = nil, notificationCenter: NotificationCenter = .default) {
        #if SHOWCASE
        // Для публичных снимков EventKit вообще не создаётся: все события вымышленные.
        self.store = store ?? ShowcaseCalendarStore()
        #elseif DEBUG
        self.store = store ?? CalendarUITestStore.makeIfRequested() ?? EventKitAdapter()
        #else
        self.store = store ?? EventKitAdapter()
        #endif
        refresh()
        // Подписка живёт с сервисом, поэтому настройки обновляются даже без открытого рабочего окна.
        for name in [Notification.Name.EKEventStoreChanged, NSApplication.didBecomeActiveNotification,
                     .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            // NotificationCenter calls synchronously on the posting thread. The outer closure
            // must not inherit MainActor: its isolation check runs before the Task can hop there.
            notificationCenter.publisher(for: name).sink { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }.store(in: &observations)
        }
    }

    func refresh() {
        access = store.access
        calendars = access == .full ? store.calendars() : []
        revision += 1
    }
    func connect() async {
        guard !connecting else { return }
        connecting = true; connectionError = nil
        defer { connecting = false; refresh() }
        do { _ = try await store.requestAccess() }
        catch { connectionError = error.localizedDescription }
    }
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
    }
    func creationCalendar(preferred: String?) -> String? {
        if let preferred, calendars.contains(where: { $0.id == preferred && $0.writable }) { return preferred }
        return calendars.first(where: { $0.id == store.defaultCalendarID && $0.writable })?.id
            ?? calendars.first(where: \.writable)?.id
    }
    func load(_ range: DateInterval, visibleIDs: Set<String>?) throws -> [CalendarEvent] {
        guard store.access == .full else { throw CalendarFailure(message: "Нет доступа к календарям.") }
        let ids = Set(calendars.map(\.id)).intersection(visibleIDs ?? Set(calendars.map(\.id)))
        guard !ids.isEmpty else { return [] }
        return CalendarDates.sorted(try store.events(in: range, calendarIDs: ids))
    }
    func resolve(identifier: String, externalIdentifier: String?) -> CalendarEvent? {
        guard store.access == .full else { return nil }
        if let event = store.event(identifier: identifier) { return event }
        guard let externalIdentifier, !externalIdentifier.isEmpty else { return nil }
        let matches = store.events(externalIdentifier: externalIdentifier)
        // Внешний идентификатор не уникален для всех провайдеров и повторов.
        return matches.count == 1 ? matches[0] : nil
    }
    func save(_ draft: EventDraft, original: CalendarEvent?) throws -> CalendarEvent {
        guard store.access == .full else { throw CalendarFailure(message: "Нет доступа к календарям.") }
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CalendarFailure(message: "Введите название события.") }
        _ = try draft.interval()
        if let original { try validateExisting(original) }
        let result = try store.save(draft, original: original)
        refresh()
        return result
    }
    func delete(_ event: CalendarEvent) throws {
        guard store.access == .full else { throw CalendarFailure(message: "Нет доступа к календарям.") }
        try validateExisting(event)
        try store.delete(event); refresh()
    }

    /// Меняем только даты свежего события; повторная доставка того же drop не переносит его ещё раз.
    func move(_ request: CalendarMoveRequest, to day: Date) throws -> CalendarEventMove? {
        let latest = try editableForMove(request)
        guard !Calendar.current.isDate(request.sourceDay, inSameDayAs: day) else { return nil }
        let draft = try request.draft(for: latest, to: day)
        let saved = try store.save(draft, original: latest)
        refresh()
        return CalendarEventMove(before: latest, after: saved)
    }

    func undoMove(_ move: CalendarEventMove) throws -> CalendarEvent {
        let latest = try editableForMove(CalendarMoveRequest(event: move.after, sourceDay: move.after.start))
        var draft = EventDraft(event: latest)
        let before = EventDraft(event: move.before)
        draft.start = before.start; draft.end = before.end; draft.allDay = before.allDay
        let saved = try store.save(draft, original: latest)
        refresh()
        return saved
    }

    private func editableForMove(_ request: CalendarMoveRequest) throws -> CalendarEvent {
        guard store.access == .full else { throw CalendarFailure(message: "Нет доступа к календарям.") }
        guard let latest = store.event(identifier: request.identifier) else {
            throw CalendarFailure(message: "Событие больше недоступно. Возможно, оно удалено или перемещено.")
        }
        if let reason = latest.readOnlyReason { throw CalendarFailure(message: reason) }
        guard request.matches(latest) else {
            throw CalendarFailure(message: "Время события изменилось. Обновите расписание и повторите перенос.")
        }
        return latest
    }
    private func validateExisting(_ event: CalendarEvent) throws {
        guard let latest = store.event(identifier: event.identifier) else {
            throw CalendarFailure(message: "Событие больше недоступно. Возможно, оно удалено или перемещено.")
        }
        if let reason = latest.readOnlyReason { throw CalendarFailure(message: reason) }
    }
}

/// Только этот адаптер обращается к системному хранилищу. Запрос доступа всегда явный.
@MainActor
final class EventKitAdapter: CalendarStore {
    private let store = EKEventStore()
    var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .full
        case .notDetermined: .notDetermined
        case .writeOnly: .writeOnly
        case .restricted: .restricted
        default: .denied
        }
    }
    var defaultCalendarID: String? { access == .full ? store.defaultCalendarForNewEvents?.calendarIdentifier : nil }
    func requestAccess() async throws -> Bool { try await store.requestFullAccessToEvents() }
    func calendars() -> [CalendarInfo] {
        store.calendars(for: .event).map { calendar in
            let color = NSColor(cgColor: calendar.cgColor)?.usingColorSpace(.sRGB) ?? .systemPurple
            let hex = String(format: "%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
            return CalendarInfo(id: calendar.calendarIdentifier, title: calendar.title, colorHex: hex, writable: calendar.allowsContentModifications)
        }
    }
    func events(in range: DateInterval, calendarIDs: Set<String>) throws -> [CalendarEvent] {
        guard access == .full else { throw CalendarFailure(message: "Нет доступа к календарям.") }
        let calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)).map(snapshot)
    }
    func event(identifier: String) -> CalendarEvent? { store.event(withIdentifier: identifier).map(snapshot) }
    func events(externalIdentifier: String) -> [CalendarEvent] {
        store.calendarItems(withExternalIdentifier: externalIdentifier).compactMap { ($0 as? EKEvent).map(snapshot) }
    }
    private func snapshot(_ event: EKEvent) -> CalendarEvent {
        CalendarEvent(identifier: event.eventIdentifier ?? event.calendarItemIdentifier, externalIdentifier: event.calendarItemExternalIdentifier,
                      calendarID: event.calendar.calendarIdentifier, title: event.title ?? "", start: event.startDate, end: event.endDate,
                      allDay: event.isAllDay, notes: event.notes ?? "",
                      recurring: Self.isRecurring(event),
                      writable: event.calendar.allowsContentModifications, alarms: EventKitAlarms.snapshot(event.alarms ?? []))
    }
    static func isRecurring(_ event: EKEvent) -> Bool {
        // Дата вхождения сама по себе не задаёт повтор: ориентируемся на правила серии и её исключения.
        event.hasRecurrenceRules || event.isDetached
    }
    private func editable(_ original: CalendarEvent) throws -> EKEvent {
        guard let event = store.event(withIdentifier: original.identifier) else { throw CalendarFailure(message: "Событие больше недоступно. Возможно, оно удалено или перемещено.") }
        if let reason = snapshot(event).readOnlyReason { throw CalendarFailure(message: reason) }
        return event
    }
    func save(_ draft: EventDraft, original: CalendarEvent?) throws -> CalendarEvent {
        let event = try original.map(editable) ?? EKEvent(eventStore: store)
        let before = original.map { EventDraft(event: $0) }
        // Проверяем конфликт до изменения живого EventKit-объекта.
        let updatedAlarms: [EKAlarm]?
        if before == nil || before?.alarms != draft.alarms {
            updatedAlarms = try EventKitAlarms.updating(original == nil ? [] : (event.alarms ?? []),
                                                        original: original?.alarms ?? [], draft: draft.alarms)
        } else { updatedAlarms = nil }
        // Сравниваем с открытой формой, применяем изменения к свежему объекту: посторонние поля сохраняются.
        if before == nil || before?.calendarID != draft.calendarID {
            guard let calendar = store.calendar(withIdentifier: draft.calendarID), calendar.allowsContentModifications else { throw CalendarFailure(message: "Нет календаря для записи. Выберите другой календарь.") }
            event.calendar = calendar
        }
        if before == nil || before?.title != draft.title { event.title = draft.title }
        if before == nil || before?.notes != draft.notes { event.notes = draft.notes.isEmpty ? nil : draft.notes }
        let interval = try draft.interval()
        let changedDayMode = before == nil || before?.allDay != draft.allDay
        if changedDayMode { event.isAllDay = draft.allDay }
        if changedDayMode || before?.start != draft.start { event.startDate = interval.start }
        if changedDayMode || before?.end != draft.end { event.endDate = interval.end }
        if before == nil { event.timeZone = .current }
        guard event.endDate > event.startDate else { throw CalendarFailure(message: "Окончание должно быть позже начала.") }
        if let updatedAlarms { event.alarms = updatedAlarms }
        try store.save(event, span: .thisEvent, commit: true)
        return snapshot(event)
    }
    func delete(_ original: CalendarEvent) throws { try store.remove(editable(original), span: .thisEvent, commit: true) }
}

/// После успешного EventKit-сохранения повторная попытка выполняет только локальную часть операции.
@MainActor @Observable
final class EventSaveSession {
    private(set) var savedEvent: CalendarEvent?
    func save(draft: EventDraft, original: CalendarEvent?, calendar: CalendarService, link: ((CalendarEvent) -> Bool)?) throws -> CalendarEvent {
        let event: CalendarEvent
        if let savedEvent { event = savedEvent }
        else { event = try calendar.save(draft, original: original); savedEvent = event }
        if let link, !link(event) { throw CalendarFailure(message: "Событие сохранено, но связь с задачей — нет. Повторите сохранение связи: новое событие не будет создано.") }
        return event
    }
}
