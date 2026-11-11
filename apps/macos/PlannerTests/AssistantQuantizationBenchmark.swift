import Foundation
import SwiftData
import Testing
import MLX
import Darwin
@testable import Planner

/// Отдельный opt-in эксперимент. Ошибки модели записываются в отчёт, а не прерывают сравнение.
@MainActor struct AssistantQuantizationBenchmark {
    private let workFolder = "11111111-1111-4111-8111-111111111111"
    private let homeFolder = "22222222-2222-4222-8222-222222222222"
    private let selectedTask = "33333333-3333-4333-8333-333333333333"
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private var sourceLab: URL { root.appending(path: ".build/QuantizationBenchmark") }
    private var lab: URL {
        FileManager.default.temporaryDirectory.appending(path: "PlannerQuantizationBenchmark-" + (ProcessInfo.processInfo.environment["PLANNER_QUANT_RUN"] ?? "manual"))
    }

    struct Fixture: Codable {
        let id: String
        var context: AssistantContext
        var thread: AssistantThread
        var prompt: String
    }
    struct Record: Codable {
        let id: String
        let seconds: Double
        let raw: String
        let normalized: AssistantResponse?
        let issues: [String]
        let activePeak: Int
        let physicalPeak: UInt64
        let residentAfterTrim: UInt64
        let tasksCreated: Int
        let eventsCreated: Int
    }
    struct Report: Codable {
        let bits: String
        let revision: String
        let startedAt: Date
        let physicalRAM: UInt64
        let os: String
        let beforeLoad: UInt64
        let loadedFootprint: UInt64
        let loadedActive: Int
        let loadSeconds: Double
        let reloadSeconds: Double
        let unloadedFootprint: UInt64
        let unloadedActive: Int
        let records: [Record]
    }
    @Test(.enabled(if: ["3", "4"].contains(ProcessInfo.processInfo.environment["PLANNER_QUANT_BENCHMARK"] ?? "")))
    func comparePinnedModel() async throws {
        let bits = ProcessInfo.processInfo.environment["PLANNER_QUANT_BENCHMARK"]!
        let directory = bits == "3" ? sourceLab.appending(path: "Models/3bit") : root.appending(path: ".build/ModelCache4")
        let manifestURL = bits == "3" ? sourceLab.appending(path: "ModelManifest-3bit.json") : root.appending(path: "Planner/Assistant/ModelManifest.json")
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: manifestURL))
        let startedAt = Date.now
        try FileManager.default.createDirectory(at: lab, withIntermediateDirectories: true)
        print("QUANT OUTPUT_DIR " + lab.path)
        let fixturesURL = lab.appending(path: "fixtures.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let fixtures: [Fixture]
        if ProcessInfo.processInfo.environment["PLANNER_RELIABILITY"] == "1" {
            let baseline = root.appending(path: "Experiments/QuantizationBenchmark/results/fixtures.json")
            let originals = try decoder.decode([Fixture].self, from: Data(contentsOf: baseline))
            fixtures = try (originals + heldOutFixtures(context: originals[0].context)).map { original in
                var fixture = original
                fixture.prompt = try AssistantPrompt.request(context: fixture.context, thread: fixture.thread)
                return fixture
            }
            try encoder.encode(fixtures).write(to: fixturesURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: fixturesURL.path) {
            fixtures = try decoder.decode([Fixture].self, from: Data(contentsOf: fixturesURL))
        } else {
            fixtures = try makeFixtures()
            try encoder.encode(fixtures).write(to: fixturesURL, options: .atomic)
        }
        #expect(fixtures.count == (ProcessInfo.processInfo.environment["PLANNER_RELIABILITY"] == "1" ? 26 : 18))
        let beforeLoad = quantFootprint()
        let backend = MLXAssistantBackend()
        var started = Date.now
        try await backend.prepare(directory: directory)
        let loadSeconds = Date.now.timeIntervalSince(started)
        let loadedFootprint = quantFootprint(), loadedActive = Memory.activeMemory
        print("QUANT LOAD bits=\(bits) seconds=\(loadSeconds) active=\(loadedActive) footprint=\(loadedFootprint)")
        let probe = QuantProbe()
        let sampling = Task.detached {
            while !Task.isCancelled {
                await probe.record(quantFootprint())
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
        defer { sampling.cancel() }
        var records: [Record] = []
        for fixture in fixtures {
            await probe.reset(quantFootprint()); Memory.peakMemory = 0
            started = .now
            var raw = "", response: AssistantResponse?, issues: [String] = []
            do {
                raw = try await backend.respond(instructions: AssistantPrompt.instructions, prompt: fixture.prompt)
            } catch { issues.append("Ошибка генерации: " + error.localizedDescription) }
            let seconds = Date.now.timeIntervalSince(started)
            let activePeak = Memory.peakMemory, physicalPeak = await probe.peak
            await backend.releaseTransientMemory()
            let resident = quantFootprint()
            if issues.isEmpty {
                do {
                    response = AssistantResponsePolicy.normalize(try ActionPlanValidator.decode(raw), thread: fixture.thread, context: fixture.context)
                    issues += assess(response!, fixture: fixture)
                } catch { issues.append("Невалидный JSON: " + error.localizedDescription) }
            }
            var created = (tasks: 0, events: 0)
            if let response {
                do { created = try await checkCreation(response, fixture: fixture) }
                catch { issues.append("Ошибка локального создания: " + error.localizedDescription) }
            }
            let record = Record(id: fixture.id, seconds: seconds, raw: raw, normalized: response, issues: issues,
                activePeak: activePeak, physicalPeak: physicalPeak, residentAfterTrim: resident,
                tasksCreated: created.tasks, eventsCreated: created.events)
            records.append(record)
            print("QUANT CASE bits=\(bits) id=\(fixture.id) seconds=\(seconds) peak=\(physicalPeak) issues=\(issues)")
            // Промежуточный журнал переживает ошибку следующего запроса или прерывание эксперимента.
            try encoder.encode(records).write(to: lab.appending(path: "partial-\(bits).json"), options: .atomic)
        }
        await backend.unload()
        try await Task.sleep(for: .milliseconds(300))
        let unloadedFootprint = quantFootprint(), unloadedActive = Memory.activeMemory
        started = .now
        try await backend.prepare(directory: directory)
        let reloadSeconds = Date.now.timeIntervalSince(started)
        await backend.unload()
        let report = Report(bits: bits, revision: manifest.revision, startedAt: startedAt,
            physicalRAM: ProcessInfo.processInfo.physicalMemory, os: ProcessInfo.processInfo.operatingSystemVersionString,
            beforeLoad: beforeLoad, loadedFootprint: loadedFootprint, loadedActive: loadedActive, loadSeconds: loadSeconds,
            reloadSeconds: reloadSeconds, unloadedFootprint: unloadedFootprint, unloadedActive: unloadedActive, records: records)
        let result = lab.appending(path: "Results/\(bits)bit-\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: result, options: .atomic)
        print("QUANT RESULT " + result.path)
        print("QUANT SUMMARY bits=\(bits) passed=\(records.filter { $0.issues.isEmpty }.count)/\(records.count) unloadedActive=\(unloadedActive)")
        #expect(records.count == fixtures.count)
        #expect(unloadedActive < 16 * 1024 * 1024)
    }

    private func makeFixtures() throws -> [Fixture] {
        let base = AssistantContext(now: ISO8601DateFormatter().date(from: "2026-10-29T09:00:00Z")!, timeZoneID: "Europe/Moscow", language: "ru",
            folders: [AssistantFolder(id: "inbox", name: "Входящие"), AssistantFolder(id: "week", name: "На неделе"),
                AssistantFolder(id: "month", name: "Месяц"), AssistantFolder(id: workFolder, name: "Работа"), AssistantFolder(id: homeFolder, name: "Личное")],
            calendars: [AssistantCalendar(id: "work", name: "Работа"), AssistantCalendar(id: "home", name: "Личное")],
            defaultFolderID: "inbox", defaultCalendarID: "work", taskID: nil, taskTitle: nil, durationMinutes: 60, reminderMinutes: nil)
        let samples = [
            ("simple-task", "Добавь задачу Полить цветы. Без срока."),
            ("folder-checklist", "Создай в папке Работа задачу Подготовить отчёт. Три подзадачи: собрать данные; построить графики; проверить выводы. Без срока."),
            ("today-folder", "Создай в папке Личное задачу Купить продукты и отметь её На сегодня. Срок не нужен."),
            ("task-deadline", "Добавь в папку На неделе задачу Отправить договор, срок 30 октября 2026 в 18:15."),
            ("multiple-folders", "Создай три отдельные задачи без сроков: Ответить клиенту в папке Работа; Купить хлеб в папке Личное; Прочитать письмо во Входящих."),
            ("event-explicit", "Создай событие Звонок с Анной 2 ноября 2026 с 11:00 до 11:45 в календаре Работа. Напомни за 15 минут."),
            ("event-midnight", "Создай событие Проверка сервера 2 ноября 2026 в 23:30 на 90 минут в календаре Работа, без напоминания."),
            ("event-all-day", "Добавь в календарь Личное событие Выходной 4 ноября 2026 на весь день. Без напоминания."),
            ("event-needs-time", "Запланируй встречу Обсудить запуск на завтра в календаре Работа. Время я пока не указал."),
            ("event-followup", "В 16:30 на двадцать минут, без напоминания."),
            ("unknown-folder", "Добавь задачу Прочитать главу в папку Учёба, без срока."),
            ("selected-task-event", "Выдели для открытой задачи время 30 октября 2026 в 15:00 на 25 минут в календаре Работа. Напомни за 5 минут."),
            ("new-task-event", "Создай задачу Написать статью в папке Работа, без срока. И выдели время именно для этой новой задачи: 31 октября 2026 в 10:00 на 30 минут в календаре Работа, без напоминания."),
            ("default-folder", "Создай задачу Забрать посылку, без срока."),
            ("english-task", "Create a task called Write release notes in Inbox with two subtasks: draft the summary and check the links. No due date."),
            ("default-reminder", "Создай событие Планёрка 30 октября 2026 в 09:00 на 30 минут в календаре Работа."),
            ("long-context", "Создай только одну новую задачу Проверить ссылки во Входящих, без срока. Ничего из прежнего обсуждения создавать не нужно."),
            ("correct-proposal", "Исправь предложение: назови задачу Купить билеты и перенеси в папку Личное. Срок по-прежнему не нужен.")
        ]
        return try samples.map { id, text in
            var context = base, thread = AssistantThread()
            if id == "selected-task-event" { context.taskID = selectedTask; context.taskTitle = "Проверить релиз" }
            if id == "default-folder" { context.defaultFolderID = homeFolder }
            if id == "english-task" { context.language = "en" }
            if id == "default-reminder" { context.reminderMinutes = 15 }
            if id == "event-followup" {
                let p = AssistantProposal(key: "event1", kind: .event, title: "Обсудить запуск", date: "2026-10-30", durationMinutes: 60, calendarID: "work")
                let q = [AssistantQuestion(text: "Во сколько 30 октября?", options: ["09:00", "12:00", "15:00", "Весь день"])]
                thread.messages = [AssistantMessage(role: .user, text: "Запланируй встречу Обсудить запуск на завтра."), AssistantMessage(role: .assistant, text: "Уточните время.", questions: q)]
                thread.actions = [AssistantAction(proposal: p, context: context)]
            }
            if id == "correct-proposal" {
                let p = AssistantProposal(key: "task1", kind: .task, title: "Купить книгу", folderID: "inbox")
                thread.actions = [AssistantAction(proposal: p, context: context)]
                thread.messages = [AssistantMessage(role: .user, text: "Создай задачу Купить книгу без срока."), AssistantMessage(role: .assistant, text: "Проверьте предложение.")]
            }
            if id == "long-context" {
                for n in 0..<6 {
                    thread.messages.append(AssistantMessage(role: n.isMultiple(of: 2) ? .user : .assistant,
                        text: String(repeating: "Обсуждаем проект сайта: дизайн, тексты, согласование макетов и проверку ссылок. ", count: 8)))
                }
            }
            thread.messages.append(AssistantMessage(role: .user, text: text))
            return Fixture(id: id, context: context, thread: thread, prompt: try AssistantPrompt.request(context: context, thread: thread))
        }
    }
    /// Новые формулировки отделены от исходных 18 примеров и проверяют отсутствие узкой подгонки.
    private func heldOutFixtures(context base: AssistantContext) throws -> [Fixture] {
        let messages = [
            ("heldout-default", "Нужна задача Сверить остатки. Без срока."),
            ("heldout-quoted-folder", "В папку «Работа» добавь задачу Проверить доступы без срока."),
            ("heldout-literal-title", "Создай задачу «Отметить на сегодня», без срока. Это именно название задачи."),
            ("heldout-star-deadline", "Добавь задачу Проверить подписи, срок 5 ноября 2026 в 17:20. Отметь На сегодня."),
            ("heldout-unknown-folder", "Создай задачу Проверить камеру в папке «Поездка», без срока."),
            ("heldout-standalone", "Создай самостоятельное событие Обед 6 ноября 2026 в 13:00 на 40 минут в календаре Личное, без напоминания."),
            ("heldout-unknown-calendar", "Создай событие Поездка 6 ноября 2026 в 10:00 на час в календаре «Праздники»."),
            ("heldout-english-event", "Schedule a 35-minute call with Alex on November 7, 2026 at 14:10 in Personal calendar. No reminder.")
        ]
        return messages.map { id, message in
            var c = base
            if id == "heldout-default" { c.defaultFolderID = homeFolder }
            if id == "heldout-standalone" { c.taskID = selectedTask; c.taskTitle = "Проверить релиз" }
            if id == "heldout-english-event" {
                c.language = "en"; c.calendars = [.init(id: "work", name: "Work"), .init(id: "home", name: "Personal")]
            }
            var t = AssistantThread(); t.messages = [.init(role: .user, text: message)]
            return Fixture(id: id, context: c, thread: t, prompt: "")
        }
    }
    private func assess(_ response: AssistantResponse, fixture: Fixture) -> [String] {
        let actions = response.actions ?? [], tasks = actions.filter { $0.kind == .task }, events = actions.filter { $0.kind == .event }
        let questions = response.questions ?? []
        var issues: [String] = []
        func check(_ ok: Bool, _ label: String) { if !ok { issues.append(label) } }
        func has(_ value: String?, _ stems: [String]) -> Bool { stems.allSatisfy { (value ?? "").lowercased().contains($0) } }
        func task(_ folder: String, _ stems: [String]) {
            check(tasks.count == 1 && events.isEmpty, "Ожидалась одна задача")
            check(tasks.first?.folderID == folder, "Неверная папка")
            check(has(tasks.first?.title, stems), "Потерян смысл названия")
        }
        func event(_ date: String, _ time: String?, _ minutes: Int?, _ calendar: String = "work") {
            check(events.count == 1 && tasks.isEmpty, "Ожидалось одно событие")
            guard let p = events.first else { return }
            check(p.date == date, "Неверная дата")
            check(p.calendarID == calendar, "Неверный календарь")
            if let time { check(p.time == time, "Неверное время") }
            if let minutes {
                let draft = try? ActionPlanValidator.eventDraft(AssistantAction(proposal: p, context: fixture.context))
                check(draft?.end.timeIntervalSince(draft!.start) == Double(minutes * 60), "Неверная длительность")
            }
        }
        let clarification = ["event-needs-time", "unknown-folder", "heldout-unknown-folder", "heldout-unknown-calendar"].contains(fixture.id)
        if !clarification { check(questions.isEmpty, "Лишний уточняющий вопрос") }
        switch fixture.id {
        case "simple-task": task("inbox", ["полить", "цвет"]); check(tasks.first?.date == nil, "Придуман срок")
        case "folder-checklist":
            task(workFolder, ["отчёт"])
            check(tasks.first?.checklist?.count == 3, "Потеряны подзадачи")
            let content = tasks.first?.checklist?.joined(separator: " ").lowercased() ?? ""
            check(has(content, ["данн", "график", "вывод"]), "Изменён смысл подзадач")
            check(tasks.first?.date == nil, "Придуман срок")
        case "today-folder": task(homeFolder, ["купить", "продукт"]); check(tasks.first?.today == true && tasks.first?.date == nil, "Звезда перепутана со сроком")
        case "task-deadline": task("week", ["договор"]); check(tasks.first?.date == "2026-10-30" && tasks.first?.time == "18:15", "Неверный срок")
        case "multiple-folders":
            check(tasks.count == 3 && events.isEmpty, "Ожидались три задачи")
            for (stem, folder) in [("клиент", workFolder), ("хлеб", homeFolder), ("письм", "inbox")] {
                check(tasks.contains { has($0.title, [stem]) && $0.folderID == folder && $0.date == nil }, "Задача/папка/срок: " + stem)
            }
        case "event-explicit": event("2026-11-02", "11:00", 45); check(events.first?.reminderMinutes == 15, "Неверное напоминание")
        case "event-midnight": event("2026-11-02", "23:30", 90); check(events.first?.reminderMinutes == nil, "Придумано напоминание")
        case "event-all-day":
            event("2026-11-04", nil, nil, "home")
            check(events.first?.allDay == true, "Потерян весь день")
            if let p = events.first, let draft = try? ActionPlanValidator.eventDraft(AssistantAction(proposal: p, context: fixture.context)) {
                check((try? draft.interval().duration) == 86400, "Неверная длительность целого дня")
            } else { check(false, "Событие на весь день невалидно") }
        case "event-needs-time":
            check(!questions.isEmpty, "Не задан вопрос о времени")
            check(events.allSatisfy { $0.time == nil && $0.allDay != true && ($0.date == nil || $0.date == "2026-10-30") }, "Придумано время или неверная дата")
        case "event-followup": event("2026-10-30", "16:30", 20); check(events.first?.key == "event1", "Потерян ключ уточнения")
        case "unknown-folder":
            check(!questions.isEmpty, "Не уточнена неизвестная папка")
            check(actions.allSatisfy { $0.folderID == nil }, "Папка придумана или подменена")
        case "selected-task-event": event("2026-10-30", "15:00", 25); check(events.first?.linkTo == selectedTask, "Потеряна связь с открытой задачей"); check(events.first?.reminderMinutes == 5, "Неверное напоминание")
        case "new-task-event":
            check(tasks.count == 1 && events.count == 1, "Ожидались задача и событие")
            check(tasks.first?.folderID == workFolder && has(tasks.first?.title, ["стать"]), "Неверная новая задача")
            if let p = events.first, let t = tasks.first {
                check(p.linkTo == t.key && p.date == "2026-10-31" && p.time == "10:00", "Неверная связь или время новой задачи")
                let draft = try? ActionPlanValidator.eventDraft(AssistantAction(proposal: p, context: fixture.context))
                check(draft?.end.timeIntervalSince(draft!.start) == 1800, "Неверная длительность связанного события")
            }
        case "default-folder": task(homeFolder, ["посыл"]); check(tasks.first?.date == nil, "Придуман срок")
        case "english-task": task("inbox", ["release", "notes"]); check(tasks.first?.checklist?.count == 2 && tasks.first?.date == nil, "Подзадачи или срок английского запроса")
        case "default-reminder": event("2026-10-30", "09:00", 30); check(events.first?.reminderMinutes == 15, "Потеряна настройка напоминания")
        case "long-context": task("inbox", ["ссыл"]); check(tasks.first?.date == nil, "Придуман срок")
        case "correct-proposal": task(homeFolder, ["билет"]); check(tasks.first?.key == "task1" && tasks.first?.date == nil, "Потерян ключ или придуман срок")
        case "heldout-default": task(homeFolder, ["остат"]); check(tasks.first?.date == nil, "Придуман срок")
        case "heldout-quoted-folder": task(workFolder, ["доступ"]); check(tasks.first?.date == nil, "Придуман срок")
        case "heldout-literal-title": task("inbox", ["отметить", "сегодня"]); check(tasks.first?.today != true && tasks.first?.date == nil, "Название интерпретировано как команда")
        case "heldout-star-deadline": task("inbox", ["подпис"]); check(tasks.first?.date == "2026-11-05" && tasks.first?.time == "17:20" && tasks.first?.today == true, "Звезда и срок не независимы")
        case "heldout-unknown-folder": check(!questions.isEmpty && actions.allSatisfy { $0.folderID == nil }, "Не уточнена новая неизвестная папка")
        case "heldout-standalone": event("2026-11-06", "13:00", 40, "home"); check(events.first?.linkTo == nil && events.first?.reminderMinutes == nil, "Самостоятельное событие связано или получило напоминание")
        case "heldout-unknown-calendar": check(!questions.isEmpty && actions.allSatisfy { $0.calendarID == nil }, "Не уточнён неизвестный календарь")
        case "heldout-english-event": event("2026-11-07", "14:10", 35, "home"); check(events.first?.reminderMinutes == nil && events.first?.linkTo == nil, "Английское событие получило лишние параметры")
        default: check(false, "Неизвестный сценарий")
        }
        if !clarification {
            for p in actions {
                issues += ActionPlanValidator.problems(AssistantAction(proposal: p, context: fixture.context), folders: fixture.context.folders, calendars: fixture.context.calendars)
            }
        }
        return issues
    }
    private func checkCreation(_ response: AssistantResponse, fixture: Fixture) async throws -> (tasks: Int, events: Int) {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let folders = fixture.context.folders.compactMap { item -> TaskFolder? in
            guard let id = UUID(uuidString: item.id) else { return nil }
            let folder = TaskFolder(name: item.name, sortOrder: 0); folder.id = id; container.mainContext.insert(folder); return folder
        }
        if let id = fixture.context.taskID.flatMap(UUID.init(uuidString:)) {
            let task = PlannerTask(title: fixture.context.taskTitle ?? "Задача"); task.id = id; container.mainContext.insert(task)
        }
        try container.mainContext.save()
        let calendarStore = FakeCalendarStore()
        calendarStore.calendarList += [CalendarInfo(id: "home", title: "Личное", colorHex: "336699", writable: true)]
        let store = AssistantStore(url: lab.appending(path: "CreationScratch/\(UUID())/history.json"))
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let service = AssistantService(model: ModelManager(backend: FakeAIBackend(), directory: lab.appending(path: "NoModel")), store: store)
        let actions = (response.actions ?? []).map { AssistantAction(proposal: $0, context: fixture.context) }
        service.archive.threads[0].actions = actions
        await service.apply(taskService: TaskService(context: container.mainContext), calendar: CalendarService(store: calendarStore), folders: folders)
        let ready = actions.filter { ActionPlanValidator.problems($0, folders: fixture.context.folders, calendars: fixture.context.calendars).isEmpty }.count
        let created = service.current?.actions.filter { $0.status == .created } ?? []
        guard created.count == ready else { throw AssistantFailure(message: "Валидные предложения не сохранились полностью") }
        return (created.filter { $0.proposal.kind == .task }.count, created.filter { $0.proposal.kind == .event }.count)
    }
}

private func quantFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let capacity = Int(count)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
}
private actor QuantProbe {
    var peak: UInt64 = 0
    func reset(_ value: UInt64) { peak = value }
    func record(_ value: UInt64) { peak = max(peak, value) }
}
