import Foundation
import SwiftData
import Testing
@testable import Planner

@MainActor
struct CalendarAgendaTests {
    private func calendar(_ zone: String = "Europe/Moscow") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = 2
        return calendar
    }
    private func date(_ day: Int, _ hour: Int = 9, year: Int = 2026, month: Int = 10, calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar()).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private func event(start: Date? = nil) -> CalendarEvent {
        let start = start ?? date(26)
        return CalendarEvent(identifier: "meeting", externalIdentifier: "external-meeting", calendarID: "work",
                             title: "Встреча", start: start, end: start.addingTimeInterval(5400), notes: "Заметки", reminder: -900)
    }

    @Test func rangesCrossMonthsYearsAndRespectFirstWeekday() {
        let cal = calendar(), selected = date(31, year: 2026, month: 12)
        #expect(CalendarAgendaMode.day.days(containing: selected, calendar: cal) == [date(31, 0, year: 2026, month: 12)])
        #expect(CalendarAgendaMode.threeDays.days(containing: selected, calendar: cal) == [
            date(31, 0, year: 2026, month: 12), date(1, 0, year: 2027, month: 1), date(2, 0, year: 2027, month: 1)
        ])
        let week = CalendarAgendaMode.week.days(containing: selected, calendar: cal)
        #expect(week.count == 7 && week.first == date(28, 0, year: 2026, month: 12) && week.last == date(3, 0, year: 2027, month: 1))
        var sunday = cal; sunday.firstWeekday = 1
        #expect(CalendarAgendaMode.week.days(containing: selected, calendar: sunday).first == date(27, 0, year: 2026, month: 12))
    }

    @Test func focusingDayDoesNotShiftThreeDayPeriod() {
        let state = CalendarPanelState(date: date(26)), cal = calendar()
        state.selectedDate = date(28)
        #expect(state.agendaAnchor == date(26))
        state.shiftPeriod(1, mode: .threeDays, calendar: cal)
        #expect(state.agendaAnchor == date(29) && state.selectedDate == date(31))
        state.shiftPeriod(-1, mode: .threeDays, calendar: cal)
        #expect(state.agendaAnchor == date(26) && state.selectedDate == date(28))
        state.select(date(1, year: 2027, month: 1))
        #expect(state.month == state.selectedDate && state.agendaAnchor == state.selectedDate)
    }

    @Test func movePreservesTimeDurationAndFreshMetadata() throws {
        let store = FakeCalendarStore(), original = event()
        var fresh = original; fresh.title = "Обновлённая встреча"; fresh.notes = "Новые заметки"; fresh.reminder = -300
        store.values = [fresh]
        let service = CalendarService(store: store)
        let move = try #require(try service.move(CalendarMoveRequest(event: original, sourceDay: original.start), to: date(28)))
        #expect(move.after.start == date(28) && move.after.end == date(28).addingTimeInterval(5400))
        #expect(move.after.title == fresh.title && move.after.notes == fresh.notes && move.after.reminder == fresh.reminder)
        #expect(move.after.calendarID == original.calendarID && store.values.count == 1 && store.saves == 1)
        #expect(throws: CalendarFailure.self) {
            try service.move(CalendarMoveRequest(event: original, sourceDay: original.start), to: date(28))
        }
        #expect(store.saves == 1)
    }

    @Test func droppingOnSameDayDoesNotWriteOrChangeDuration() throws {
        let store = FakeCalendarStore(), original = event()
        store.values = [original]
        let service = CalendarService(store: store)
        let result = try service.move(CalendarMoveRequest(event: original, sourceDay: original.start), to: original.start)
        #expect(result == nil && store.saves == 0)
    }

    @Test func movingContinuationShiftsWholeEventByDayDifference() throws {
        var original = event(start: date(26, 23))
        original.end = date(28, 2)
        let request = CalendarMoveRequest(event: original, sourceDay: date(27))
        let draft = try request.draft(for: original, to: date(30), calendar: calendar())
        #expect(draft.start == date(29, 23) && draft.end == date(31, 2))
        #expect(throws: CalendarFailure.self) {
            try CalendarMoveRequest(event: original, sourceDay: date(29)).draft(for: original, to: date(30), calendar: calendar())
        }
    }

    @Test func movingAcrossDSTPreservesWallClockAndAllDayCount() throws {
        let cal = calendar("America/New_York")
        let source = date(7, 9, year: 2026, month: 3, calendar: cal)
        let original = event(start: source)
        let target = date(8, 0, year: 2026, month: 3, calendar: cal)
        let draft = try CalendarMoveRequest(event: original, sourceDay: source).draft(for: original, to: target, calendar: cal)
        #expect(cal.component(.hour, from: draft.start) == 9)
        #expect(draft.end.timeIntervalSince(draft.start) == 5400)
        #expect(draft.start.timeIntervalSince(source) == 23 * 3600)

        var allDay = event(start: date(29, 0, year: 2026, month: 10, calendar: cal))
        allDay.allDay = true; allDay.end = date(1, 0, year: 2026, month: 11, calendar: cal)
        let moved = try CalendarMoveRequest(event: allDay, sourceDay: allDay.start)
            .draft(for: allDay, to: date(31, 0, year: 2026, month: 10, calendar: cal), calendar: cal)
        let interval = try moved.interval(calendar: cal)
        #expect(interval.end == date(3, 0, year: 2026, month: 11, calendar: cal))
        #expect(interval.duration == 73 * 3600)
    }

    @Test func missingDSTHourAdvancesWhileKeepingMinutes() throws {
        let cal = calendar("America/New_York")
        let original = event(start: date(7, 2, year: 2026, month: 3, calendar: cal).addingTimeInterval(1800))
        let draft = try CalendarMoveRequest(event: original, sourceDay: original.start)
            .draft(for: original, to: date(8, 0, year: 2026, month: 3, calendar: cal), calendar: cal)
        #expect(cal.component(.hour, from: draft.start) == 3 && cal.component(.minute, from: draft.start) == 30)
        #expect(draft.end.timeIntervalSince(draft.start) == 5400)
    }

    @Test func unavailableReadOnlyRecurringStaleAndRevokedMovesDoNotWrite() {
        let store = FakeCalendarStore(), original = event(), service = CalendarService(store: store)
        let request = CalendarMoveRequest(event: original, sourceDay: original.start)
        #expect(throws: CalendarFailure.self) { try service.move(request, to: date(28)) }
        var locked = original; locked.writable = false; store.values = [locked]
        #expect(throws: CalendarFailure.self) { try service.move(request, to: date(28)) }
        locked = original; locked.recurring = true; store.values = [locked]
        #expect(throws: CalendarFailure.self) { try service.move(request, to: date(28)) }
        locked = original; locked.start = date(27); store.values = [locked]
        #expect(throws: CalendarFailure.self) { try service.move(request, to: date(28)) }
        store.values = [original]; store.access = .denied
        #expect(throws: CalendarFailure.self) { try service.move(request, to: date(28)) }
        #expect(store.saves == 0)
    }

    @Test func failedSaveLeavesOriginalAndDoesNotCreateDuplicate() {
        let store = FakeCalendarStore(), original = event(), service = CalendarService(store: store)
        store.values = [original]; store.failSave = true
        #expect(throws: CalendarFailure.self) {
            try service.move(CalendarMoveRequest(event: original, sourceDay: original.start), to: date(28))
        }
        #expect(store.values == [original] && store.saves == 0)
    }

    @Test func undoRestoresTimesAndPreservesLaterMetadataButRejectsLaterTimeChanges() throws {
        let store = FakeCalendarStore(), original = event(), service = CalendarService(store: store)
        store.values = [original]
        let move = try #require(try service.move(CalendarMoveRequest(event: original, sourceDay: original.start), to: date(28)))
        store.values[0].notes = "После переноса"
        let restored = try service.undoMove(move)
        #expect(restored.start == original.start && restored.end == original.end && restored.notes == "После переноса")
        let again = try #require(try service.move(CalendarMoveRequest(event: restored, sourceDay: restored.start), to: date(29)))
        store.values[0].end = store.values[0].end.addingTimeInterval(600)
        #expect(throws: CalendarFailure.self) { try service.undoMove(again) }
        #expect(store.saves == 3)
    }

    @Test func linkRetryAfterChangedIdentifierDoesNotMoveEventTwice() throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        var fail = false
        let taskService = TaskService(context: container.mainContext, saveContext: { context in
            if fail { throw CalendarFailure(message: "Ошибка связи") }
            try context.save()
        })
        let task = try #require(taskService.createTask(in: .inbox, folders: []))
        let store = FakeCalendarStore(), original = event(), service = CalendarService(store: store)
        store.values = [original]; store.replacementIdentifier = "moved-meeting"
        #expect(taskService.link(original, to: task))
        let links = try container.mainContext.fetch(FetchDescriptor<TaskEventLink>())
        let move = try #require(try service.move(CalendarMoveRequest(event: original, sourceDay: original.start), to: date(28)))
        fail = true
        #expect(!taskService.refreshEventLinks(links, event: move.after))
        #expect(links[0].eventIdentifier == original.identifier)
        fail = false
        #expect(taskService.refreshEventLinks(links, event: move.after))
        #expect(links[0].eventIdentifier == "moved-meeting" && links[0].lastStart == date(28))
        #expect(links[0].task?.id == task.id && store.saves == 1 && store.values.count == 1)
    }
}
