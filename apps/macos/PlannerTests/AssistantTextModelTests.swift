import Foundation
import Testing
import MLX
import Darwin
@testable import Planner

/// Opt-in проверка закреплённой модели на вымышленном тексте, без доступа к библиотеке и EventKit.
struct AssistantTextModelTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PLANNER_AI_TEXT_SMOKE"] == "1"))
    func rewritesRussianAndEnglishText() async throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let backend = MLXAssistantBackend()
        let beforeLoad = footprint()
        let started = Date.now
        try await backend.prepare(directory: root.appending(path: ".build/ModelCache4"))
        print("TEXT MODEL loadSeconds=\(Date.now.timeIntervalSince(started)) footprint=\(footprint()) baseline=\(beforeLoad)")
        let original = AssistantTextSnapshot(id: UUID(), title: "Подготовить презентацию проекта", description: "Рассказать о проекте.",
            checklist: [.init(id: UUID(), title: "Собрать материалы", isCompleted: true)])
        let cases: [(String, String, AssistantTextEdit.Target)] = [
            ("Распиши описание задачи немного подробнее: цель, основные шаги и ожидаемый результат. Название не меняй и подзадачи не добавляй.", "ru", .savedTask),
            ("Предложи три новые подзадачи для выполнения задачи. Уже существующие не повторяй. Название и описание не меняй.", "ru", .savedTask),
            ("Rephrase only the task title in English. Do not change the description or subtasks.", "en", .savedTask),
            ("Улучши описание, сделай его понятным и структурированным. Название и подзадачи не меняй.", "ru", .proposal)
        ]
        for (index, sample) in cases.enumerated() {
            var edit = AssistantTextEdit(target: sample.2, before: original)
            var thread = AssistantThread(); thread.messages = [.init(role: .user, text: sample.0)]
            let prompt = try AssistantTextPrompt.request(edit: edit, thread: thread, language: sample.1)
            Memory.peakMemory = 0
            let started = Date.now
            let output = try await backend.respond(instructions: AssistantTextPrompt.instructions, prompt: prompt)
            let elapsed = Date.now.timeIntervalSince(started)
            print("TEXT MODEL case=\(index) seconds=\(elapsed) activePeak=\(Memory.peakMemory) footprint=\(footprint()) output=\(output)")
            let response = try ActionPlanValidator.decode(output)
            #expect(response.questions?.isEmpty != false && response.actions?.isEmpty != false)
            let change = try #require(response.textEdit)
            try edit.propose(change)
            if index == 0 || index == 3 {
                #expect((change.description?.count ?? 0) > original.description.count)
                #expect(change.title == nil || change.title == original.title)
                #expect(change.checklist?.isEmpty != false)
                #expect(change.description?.contains("\n") == true)
            }
            if index == 1 { #expect(edit.additions.count >= 2 && !edit.additions.contains { $0.title == "Собрать материалы" }) }
            if index == 2 { #expect(change.title != nil && change.title != original.title && change.description == nil) }
            if index == 0 {
                // Повторная генерация видит принятый пользователем текст, не обрезанный исходник.
                edit.change.description = (change.description ?? "") + "\nСохранить исходные материалы."
                thread.messages += [.init(role: .assistant, text: "Проверьте предложение"), .init(role: .user, text: "Сократи описание до двух предложений, сохрани смысл. Название не меняй.")]
                let refined = try await backend.respond(instructions: AssistantTextPrompt.instructions,
                    prompt: AssistantTextPrompt.request(edit: edit, thread: thread, language: "ru"))
                print("TEXT MODEL followup=\(refined)")
                let next = try #require(try ActionPlanValidator.decode(refined).textEdit)
                #expect(next.description != nil)
            }
            await backend.releaseTransientMemory()
        }
        let createContext = AssistantContext(now: .now, timeZoneID: "Europe/Moscow", language: "ru", folders: [.init(id: "inbox", name: "Входящие")], calendars: [], defaultFolderID: "inbox", durationMinutes: 60)
        var createThread = AssistantThread()
        createThread.messages = [.init(role: .user, text: "Создай новую задачу «Подготовить презентацию проекта» во Входящих и распиши её описание: цель, основные шаги, результат. Без срока и без подзадач.")]
        let createOutput = try await backend.respond(instructions: AssistantPrompt.instructions, prompt: AssistantPrompt.request(context: createContext, thread: createThread))
        print("TEXT MODEL new-draft=\(createOutput)")
        let creation = AssistantResponsePolicy.normalize(try ActionPlanValidator.decode(createOutput), thread: createThread, context: createContext)
        let proposal = try #require(creation.actions?.first)
        #expect(proposal.kind == .task && proposal.folderID == "inbox" && (proposal.description?.count ?? 0) > 40)
        #expect(proposal.date == nil && proposal.checklist?.isEmpty != false)
        await backend.unload()
        print("TEXT MODEL unloaded active=\(Memory.activeMemory) footprint=\(footprint())")
        #expect(Memory.activeMemory < 16 * 1024 * 1024)
    }
    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { ptr in ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        } }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
