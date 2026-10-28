import Foundation
import Testing
@testable import Planner

/// Запускается отдельно только с явным PLANNER_AI_SMOKE=1. Использует исключительно вымышленные запросы.
struct AssistantModelSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PLANNER_AI_SMOKE"] == "1"))
    func localModelCreatesRussianPlans() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: ProcessInfo.processInfo.environment["PLANNER_AI_VARIANT"] == "4" ? ".build/ModelCache4" : ".build/ModelCache")
        let backend = MLXAssistantBackend()
        try await backend.prepare(directory: directory)
        let context = AssistantContext(now: ISO8601DateFormatter().date(from: "2026-10-28T09:00:00Z")!, timeZoneID: "Europe/Moscow", language: "ru",
            folders: [AssistantFolder(id: "inbox", name: "Входящие"), AssistantFolder(id: "week", name: "На неделе")],
            calendars: [AssistantCalendar(id: "work", name: "Работа")], defaultFolderID: "inbox", defaultCalendarID: "work",
            taskID: nil, taskTitle: nil, durationMinutes: 60, reminderMinutes: nil)
        let samples = [
            "Нужна задача Обновить портфолио в папке Входящие. Два пункта выполнения: выбрать работы; написать описания.",
            "Поставь в календарь Звонок с Анной на 2 ноября 2026 с 11:00 до 11:45. Уведомление за 15 минут.",
            "Завтра надо обсудить запуск. Запланируй встречу."
        ]
        for (index, sample) in samples.enumerated() {
            var thread = AssistantThread(); thread.messages = [AssistantMessage(role: .user, text: sample)]
            let response = try await backend.respond(instructions: AssistantPrompt.instructions, prompt: AssistantPrompt.request(context: context, thread: thread))
            print("AI SMOKE \(index): \(response)")
            let decoded = try ActionPlanValidator.decode(response)
            if index == 0 { #expect(decoded.actions?.contains { $0.kind == .task && $0.folderID == "inbox" && ($0.checklist?.count ?? 0) >= 2 } == true) }
            if index == 1 {
                let event = try #require(decoded.actions?.first { $0.kind == .event })
                #expect(event.date == "2026-11-02" && event.time == "11:00" && event.reminderMinutes == 15)
                let interval = try ActionPlanValidator.eventDraft(AssistantAction(proposal: event, context: context)).interval()
                #expect(interval.duration == 45 * 60)
            }
            if index == 2 {
                #expect(decoded.questions?.isEmpty == false)
                thread.messages.append(AssistantMessage(role: .assistant, text: decoded.message, questions: decoded.questions ?? []))
                thread.actions = (decoded.actions ?? []).map { AssistantAction(proposal: $0, context: context) }
                thread.messages.append(AssistantMessage(role: .user, text: "В 16:30 на двадцать минут."))
                let followup = try await backend.respond(instructions: AssistantPrompt.instructions, prompt: AssistantPrompt.request(context: context, thread: thread))
                print("AI FOLLOWUP: \(followup)")
                let updated = AssistantResponsePolicy.normalize(try ActionPlanValidator.decode(followup), thread: thread, context: context)
                #expect(updated.actions?.contains { $0.kind == .event && $0.date == "2026-10-29" && $0.time == "16:30" && $0.durationMinutes == 20 && $0.reminderMinutes == nil } == true)
            }
        }
        var english = context; english.language = "en"
        var thread = AssistantThread()
        thread.messages = [AssistantMessage(role: .user, text: "Create a task called Write release notes in Inbox with two subtasks: draft the summary and check the links. No due date.")]
        let englishOutput = try await backend.respond(instructions: AssistantPrompt.instructions, prompt: AssistantPrompt.request(context: english, thread: thread))
        print("AI ENGLISH: \(englishOutput)")
        let englishResponse = try ActionPlanValidator.decode(englishOutput)
        #expect(englishResponse.actions?.contains { $0.kind == .task && $0.folderID == "inbox" && ($0.checklist?.count ?? 0) == 2 && $0.date == nil } == true)
        await backend.unload()
    }
}
