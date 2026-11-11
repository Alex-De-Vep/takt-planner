import Foundation
import Testing
@testable import Planner

/// Предметные правила проверяем на ошибочных ответах модели и новых формулировках, не на личных данных.
struct AssistantIntentPolicyTests {
    private let home = "22222222-2222-4222-8222-222222222222"
    private let work = "11111111-1111-4111-8111-111111111111"
    private func context() -> AssistantContext {
        AssistantContext(now: Date(timeIntervalSince1970: 1793264400), timeZoneID: "Europe/Moscow", language: "ru",
            folders: [.init(id: "inbox", name: "Входящие"), .init(id: work, name: "Работа"), .init(id: home, name: "Личное")],
            calendars: [.init(id: "work", name: "Работа"), .init(id: "home", name: "Личное")], defaultFolderID: home,
            defaultCalendarID: "work", taskID: "33333333-3333-4333-8333-333333333333", taskTitle: "Проверить релиз", durationMinutes: 60, reminderMinutes: nil)
    }
    private func task(_ key: String = "task1", title: String = "Проверить", folder: String? = "inbox") -> AssistantProposal {
        AssistantProposal(key: key, kind: .task, title: title, folderID: folder)
    }
    private func event(_ key: String = "event1") -> AssistantProposal {
        AssistantProposal(key: key, kind: .event, title: "Встреча", date: "2026-10-30", time: "15:00", durationMinutes: 25, calendarID: "work")
    }
    private func thread(_ text: String) -> AssistantThread { var t = AssistantThread(); t.messages = [.init(role: .user, text: text)]; return t }
    private func normalize(_ actions: [AssistantProposal], _ text: String, context c: AssistantContext? = nil) -> AssistantResponse {
        AssistantResponsePolicy.normalize(.init(message: "", actions: actions), thread: thread(text), context: c ?? context())
    }
    @Test func referencesRoundTripWithoutGivingUUIDsToModel() {
        let refs = AssistantReferences(context: context())
        var p = event(); p.linkTo = context().taskID
        let encoded = refs.outbound(p)
        #expect(encoded.calendarID == "c0" && encoded.linkTo == "selected_task")
        #expect(refs.inbound(encoded).linkTo == p.linkTo)
        #expect(refs.folderID("f2") == home)
        #expect(refs.folderID("f99") == "f99")
    }
    @Test func defaultFolderComesFromApplicationNotModel() {
        let response = normalize([task()], "Добавь Проверить, без срока.")
        #expect(response.actions?.first?.folderID == home)
    }
    @Test func explicitFolderAndBuiltInNameOverrideDefault() {
        #expect(normalize([task()], "Создай в папке Работа задачу Проверить.").actions?.first?.folderID == work)
        #expect(normalize([task(folder: home)], "Добавь Проверить во Входящие.").actions?.first?.folderID == "inbox")
        #expect(normalize([task()], "Задача Проверить, папка Личное.").actions?.first?.folderID == home)
    }
    @Test func unknownFolderCannotFallBackSilentlyAndReplyResolvesIt() {
        var t = thread("Добавь задачу Проверить в папку Учёба, без срока.")
        let first = AssistantResponsePolicy.normalize(.init(message: "", actions: [task()]), thread: t, context: context())
        #expect(first.actions?.first?.folderID == nil)
        #expect(first.questions?.first?.text.contains("Учёба") == true)
        t.actions = first.actions!.map { AssistantAction(proposal: $0, context: context()) }
        t.messages.append(.init(role: .assistant, text: first.message, questions: first.questions ?? []))
        t.messages.append(.init(role: .user, text: "Личное"))
        let reply = AssistantResponsePolicy.normalize(.init(message: "", actions: [task("task2")]), thread: t, context: context())
        #expect(reply.actions?.first?.key == "task1" && reply.actions?.first?.folderID == home)
    }
    @Test func duplicateFolderNamesRequireClarification() {
        var c = context(); c.folders.append(.init(id: "44444444-4444-4444-8444-444444444444", name: "Работа"))
        let response = normalize([task()], "Добавь Проверить в папку Работа.", context: c)
        #expect(response.actions?.first?.folderID == nil && response.questions?.isEmpty == false)
    }
    @Test func multipleDestinationsAreResolvedWithinTheirClauses() {
        let response = normalize([task("task1", title: "Ответить", folder: "f0"), task("task2", title: "Купить хлеб", folder: "f0")],
            "Ответить в папке Работа; Купить хлеб в папке Личное.")
        #expect(response.actions?[0].folderID == work && response.actions?[1].folderID == home)
    }
    @Test func todayIsIndependentOfDeadlineAndDoesNotBecomeChecklistItem() {
        var p = task(title: "Позвонить"); p.date = "2026-10-29"; p.checklist = ["Отметить на сегодня"]
        let response = normalize([p], "Создай Позвонить и отметь На сегодня. Срок не нужен.")
        #expect(response.actions?.first?.today == true)
        #expect(response.actions?.first?.date == nil && response.actions?.first?.time == nil)
        #expect(response.actions?.first?.checklist?.isEmpty != false)
    }
    @Test func quotedTodayLabelWorksButTitleIsNotInterpretedAsInstruction() {
        #expect(normalize([task()], "Создай Проверить и отметь «На сегодня».").actions?.first?.today == true)
        var p = task(title: "Отметить на сегодня"); p.today = true
        #expect(normalize([p], "Создай задачу «Отметить на сегодня», без срока.").actions?.first?.today == nil)
    }
    @Test func starDoesNotEraseAnExplicitDeadlineAndRequestedChecklist() {
        var p = task(); p.date = "2026-11-02"; p.time = "18:00"; p.checklist = ["Сверить список"]
        let response = normalize([p], "Создай Проверить, срок 2 ноября в 18:00. Отметь На сегодня. Подзадача Сверить список.")
        #expect(response.actions?.first?.today == true && response.actions?.first?.date == "2026-11-02")
        #expect(response.actions?.first?.checklist == ["Сверить список"])
    }
    @Test func correctionKeepsPendingKeyFolderAndEventLinks() {
        var t = thread("Создай задачу Проверить, без срока.")
        t.actions = [AssistantAction(proposal: task(folder: work), context: context())]
        t.messages.append(.init(role: .assistant, text: "Проверьте"))
        t.messages.append(.init(role: .user, text: "Переименуй в Сверить."))
        let response = AssistantResponsePolicy.normalize(.init(message: "", actions: [task("task2", title: "Сверить")]), thread: t, context: context())
        #expect(response.actions?.first?.key == "task1" && response.actions?.first?.folderID == work)
    }
    @Test func ordinaryNewRequestDoesNotReusePendingIdentity() {
        var t = thread("Создай ещё задачу Вторую.")
        t.actions = [AssistantAction(proposal: task("old", folder: work), context: context())]
        let response = AssistantResponsePolicy.normalize(.init(message: "", actions: [task("new", title: "Вторую")]), thread: t, context: context())
        #expect(response.actions?.first?.key == "new" && response.actions?.first?.folderID == home)
    }
    @Test func taskTimeUsesSelectedTaskButStandaloneEventStaysIndependent() {
        #expect(normalize([event()], "Выдели для открытой задачи время завтра в 15:00.").actions?.first?.linkTo == context().taskID)
        #expect(normalize([event()], "Создай самостоятельное событие завтра в 15:00.").actions?.first?.linkTo == nil)
    }
    @Test func newTaskLinkIsOnlyAddedWhenRequested() {
        let linked = normalize([task(), event()], "Создай задачу Проверить и выдели для этой новой задачи время завтра в 15:00.")
        #expect(linked.actions?[1].linkTo == "task1")
        let independent = normalize([task(), event()], "Создай задачу Проверить и отдельное событие Встреча завтра в 15:00.")
        #expect(independent.actions?[1].linkTo == nil)
    }
    @Test func eventClarificationKeepsDateButExplicitDateChangeWins() {
        var t = thread("Запланируй Встречу завтра.")
        var old = event(); old.time = nil; old.linkTo = context().taskID
        t.actions = [AssistantAction(proposal: old, context: context())]
        t.messages.append(.init(role: .assistant, text: "Когда?", questions: [.init(text: "Во сколько?", options: ["15:00"])]))
        t.messages.append(.init(role: .user, text: "В 16:30 на 20 минут."))
        var p = event("event2"); p.date = "2026-11-01"
        let unchanged = AssistantResponsePolicy.normalize(.init(message: "", actions: [p]), thread: t, context: context())
        #expect(unchanged.actions?.first?.date == "2026-10-30" && unchanged.actions?.first?.linkTo == context().taskID)
        t.messages[t.messages.count-1].text = "Перенеси на 1 ноября в 16:30."
        let changed = AssistantResponsePolicy.normalize(.init(message: "", actions: [p]), thread: t, context: context())
        #expect(changed.actions?.first?.date == "2026-11-01")
    }
    @Test func unknownCalendarCannotBeReplacedByDefault() {
        let response = normalize([event()], "Создай Встречу в календаре Отпуск, завтра в 15:00.")
        #expect(response.actions?.first?.calendarID == nil && response.questions?.isEmpty == false)
    }
    @Test func folderWordsInsideTaskTitleAreDataAndLiteralFolderObjectsAreNotDestinations() {
        #expect(normalize([task(title: "Проверить в папке Работа")], "Создай задачу «Проверить в папке Работа», без срока.").actions?.first?.folderID == home)
        #expect(normalize([task(title: "Разобрать папку Документы")], "Создай задачу Разобрать папку Документы, без срока.").actions?.first?.folderID == home)
    }
    @Test func explicitDefaultAndQuotedDestinationAreSupported() {
        #expect(normalize([task(folder: work)], "Добавь Проверить в папку по умолчанию.").actions?.first?.folderID == home)
        #expect(normalize([task()], "Добавь Проверить в «Работа».").actions?.first?.folderID == work)
    }
    @Test func englishCalendarNameCanPrecedeCalendarNoun() {
        var c = context(); c.language = "en"; c.calendars = [.init(id: "work", name: "Work"), .init(id: "home", name: "Personal")]
        #expect(normalize([event()], "Create a meeting in Personal calendar.", context: c).actions?.first?.calendarID == "home")
    }
    @Test func starringAPendingTaskDoesNotEraseItsDeadline() {
        var p = task(); p.date = "2026-11-02"; p.time = "18:00"
        var t = thread("Отметь На сегодня."); t.actions = [.init(proposal: p, context: context())]
        var proposed = p; proposed.date = "2026-10-29"
        let response = AssistantResponsePolicy.normalize(.init(message: "", actions: [proposed]), thread: t, context: context())
        #expect(response.actions?.first?.today == true && response.actions?.first?.date == "2026-11-02" && response.actions?.first?.time == "18:00")
    }
    @Test func aNoDeadlinePhraseDoesNotEraseAnotherTasksExplicitDeadline() {
        let first = task("task1", title: "Первую")
        var second = task("task2", title: "Вторую"); second.date = "2026-11-02"
        let response = normalize([first, second], "Добавь Первую без срока и Вторую со сроком 2 ноября.")
        #expect(response.actions?[1].date == "2026-11-02")
    }
    @Test func hallucinatedLinkCannotAttachAStandaloneEventOrReferToItself() {
        var p = event(); p.linkTo = "event1"
        #expect(normalize([p], "Создай Встречу завтра в 15:00.").actions?.first?.linkTo == nil)
        p.linkTo = context().taskID
        #expect(normalize([p], "Запланируй самостоятельное событие завтра в 15:00.").actions?.first?.linkTo == nil)
    }
    @Test func unambiguousChecklistTextObjectsAreAcceptedButFlagsAreNotDiscarded() throws {
        let response = try ActionPlanValidator.decode("{\"message\":\"\",\"actions\":[{\"key\":\"task1\",\"kind\":\"task\",\"title\":\"Проверить\",\"checklist\":[{\"text\":\"Первый\"},{\"title\":\"Второй\"}]}]}")
        #expect(response.actions?.first?.checklist == ["Первый", "Второй"])
        #expect(throws: (any Error).self) { try ActionPlanValidator.decode("{\"message\":\"\",\"actions\":[{\"key\":\"task1\",\"kind\":\"task\",\"title\":\"Проверить\",\"checklist\":[{\"text\":\"Первый\",\"done\":true}]}]}") }
    }
    @Test func aReminderFromAnEarlierIndependentRequestCannotOverrideDefaults() {
        var t = thread("Создай Встречу завтра в 15:00, напомни за час.")
        t.messages.append(.init(role: .assistant, text: "Проверьте"))
        t.messages.append(.init(role: .user, text: "Создай другое событие завтра в 18:00."))
        var p = event(); p.reminderMinutes = 60
        let response = AssistantResponsePolicy.normalize(.init(message: "", actions: [p]), thread: t, context: context())
        #expect(response.actions?.first?.reminderMinutes == nil)
        #expect(normalize([p], "Создай событие Встреча завтра в 15:00, без напоминания.").actions?.first?.reminderMinutes == nil)
    }
    @Test func laterExplicitDeadlineAndNegativeEnglishFocusAreRespected() {
        #expect(!AssistantIntentPolicy.noDeadline("Без срока. Нет, поставь срок 5 ноября."))
        #expect(AssistantIntentPolicy.noDeadline("Срок 5 ноября. Нет, без срока."))
        #expect(AssistantIntentPolicy.today("Do not mark it for today") == false)
    }
    @Test func clarificationPreservesExplicitlyAbsentReminderAndUnresolvedCalendar() {
        var c = context(); c.reminderMinutes = 15
        var old = event(); old.calendarID = nil; old.reminderMinutes = nil
        var t = thread("Создай Встречу в календаре Отпуск без напоминания.")
        t.actions = [.init(proposal: old, context: c)]
        t.messages.append(.init(role: .assistant, text: "Уточните", questions: [.init(text: "Какой календарь?", options: ["Работа"])]))
        t.messages.append(.init(role: .user, text: "В 16:00."))
        var proposed = event(); proposed.time = "16:00"; proposed.reminderMinutes = 15
        let result = AssistantResponsePolicy.normalize(.init(message: "", actions: [proposed]), thread: t, context: c)
        #expect(result.actions?.first?.calendarID == nil && result.actions?.first?.reminderMinutes == nil)
    }
    @Test func promptIsStableAndContainsShortReferencesAndFullLatestMessage() throws {
        let text = String(repeating: "Детали. ", count: 220) + "Создай Проверить в папке Личное."
        let t = thread(text)
        let a = try AssistantPrompt.request(context: context(), thread: t)
        #expect(a == (try AssistantPrompt.request(context: context(), thread: t)))
        #expect(!a.contains(home) && !a.contains(work) && !a.contains(context().taskID!))
        #expect(a.contains("f2") && a.contains("selected_task") && a.contains("Создай Проверить в папке Личное."))
    }
}
