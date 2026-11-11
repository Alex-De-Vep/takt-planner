import Foundation
import Testing
@testable import Planner

struct AssistantEventTimePolicyTests {
    private var context: AssistantContext {
        .init(now: .now, timeZoneID: "Europe/Moscow", language: "ru", folders: [], calendars: [], defaultFolderID: "inbox", defaultCalendarID: "work", taskID: nil, taskTitle: nil, durationMinutes: 60, reminderMinutes: nil)
    }
    private var proposal: AssistantProposal { .init(key: "event1", kind: .event, title: "Встреча", date: "2026-11-02", time: "00:00", durationMinutes: 30, calendarID: "work") }
    @Test func missingTimeNeverBecomesMidnightOrAllDay() {
        var p = proposal; p.allDay = true
        let result = AssistantEventTimePolicy.resolve(p, text: "Запланируй встречу на завтра", old: nil, context: context)
        #expect(result.needsTime && result.proposal.time == nil && result.proposal.allDay != true)
    }
    @Test func explicitMidnightAndAllDayRemainValid() {
        #expect(AssistantEventTimePolicy.resolve(proposal, text: "Встреча в полночь", old: nil, context: context).proposal.time == "00:00")
        #expect(AssistantEventTimePolicy.resolve(proposal, text: "Встреча на весь день", old: nil, context: context).proposal.allDay == true)
    }
    @Test func timeAndDurationOverrideConfusedReminderOutput() {
        let result = AssistantEventTimePolicy.resolve(proposal, text: "В 16:30 на двадцать минут", old: nil, context: context)
        #expect(result.proposal.time == "16:30" && result.proposal.durationMinutes == 20)
    }
    @Test func rangeAndCrossMidnightAreCalculatedFromExplicitClocks() {
        #expect(AssistantEventTimePolicy.resolve(proposal, text: "С 11:00 до 11:45", old: nil, context: context).proposal.durationMinutes == 45)
        #expect(AssistantEventTimePolicy.resolve(proposal, text: "С 23:30 до 01:00", old: nil, context: context).proposal.durationMinutes == 90)
    }
    @Test func datesAndReminderNumbersAreNotTimeOrDuration() {
        #expect(AssistantEventTimePolicy.clocks("2.11.2026, напомни за 15 минут").isEmpty)
        #expect(AssistantEventTimePolicy.duration("Напомни за 15 минут") == nil)
        #expect(AssistantEventTimePolicy.duration("for 2 hours") == 120)
        #expect(AssistantEventTimePolicy.duration("a 35-minute call") == 35)
    }
    @Test func correctionWithoutTimeKeepsExistingTimeAndDuration() {
        var old = proposal; old.time = "14:20"; old.durationMinutes = 45
        let result = AssistantEventTimePolicy.resolve(proposal, text: "Переименуй встречу", old: old, context: context)
        #expect(!result.needsTime && result.proposal.time == "14:20" && result.proposal.durationMinutes == 45)
    }
    @Test func dateOnlyAndVagueMorningRequireClarification() {
        #expect(AssistantEventTimePolicy.resolve(proposal, text: "Завтра утром", old: nil, context: context).needsTime)
        #expect(AssistantEventTimePolicy.resolve(proposal, text: "30 октября 2026", old: nil, context: context).needsTime)
    }
    @Test func mixedClockFormatsAreOrderedAndReminderTimeDoesNotReplaceStart() {
        #expect(AssistantEventTimePolicy.clocks("с 9 до 10:30") == ["09:00", "10:30"])
        #expect(AssistantEventTimePolicy.resolve(proposal, text: "с 9 до 10:30", old: nil, context: context).proposal.durationMinutes == 90)
        #expect(AssistantEventTimePolicy.clocks("на 00:30 в 15:00") == ["15:00"])
        #expect(AssistantEventTimePolicy.duration("for two hours") == 120)
        #expect(AssistantEventTimePolicy.duration("займёт двадцать пять минут") == 25)
    }
    @Test func explicitMultiDayIntervalAndBareDurationArePreserved() {
        var p = proposal; p.endDate = "2026-11-04"; p.endTime = "15:00"
        let resolved = AssistantEventTimePolicy.resolve(p, text: "С 2 ноября в 11:00 до 4 ноября в 15:00", old: nil, context: context)
        #expect(resolved.proposal.durationMinutes == 52 * 60)
        #expect(AssistantEventTimePolicy.duration("Выдели 25 минут для задачи") == 25)
        #expect(AssistantEventTimePolicy.duration("Встреча будет идти 20 минут") == 20)
        #expect(AssistantEventTimePolicy.duration("Напомни за 20 минут") == nil)
        #expect(AssistantEventTimePolicy.duration("через 20 минут") == nil)
    }
    @Test func explicitRangeAcrossDSTUsesElapsedTimeInSelectedZone() {
        var p = proposal; p.date = "2026-10-25"
        var c = context; c.timeZoneID = "Europe/Berlin"
        let result = AssistantEventTimePolicy.resolve(p, text: "С 01:00 до 03:00", old: nil, context: c)
        #expect(result.proposal.durationMinutes == 180)
    }
    @Test func defaultDurationBelongsToApplication() {
        var c = context; c.durationMinutes = 45
        #expect(AssistantEventTimePolicy.resolve(proposal, text: "В 15:00", old: nil, context: c).proposal.durationMinutes == 45)
        #expect(AssistantEventTimePolicy.clocks("в 9 вечера") == ["21:00"])
    }
}
