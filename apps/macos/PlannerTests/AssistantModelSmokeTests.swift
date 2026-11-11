import Foundation
import Testing
import MLX
import Darwin
@testable import Planner

/// Запускается отдельно только с явным PLANNER_AI_SMOKE=1. Использует исключительно вымышленные запросы.
struct AssistantModelSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PLANNER_AI_SMOKE"] == "1"))
    func localModelCreatesRussianPlans() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: ProcessInfo.processInfo.environment["PLANNER_AI_VARIANT"] == "4" ? ".build/ModelCache4" : ".build/ModelCache")
        let backend = MLXAssistantBackend()
        let probe = ProcessFootprintProbe()
        let sampling = Task.detached {
            while !Task.isCancelled {
                await probe.record(processFootprint())
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
        defer { sampling.cancel() }
        let baseline = memory("before-load")
        Memory.peakMemory = 0
        let loadStarted = Date.now
        try await backend.prepare(directory: directory)
        print("AI TIMING load-seconds: \(Date.now.timeIntervalSince(loadStarted))")
        let loaded = memory("loaded")
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
            await backend.releaseTransientMemory()
            _ = memory("response-\(index)-trimmed")
            print("AI SMOKE \(index): \(response)")
            let decoded = AssistantResponsePolicy.normalize(try ActionPlanValidator.decode(response), thread: thread, context: context)
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
        let englishResponse = AssistantResponsePolicy.normalize(try ActionPlanValidator.decode(englishOutput), thread: thread, context: english)
        #expect(englishResponse.actions?.contains { $0.kind == .task && $0.folderID == "inbox" && ($0.checklist?.count ?? 0) == 2 && $0.date == nil } == true)
        var folderThread = AssistantThread()
        folderThread.messages = [.init(role: .user, text: "Создай задачу Проверить архив в папке Учёба, без срока.")]
        let folderOutput = try await backend.respond(instructions: AssistantPrompt.instructions, prompt: AssistantPrompt.request(context: context, thread: folderThread))
        let unresolved = AssistantResponsePolicy.normalize(try ActionPlanValidator.decode(folderOutput), thread: folderThread, context: context)
        #expect(unresolved.questions?.isEmpty == false)
        folderThread.messages.append(.init(role: .assistant, text: unresolved.message, questions: unresolved.questions ?? []))
        folderThread.actions = (unresolved.actions ?? []).map { AssistantAction(proposal: $0, context: context) }
        folderThread.messages.append(.init(role: .user, text: "На неделе"))
        let resolvedOutput = try await backend.respond(instructions: AssistantPrompt.instructions, prompt: AssistantPrompt.request(context: context, thread: folderThread))
        let resolved = AssistantResponsePolicy.normalize(try ActionPlanValidator.decode(resolvedOutput), thread: folderThread, context: context)
        #expect(resolved.actions?.first?.folderID == "week" && resolved.questions?.isEmpty != false)
        print("AI FOLDER FOLLOWUP: \(resolvedOutput)")
        // Более длинная переписка проверяется отдельно от коротких команд: контекст увеличивает пик.
        var longThread = AssistantThread()
        for index in 0..<6 {
            longThread.messages.append(AssistantMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                text: String(repeating: "Обсуждаем проект сайта: дизайн, тексты, согласование макетов и проверку ссылок. ", count: 8)))
        }
        longThread.messages.append(AssistantMessage(role: .user, text: "Создай только одну новую задачу Проверить сайт во Входящих, без срока."))
        _ = try await backend.respond(instructions: AssistantPrompt.instructions, prompt: AssistantPrompt.request(context: context, thread: longThread))
        await backend.releaseTransientMemory()
        _ = memory("long-context-trimmed")
        await backend.unload()
        let freed = memory("unloaded")
        try await Task.sleep(for: .milliseconds(300))
        _ = memory("unloaded-settled")
        #expect(freed.activeMemory < baseline.activeMemory + 16 * 1024 * 1024)
        #expect(loaded.activeMemory > freed.activeMemory)
        let reloadStarted = Date.now
        try await backend.prepare(directory: directory)
        print("AI TIMING reload-seconds: \(Date.now.timeIntervalSince(reloadStarted))")
        _ = memory("reloaded")
        await backend.unload()
        _ = memory("unloaded-again")
        print("AI MEMORY sampled-peak-footprint: \(await probe.peak)")
    }
    /// Метрики MLX и всего тестового процесса различаются: CPU-объекты не входят в activeMemory.
    private func memory(_ phase: String) -> Memory.Snapshot {
        let snapshot = Memory.snapshot()
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("AI MEMORY \(phase): active=\(snapshot.activeMemory) cache=\(snapshot.cacheMemory) peak-active=\(snapshot.peakMemory) footprint=\(processFootprint()) peak-rss=\(usage.ru_maxrss) physical=\(ProcessInfo.processInfo.physicalMemory)")
        return snapshot
    }
}

/// Физический footprint включает Metal, в отличие от обычного RSS процесса.
private func processFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let capacity = Int(count)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
}
private actor ProcessFootprintProbe {
    var peak: UInt64 = 0
    func record(_ value: UInt64) { peak = max(peak, value) }
}
