import Testing
@testable import Planner

struct AssistantIntentPolicyTests {
    private let folders = [(id: "work", name: "Работа"), (id: "home", name: "Личное")]

    @Test func namedFolderAndClarificationUseActualFolderIDs() {
        let named = AssistantIntentPolicy.destination(in: "Добавь задачу в папку «Работа»", choices: folders)
        #expect(named.id == "work")
        let clarified = AssistantIntentPolicy.destination(in: "Личное", choices: folders, replyingToQuestion: true)
        #expect(clarified.id == "home")
    }

    @Test func unknownOrAmbiguousFolderRemainsUnresolved() {
        let unknown = AssistantIntentPolicy.destination(in: "Добавь задачу в папку «Проект»", choices: folders)
        #expect(unknown.specified && unknown.id == nil)
        let duplicate = AssistantIntentPolicy.destination(in: "Добавь задачу в папку «Работа»",
            choices: folders + [(id: "other", name: "Работа")])
        #expect(duplicate.specified && duplicate.id == nil)
    }

    @Test func laterDeadlineOverridesEarlierRemoval() {
        #expect(AssistantIntentPolicy.noDeadline("Создай задачу без срока"))
        #expect(!AssistantIntentPolicy.noDeadline("Сначала без срока, потом поставь срок на завтра"))
    }
}
