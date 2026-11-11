import SwiftUI
import Observation

struct EventPresentation: Identifiable {
    let id = UUID()
    var event: CalendarEvent?
    var day: Date
    var taskID: UUID?
    var title = ""
}

/// Дата принадлежит окну и сохраняется при закрытии панели; при запуске всегда выбран сегодняшний день.
@MainActor @Observable
final class CalendarPanelState {
    var selectedDate: Date
    var month: Date
    var agendaAnchor: Date
    var presentation: EventPresentation?
    var message: String?
    var lastMove: CalendarEventMove?
    var pendingLinkUpdate: (ids: [UUID], event: CalendarEvent)?

    init(date: Date = .now) { selectedDate = date; month = date; agendaAnchor = date }
    func select(_ date: Date) { selectedDate = date; month = date; agendaAnchor = date }
    func today() { select(.now) }
    func shiftPeriod(_ direction: Int, mode: CalendarAgendaMode, calendar: Calendar = .current) {
        let offset = direction * mode.dayCount
        agendaAnchor = calendar.date(byAdding: .day, value: offset, to: agendaAnchor)!
        selectedDate = calendar.date(byAdding: .day, value: offset, to: selectedDate)!
        month = selectedDate
    }
    func show(_ event: CalendarEvent) {
        select(event.start)
        presentation = EventPresentation(event: event, day: event.start)
    }
}

struct CalendarPanel: View {
    @Environment(\.translations) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var state: CalendarPanelState
    @Bindable var preferences: AppPreferences
    let service: CalendarService
    let taskService: TaskService
    let selectedTask: PlannerTask?
    let tasks: [PlannerTask]
    let links: [TaskEventLink]
    let openTask: (PlannerTask) -> Void
    let isVisible: Bool
    @State private var events: [CalendarEvent] = []
    @State private var loading = false
    @State private var loadError: String?

    private var days: [Date] { CalendarDates.grid(for: state.month) }
    private var monthStart: Date { Calendar.current.dateInterval(of: .month, for: state.month)!.start }
    private var agendaDays: [Date] { preferences.calendarAgendaMode.days(containing: state.agendaAnchor) }
    private var queryKey: String {
        "\(isVisible):\(state.month.timeIntervalSince1970):\(state.agendaAnchor.timeIntervalSince1970):\(preferences.calendarAgendaMode.rawValue):\(service.revision):\(preferences.visibleCalendarIDs?.sorted().joined(separator: ",") ?? "all")"
    }
    var body: some View {
        VStack(spacing: 0) {
            if service.access == .full {
                monthGrid.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
                Divider()
                agendaHeader
                agenda
                moveFeedback
                creationActions
            } else {
                CalendarAccessView(service: service).padding(20)
                Spacer()
            }
        }
        // Как в панели папок, содержимое прозрачно: материал, рамку и скругления рисует оболочка AppKit.
        .background(.clear)
        .task(id: queryKey) { await reload() }
        .onChange(of: preferences.calendarAgendaMode) { state.agendaAnchor = state.selectedDate }
        .sheet(item: $state.presentation) { request in
            CalendarEventSheet(request: request, calendar: service, preferences: preferences,
                link: request.taskID.map { id in
                    { event in
                        guard let task = tasks.first(where: { $0.id == id }), !task.isDeleted else { return false }
                        return taskService.link(event, to: task)
                    }
                })
        }
        .alert(strings["Календарь"], isPresented: Binding(get: { state.message != nil }, set: { if !$0 { state.message = nil } })) {
            Button(strings["Понятно"], role: .cancel) { state.message = nil }
        } message: { Text(strings[state.message ?? ""]) }
    }

    private var monthGrid: some View {
        VStack(spacing: 12) {
            HStack {
                Text(state.month, format: .dateTime.month(.wide).year()).font(.system(size: 14, weight: .semibold))
                    .contentTransition(.opacity)
                    .animation(PlannerMotion.animation(reduceMotion: reduceMotion), value: monthStart)
                Spacer()
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .help(strings["Предыдущий месяц"]).accessibilityLabel(strings["Предыдущий месяц"])
                Button(strings["Сегодня"]) { state.today() }.font(.caption)
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                    .help(strings["Следующий месяц"]).accessibilityLabel(strings["Следующий месяц"])
            }.buttonStyle(.plain)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(Array(days.prefix(7).enumerated()), id: \.offset) { _, day in
                    Text(day, format: .dateTime.weekday(.narrow)).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(days, id: \.self) { day in
                    let selected = Calendar.current.isDate(day, inSameDayAs: state.selectedDate)
                    let today = Calendar.current.isDateInToday(day)
                    Button { state.select(day) } label: {
                        VStack(spacing: 2) {
                            Text(day, format: .dateTime.day()).font(.system(size: 12, weight: today ? .bold : .regular))
                                .frame(width: 28, height: 25)
                                .background(selected ? PlannerStyle.accent : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .overlay { if today { RoundedRectangle(cornerRadius: 7).stroke(PlannerStyle.accent, lineWidth: 1) } }
                                .foregroundStyle(selected ? .white : .primary)
                                .animation(PlannerMotion.animation(.feedback, reduceMotion: reduceMotion), value: selected)
                            Circle().fill(events.contains { CalendarDates.occurs($0, on: day) } ? PlannerStyle.accent : .clear).frame(width: 3, height: 3)
                        }
                        .opacity(Calendar.current.isDate(day, equalTo: state.month, toGranularity: .month) ? 1 : 0.4)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .id(monthStart)
            .transition(.opacity)
        }
        .animation(PlannerMotion.animation(reduceMotion: reduceMotion), value: monthStart)
    }

    private var agendaHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(periodTitle).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).help(periodTitle)
                    .contentTransition(.opacity)
                    .animation(PlannerMotion.animation(reduceMotion: reduceMotion), value: periodTitle)
                    .accessibilityIdentifier("calendar-agenda-period")
                Spacer(minLength: 0)
                Button { state.shiftPeriod(-1, mode: preferences.calendarAgendaMode) } label: { Image(systemName: "chevron.left") }
                    .help(strings["Предыдущий период"]).accessibilityLabel(strings["Предыдущий период"])
                Button { state.shiftPeriod(1, mode: preferences.calendarAgendaMode) } label: { Image(systemName: "chevron.right") }
                    .help(strings["Следующий период"]).accessibilityLabel(strings["Следующий период"])
            }.buttonStyle(.plain)
            HStack(spacing: 10) {
                Picker(strings["Период событий"], selection: $preferences.calendarAgendaMode) {
                    ForEach(CalendarAgendaMode.allCases, id: \.self) { mode in Text(strings[mode.title]).tag(mode) }
                }.pickerStyle(.segmented).labelsHidden()
                    .accessibilityIdentifier("calendar-agenda-mode")
                Button { preferences.calendarAgendaLayout = preferences.calendarAgendaLayout.toggled } label: {
                    Image(systemName: preferences.calendarAgendaLayout.switchSymbol)
                        .font(.system(size: 15)).frame(width: 26, height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .disabled(preferences.calendarAgendaMode == .day)
                    .help(strings[preferences.calendarAgendaMode == .day
                        ? "Выберите 3 дня или неделю для смены расположения" : preferences.calendarAgendaLayout.switchTitle])
                    .accessibilityLabel(strings[preferences.calendarAgendaLayout.switchTitle])
                    .accessibilityValue(strings[preferences.calendarAgendaLayout.title])
                    .accessibilityIdentifier("calendar-agenda-layout")
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var periodTitle: String {
        if preferences.calendarAgendaMode == .day {
            return state.selectedDate.formatted(.dateTime.day().month(.wide).weekday(.wide).locale(strings.language.locale))
        }
        let format = Date.FormatStyle.dateTime.day().month(.abbreviated).year().locale(strings.language.locale)
        return agendaDays.first!.formatted(format) + " – " + agendaDays.last!.formatted(format)
    }

    @ViewBuilder private var agenda: some View {
        if loading && events.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 12) {
                Text(strings[loadError]).foregroundStyle(.secondary)
                Button(strings["Повторить"]) { service.refresh() }
            }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            CalendarAgendaView(days: agendaDays, events: events, selectedDate: $state.selectedDate,
                layout: preferences.calendarAgendaLayout,
                calendars: service.calendars, links: links, canMove: state.pendingLinkUpdate == nil,
                openEvent: { event, day in state.presentation = EventPresentation(event: event, day: day) },
                openTask: openTask, moveEvent: moveEvent)
        }
    }

    @ViewBuilder private var moveFeedback: some View {
        if state.pendingLinkUpdate != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text(strings["Дата события сохранена, но связь с задачей не обновлена."]).font(.caption)
                Button(strings["Повторить сохранение связи"]) { retryLinkUpdate() }
            }.padding(.horizontal, 16).padding(.top, 8)
        } else if let move = state.lastMove {
            HStack {
                Text(strings["Событие перенесено"]).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(strings["Отменить перенос"]) { undoMove(move) }
                    .font(.caption).accessibilityIdentifier("calendar-undo-move")
            }.padding(.horizontal, 16).padding(.top, 8)
        }
    }

    private func moveEvent(_ request: CalendarMoveRequest, to day: Date) {
        guard state.pendingLinkUpdate == nil else { return }
        do {
            guard let move = try service.move(request, to: day) else { return }
            state.lastMove = move
            updateLinks(from: move.before, to: move.after)
        } catch { state.message = error.localizedDescription; service.refresh() }
    }

    private func undoMove(_ move: CalendarEventMove) {
        do {
            let saved = try service.undoMove(move)
            state.lastMove = nil
            updateLinks(from: move.after, to: saved)
        } catch { state.message = error.localizedDescription; service.refresh() }
    }

    private func updateLinks(from original: CalendarEvent, to saved: CalendarEvent) {
        let affected = links.filter { $0.eventIdentifier == original.identifier }
        if !taskService.refreshEventLinks(affected, event: saved) {
            state.pendingLinkUpdate = (affected.map(\.id), saved)
        }
    }

    private func retryLinkUpdate() {
        guard let update = state.pendingLinkUpdate else { return }
        if taskService.refreshEventLinks(links.filter { update.ids.contains($0.id) }, event: update.event) {
            state.pendingLinkUpdate = nil
        }
    }

    private var creationActions: some View {
        VStack(spacing: 10) {
            if service.creationCalendar(preferred: preferences.creationCalendarID) == nil {
                Text(strings["Нет календаря для записи. Выберите другой календарь."]).font(.caption).foregroundStyle(.secondary)
            }
            // Компактные подписи помещаются рядом; системный стиль сам добавляет отступы кнопок.
            HStack(spacing: 10) {
                Button { state.presentation = EventPresentation(day: state.selectedDate) } label: {
                    Label(strings["Событие"], systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: 20)
                }.buttonStyle(.borderedProminent)
                if let selectedTask {
                    Button {
                        state.presentation = EventPresentation(day: state.selectedDate, taskID: selectedTask.id, title: selectedTask.displayTitle(using: strings))
                    } label: {
                        Label(strings["Для задачи"], systemImage: "clock")
                            .frame(maxWidth: .infinity, minHeight: 20)
                    }.buttonStyle(.bordered)
                        .help(strings["Выделить время для задачи"])
                        .accessibilityLabel(strings["Выделить время для задачи"])
                }
            }
            .font(.system(size: 13, weight: .medium))
            .controlSize(.regular)
        }.disabled(service.creationCalendar(preferred: preferences.creationCalendarID) == nil)
            .padding(16)
    }
    private func shiftMonth(_ value: Int) {
        state.month = Calendar.current.date(byAdding: .month, value: value, to: state.month)!
    }
    @MainActor private func reload() async {
        guard isVisible, service.access == .full else { events = []; loading = false; return }
        loading = true; loadError = nil
        await Task.yield()
        guard !Task.isCancelled else { return }
        do {
            let monthRange = CalendarDates.range(of: days), agendaRange = CalendarDates.range(of: agendaDays)
            var loaded = try service.load(monthRange, visibleIDs: preferences.visibleCalendarIDs)
            // Месяц можно листать независимо от расписания: не запрашиваем весь промежуток между ними.
            if agendaRange.start < monthRange.start || agendaRange.end > monthRange.end {
                loaded += try service.load(agendaRange, visibleIDs: preferences.visibleCalendarIDs)
            }
            events = CalendarDates.sorted(Array(Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values))
        } catch { events = []; loadError = error.localizedDescription }
        loading = false
    }
}

struct CalendarAccessView: View {
    @Environment(\.translations) private var strings
    let service: CalendarService
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
            Text(strings["Подключите системные календари, чтобы видеть события и выделять время для задач."])
                .multilineTextAlignment(.center)
            if let error = service.connectionError { Text(strings[error]).font(.caption).foregroundStyle(.red) }
            if service.access == .notDetermined || service.access == .writeOnly {
                Button(strings["Подключить календарь"]) { Task { await service.connect() } }
                    .buttonStyle(.borderedProminent).disabled(service.connecting)
            } else {
                Text(strings["Доступ к календарям отключён. Задачи продолжают работать."]).font(.caption).foregroundStyle(.secondary)
                Button(strings["Открыть системные настройки"]) { service.openPrivacySettings() }
            }
            if service.connecting { ProgressView().controlSize(.small) }
        }
    }
}
