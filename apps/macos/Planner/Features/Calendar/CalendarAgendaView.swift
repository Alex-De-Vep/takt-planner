import AppKit
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let plannerCalendarEvent = UTType(exportedAs: "local.planner.calendar-event", conformingTo: .data)
}

/// Только ссылка и снимок времени; текст события не попадает в буфер перетаскивания.
struct CalendarEventDrag: Codable {
    let request: CalendarMoveRequest
}

struct CalendarAgendaView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let days: [Date]
    let events: [CalendarEvent]
    @Binding var selectedDate: Date
    let layout: CalendarAgendaLayout
    let calendars: [CalendarInfo]
    let links: [TaskEventLink]
    let canMove: Bool
    let openEvent: (CalendarEvent, Date) -> Void
    let openTask: (PlannerTask) -> Void
    let moveEvent: (CalendarMoveRequest, Date) -> Void
    @State private var autoscroll = CalendarAgendaAutoscroll()

    private var horizontal: Bool { layout == .horizontal && days.count > 1 }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(horizontal ? [.horizontal, .vertical] : .vertical) {
                    Group {
                        if horizontal {
                            // Колонки сохраняют читаемую ширину; остальные дни доступны горизонтальной прокруткой.
                            let width = max(220, geometry.size.width / CGFloat(days.count))
                            HStack(alignment: .top, spacing: 0) {
                                ForEach(days, id: \.self) { day in
                                    section(day, minimumHeight: max(60, geometry.size.height))
                                        .frame(width: width)
                                }
                            }
                            .transition(.opacity)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(days, id: \.self) { day in section(day) }
                            }.frame(width: max(0, geometry.size.width - 24))
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, horizontal ? 0 : 12)
                    .animation(PlannerMotion.animation(reduceMotion: reduceMotion), value: horizontal)
                    .background(CalendarAgendaScrollProbe(autoscroll: autoscroll, horizontal: horizontal))
                }
                .accessibilityIdentifier("calendar-agenda-list")
                .onChange(of: days) { if let first = days.first { proxy.scrollTo(first, anchor: .topLeading) } }
                .onChange(of: layout) {
                    autoscroll.stop()
                    if let first = days.first { proxy.scrollTo(first, anchor: .topLeading) }
                }
                .onDisappear { autoscroll.stop() }
            }
        }
    }

    private func section(_ day: Date, minimumHeight: CGFloat = 60) -> some View {
        CalendarAgendaDay(day: day, events: events.filter { CalendarDates.occurs($0, on: day) },
            selected: Calendar.current.isDate(day, inSameDayAs: selectedDate), showsHeading: days.count > 1,
            horizontal: horizontal, minimumHeight: minimumHeight,
            calendars: calendars, links: links, canMove: canMove, autoscroll: autoscroll,
            select: { selectedDate = day }, openEvent: openEvent, openTask: openTask, moveEvent: moveEvent)
            .id(day)
    }
}

private struct CalendarAgendaDay: View {
    @Environment(\.translations) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let day: Date
    let events: [CalendarEvent]
    let selected: Bool
    let showsHeading: Bool
    let horizontal: Bool
    let minimumHeight: CGFloat
    let calendars: [CalendarInfo]
    let links: [TaskEventLink]
    let canMove: Bool
    let autoscroll: CalendarAgendaAutoscroll
    let select: () -> Void
    let openEvent: (CalendarEvent, Date) -> Void
    let openTask: (PlannerTask) -> Void
    let moveEvent: (CalendarMoveRequest, Date) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeading {
                Button(action: select) {
                    HStack {
                        Text(day, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if Calendar.current.isDateInToday(day) { Text(strings["Сегодня"]).font(.caption2) }
                    }.foregroundStyle(selected ? PlannerStyle.accent : .secondary)
                        .contentShape(Rectangle()).padding(.vertical, 10)
                }.buttonStyle(.plain)
                    .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(strings.language.locale)))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("calendar-day-" + LocalDay.key(for: day))
            }
            if events.isEmpty {
                Text(strings[targeted ? "Перенести событие сюда" : "На этот день событий нет"])
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    .padding(.bottom, 6)
            } else {
                ForEach(events) { event in
                    eventRow(event)
                        .transition(.opacity)
                    if event.id != events.last?.id { Divider() }
                }
            }
        }
        .padding(.horizontal, horizontal ? 12 : 4)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
        .background(targeted ? PlannerStyle.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay { if targeted { RoundedRectangle(cornerRadius: 8).strokeBorder(PlannerStyle.accent, lineWidth: 1) } }
        .contentShape(Rectangle())
        .onDrop(of: [.plannerCalendarEvent], delegate: CalendarEventDropDelegate(day: day, enabled: canMove,
            targeted: $targeted, autoscroll: autoscroll, move: moveEvent))
        .overlay(alignment: .bottom) { if showsHeading && !horizontal { Divider() } }
        .overlay(alignment: .trailing) {
            if horizontal { Rectangle().fill(.primary.opacity(0.1)).frame(width: 0.5).allowsHitTesting(false) }
        }
        .animation(PlannerMotion.animation(.feedback, reduceMotion: reduceMotion), value: selected)
        .animation(PlannerMotion.animation(.feedback, reduceMotion: reduceMotion), value: targeted)
        .animation(PlannerMotion.animation(reduceMotion: reduceMotion), value: events.map(\.id))
    }

    @ViewBuilder private func eventRow(_ event: CalendarEvent) -> some View {
        if canMove && event.readOnlyReason == nil {
            rowContent(event)
                .onDrag {
                    let provider = NSItemProvider()
                    let data = try? JSONEncoder().encode(CalendarEventDrag(request: CalendarMoveRequest(event: event, sourceDay: day)))
                    provider.registerDataRepresentation(forTypeIdentifier: UTType.plannerCalendarEvent.identifier,
                                                        visibility: .ownProcess) { completion in
                        completion(data, nil)
                        return nil
                    }
                    return provider
                }
                .contextMenu {
                    Button(strings["Перенести на дату…"]) { openEvent(event, day) }
                }
                .help(strings["Перетащите событие на другой день"])
        } else {
            rowContent(event).help(strings[event.readOnlyReason ?? "Повторите сохранение связи перед следующим переносом."])
        }
    }

    private func rowContent(_ event: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 2).fill(calendarColor(event.calendarID)).frame(width: 3, height: 34)
            eventContent(event)
            if let task = links.first(where: { $0.eventIdentifier == event.identifier })?.task {
                Button { openTask(task) } label: { Image(systemName: "checklist") }
                    .buttonStyle(.plain).foregroundStyle(PlannerStyle.accent)
                    .help(strings["Открыть связанную задачу"])
                    .accessibilityLabel(strings["Открыть связанную задачу"])
            }
        }.padding(.vertical, 10).contentShape(Rectangle())
            .accessibilityElement(children: .contain)
    }

    private func eventContent(_ event: CalendarEvent) -> some View {
        Button { openEvent(event, day) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.system(size: 13, weight: .medium)).lineLimit(3)
                Text(event.allDay ? strings["Весь день"] : eventTime(event))
                    .font(.caption).foregroundStyle(.secondary)
                if event.start < Calendar.current.startOfDay(for: day) {
                    Text(strings["Продолжение события"]).font(.caption2).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityIdentifier("calendar-event-" + event.identifier + "-" + LocalDay.key(for: day))
    }

    private func eventTime(_ event: CalendarEvent) -> String {
        let time = Date.FormatStyle.dateTime.hour().minute().locale(strings.language.locale)
        if Calendar.current.isDate(event.start, inSameDayAs: event.end) {
            return event.start.formatted(time) + " – " + event.end.formatted(time)
        }
        let full = Date.FormatStyle.dateTime.day().month().hour().minute().locale(strings.language.locale)
        return event.start.formatted(full) + " – " + event.end.formatted(full)
    }

    private func calendarColor(_ id: String) -> Color {
        let hex = calendars.first { $0.id == id }?.colorHex ?? "8050C0"
        let value = UInt32(hex, radix: 16) ?? 0x8050C0
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

private struct CalendarEventDropDelegate: DropDelegate {
    let day: Date
    let enabled: Bool
    @Binding var targeted: Bool
    let autoscroll: CalendarAgendaAutoscroll
    let move: (CalendarMoveRequest, Date) -> Void

    func validateDrop(info: DropInfo) -> Bool { enabled && info.hasItemsConforming(to: [.plannerCalendarEvent]) }
    func dropEntered(info: DropInfo) { targeted = true; autoscroll.start() }
    func dropExited(info: DropInfo) { targeted = false; autoscroll.stop() }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: enabled ? .move : .forbidden) }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false; autoscroll.stop()
        guard enabled, let provider = info.itemProviders(for: [.plannerCalendarEvent]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.plannerCalendarEvent.identifier) { data, _ in
            guard let data, let payload = try? JSONDecoder().decode(CalendarEventDrag.self, from: data) else { return }
            Task { @MainActor in move(payload.request, day) }
        }
        return true
    }
}

/// Прокручиваем расписание у края видимой области, включая горизонтальный переход к соседним дням.
@MainActor private final class CalendarAgendaAutoscroll {
    weak var scrollView: NSScrollView?
    var horizontal = false
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil }
    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0, let scrollView, let window = scrollView.window else { stop(); return }
        let clip = scrollView.contentView
        let point = clip.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let rect = clip.bounds
        guard point.x >= rect.minX, point.x <= rect.maxX, point.y >= rect.minY, point.y <= rect.maxY else { return }
        let speedY: CGFloat = point.y < rect.minY + 28 ? -7 : point.y > rect.maxY - 28 ? 7 : 0
        let speedX: CGFloat = horizontal ? (point.x < rect.minX + 28 ? -7 : point.x > rect.maxX - 28 ? 7 : 0) : 0
        guard speedY != 0 || speedX != 0 else { return }
        var next = rect
        next.origin.y += speedY
        next.origin.x += speedX
        clip.scroll(to: clip.constrainBoundsRect(next).origin)
        scrollView.reflectScrolledClipView(clip)
    }
}

private struct CalendarAgendaScrollProbe: NSViewRepresentable {
    let autoscroll: CalendarAgendaAutoscroll
    let horizontal: Bool
    func makeNSView(context: Context) -> Probe {
        autoscroll.horizontal = horizontal
        return Probe(autoscroll: autoscroll)
    }
    func updateNSView(_ view: Probe, context: Context) { autoscroll.horizontal = horizontal; view.connect() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.autoscroll.stop() }

    final class Probe: NSView {
        let autoscroll: CalendarAgendaAutoscroll
        init(autoscroll: CalendarAgendaAutoscroll) { self.autoscroll = autoscroll; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
        func connect() { autoscroll.scrollView = enclosingScrollView }
    }
}
