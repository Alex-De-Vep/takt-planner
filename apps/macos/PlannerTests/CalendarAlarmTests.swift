import EventKit
import Foundation
import Testing
@testable import Planner

/// Настоящие EKAlarm не требуют хранилища событий или доступа к личным календарям.
@MainActor
struct CalendarAlarmTests {
    @Test func readsEveryRelativeAndAbsoluteAlarmWithoutReportingNone() {
        let date = Date(timeIntervalSince1970: 4_100_000_000)
        let alarms = EventKitAlarms.snapshot([EKAlarm(relativeOffset: -900), EKAlarm(absoluteDate: date), EKAlarm(relativeOffset: -3600)])
        #expect(alarms.count == 3 && Set(alarms.map(\.id)).count == 3)
        #expect(alarms[0].relativeOffset == -900 && alarms[1].absoluteDate == date && alarms[2].relativeOffset == -3600)
        let event = CalendarEvent(identifier: "a", calendarID: "work", title: "Встреча", start: date, end: date.addingTimeInterval(3600), alarms: alarms)
        #expect(EventDraft(event: event).alarms == alarms)
    }

    @Test func editingOneAlarmPreservesTheOthersAndTheirActions() throws {
        let date = Date(timeIntervalSince1970: 4_100_000_000)
        let email = EKAlarm(relativeOffset: -86400); email.emailAddress = "person@example.com"
        let current = [EKAlarm(relativeOffset: -900), EKAlarm(absoluteDate: date), email]
        let original = EventKitAlarms.snapshot(current)
        var draft = original; draft[0].relativeOffset = -300
        let result = try EventKitAlarms.updating(current, original: original, draft: draft)
        #expect(result.count == 3 && result[0].relativeOffset == -300)
        #expect(result[1].absoluteDate == date)
        #expect(result[2].type == .email && result[2].emailAddress == "person@example.com")
        #expect(!original[2].editable)
    }

    @Test func canEditAbsoluteDateAndRemoveItWithoutAffectingRelativeAlarm() throws {
        let date = Date(timeIntervalSince1970: 4_100_000_000)
        let current = [EKAlarm(absoluteDate: date), EKAlarm(relativeOffset: -900)]
        let original = EventKitAlarms.snapshot(current)
        var draft = original; draft[0].absoluteDate = date.addingTimeInterval(3600)
        let edited = try EventKitAlarms.updating(current, original: original, draft: draft)
        #expect(edited[0].absoluteDate == date.addingTimeInterval(3600) && edited[1].relativeOffset == -900)
        draft.removeFirst()
        let removed = try EventKitAlarms.updating(current, original: original, draft: draft)
        #expect(removed.count == 1 && removed[0].absoluteDate == nil && removed[0].relativeOffset == -900)
        #expect(try EventKitAlarms.updating(current, original: original, draft: []).isEmpty)
    }

    @Test func unchangedFormPreservesFreshExternalAlarmsButEditedFormRejectsConflict() throws {
        let current = [EKAlarm(relativeOffset: -900)]
        let original = EventKitAlarms.snapshot(current)
        current[0].relativeOffset = -3600
        #expect(try EventKitAlarms.updating(current, original: original, draft: original)[0].relativeOffset == -3600)
        var edited = original; edited[0].relativeOffset = -300
        #expect(throws: CalendarFailure.self) { try EventKitAlarms.updating(current, original: original, draft: edited) }
    }

    @Test func movingEventPreservesAllAlarmsIncludingAbsoluteDate() throws {
        let date = Date(timeIntervalSince1970: 4_100_000_000)
        let alarms = EventKitAlarms.snapshot([EKAlarm(relativeOffset: -900), EKAlarm(absoluteDate: date)])
        let event = CalendarEvent(identifier: "a", calendarID: "work", title: "Встреча", start: date.addingTimeInterval(3600),
                                 end: date.addingTimeInterval(7200), alarms: alarms)
        let store = FakeCalendarStore(); store.values = [event]
        let service = CalendarService(store: store)
        let moved = try #require(try service.move(CalendarMoveRequest(event: event, sourceDay: event.start), to: event.start.addingTimeInterval(86400)))
        #expect(moved.after.alarms == alarms)
        let undone = try service.undoMove(moved)
        #expect(undone.alarms == alarms && undone.start == event.start)
    }

    @Test func createsMultipleAlarmsAndKeepsDuplicateOffsetsSeparate() throws {
        let date = Date(timeIntervalSince1970: 4_100_000_000)
        let draft = [CalendarAlarm(relativeOffset: -900), CalendarAlarm(relativeOffset: -3600), CalendarAlarm(absoluteDate: date)]
        let created = try EventKitAlarms.updating([], original: [], draft: draft)
        #expect(created.count == 3 && created[2].absoluteDate == date)
        let duplicates = [EKAlarm(relativeOffset: -900), EKAlarm(relativeOffset: -900)]
        let original = EventKitAlarms.snapshot(duplicates)
        let removed = try EventKitAlarms.updating(duplicates, original: original, draft: [original[1]])
        #expect(removed.count == 1 && removed[0].relativeOffset == -900)
    }
}
