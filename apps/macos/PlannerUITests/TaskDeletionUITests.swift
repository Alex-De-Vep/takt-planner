import XCTest

/// Регрессии маршрутизации Delete: только список удаляет задачу, поля редактируют текст.
@MainActor
final class TaskDeletionUITests: XCTestCase {
    func testDeleteInEditorsAndActiveList() {
        let app = launchIsolatedApp()
        createTask("Соседняя задача", in: app)
        createTask("Целевая задачаX", in: app)

        let title = field("task-title-field", in: app)
        title.typeText(XCUIKeyboardKey.delete.rawValue)
        assertValue("Целевая задача", of: title)
        XCTAssertFalse(deletionPrompt(in: app).exists)

        let description = field("task-description-field", in: app)
        description.click()
        description.typeText("ОписаниеX" + XCUIKeyboardKey.delete.rawValue)
        assertValue("Описание", of: description)
        XCTAssertFalse(deletionPrompt(in: app).exists)

        let search = field("task-search-field", in: app)
        search.click()
        search.typeText("ЦелеваяX" + XCUIKeyboardKey.delete.rawValue)
        assertValue("Целевая", of: search)
        XCTAssertFalse(deletionPrompt(in: app).exists)
        search.typeText(XCUIKeyboardKey.escape.rawValue)
        assertValue("", of: search)

        // Delete удаляет без диалога и закрывает карточку, не выбирая соседа.
        let rowTitle = app.staticTexts["Целевая задача"].firstMatch
        XCTAssertTrue(rowTitle.waitForExistence(timeout: 3))
        rowTitle.click()
        app.typeText(XCUIKeyboardKey.delete.rawValue)
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: rowTitle)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 3), .completed)
        XCTAssertFalse(deletionPrompt(in: app).exists)
        XCTAssertFalse(field("task-title-field", in: app).exists)
        XCTAssertTrue(app.staticTexts["Соседняя задача"].firstMatch.exists)
    }

    func testForwardDeleteInCompletedList() {
        let app = launchIsolatedApp()
        createTask("Выполненная задача", in: app)
        app.buttons["complete-task-button"].click()
        let completedList = app.descendants(matching: .any)["completed-task-list"].firstMatch
        XCTAssertTrue(completedList.waitForExistence(timeout: 3))
        let rowTitle = app.staticTexts["Выполненная задача"].firstMatch
        rowTitle.click()
        app.typeText(XCUIKeyboardKey.forwardDelete.rawValue)
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: rowTitle)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 3), .completed)
        XCTAssertFalse(deletionPrompt(in: app).exists)
        XCTAssertTrue(app.buttons["empty-create-task-button"].waitForExistence(timeout: 3))
    }

    func testDeletingActiveTasksKeepsCompletedPanelCollapsed() {
        let app = launchIsolatedApp()
        createTask("Архивная задача", in: app)
        app.buttons["complete-task-button"].click()
        let disclosure = app.buttons["completed-disclosure-button"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3))
        assertValue("Развернуто", of: disclosure)
        disclosure.click()
        assertValue("Свернуто", of: disclosure)
        createTask("Активная старая", in: app)
        createTask("Активная новая", in: app)

        // Удаление нижней строки не выбирает следующую за ней выполненную задачу.
        app.staticTexts["Активная старая"].firstMatch.click()
        app.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertFalse(field("task-title-field", in: app).exists)
        assertValue("Свернуто", of: disclosure)
        XCTAssertFalse(app.descendants(matching: .any)["completed-task-list"].firstMatch.exists)

        // После удаления последней активной задачи выполненные остаются скрыты до явного раскрытия.
        let lastActive = app.staticTexts["Активная новая"].firstMatch
        lastActive.click()
        app.typeText(XCUIKeyboardKey.delete.rawValue)
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: lastActive)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 3), .completed)
        assertValue("Свернуто", of: disclosure)
        XCTAssertFalse(app.descendants(matching: .any)["completed-task-list"].firstMatch.exists)
        XCTAssertFalse(field("task-title-field", in: app).exists)
        disclosure.click()
        XCTAssertTrue(app.staticTexts["Архивная задача"].firstMatch.waitForExistence(timeout: 3))
    }

    func testSwitchingFoldersClearsTaskAndCollapsesCompletedList() {
        let app = launchIsolatedApp()
        createTask("Архивная задача", in: app)
        app.buttons["complete-task-button"].click()
        let disclosure = app.buttons["completed-disclosure-button"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3))
        assertValue("Развернуто", of: disclosure)

        let week = field("sidebar-week", in: app), inbox = field("sidebar-inbox", in: app)
        week.click()
        XCTAssertFalse(field("task-title-field", in: app).exists)
        createTask("Активная на неделе", in: app)

        // Папка без активных задач не выбирает выполненную и не раскрывает её список.
        inbox.click()
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3))
        assertValue("Свернуто", of: disclosure)
        XCTAssertFalse(field("completed-task-list", in: app).exists)
        XCTAssertFalse(field("task-title-field", in: app).exists)
        disclosure.click()
        let archived = app.staticTexts["Архивная задача"].firstMatch
        XCTAssertTrue(archived.waitForExistence(timeout: 3))
        archived.click()
        assertValue("Архивная задача", of: field("task-title-field", in: app))

        // Папка с активной задачей также открывается без выбранной карточки.
        week.click()
        XCTAssertTrue(app.staticTexts["Активная на неделе"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(field("task-title-field", in: app).exists)
        inbox.click()
        assertValue("Свернуто", of: disclosure)
        XCTAssertFalse(field("task-title-field", in: app).exists)
    }

    private func launchIsolatedApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        XCTAssertTrue(app.buttons["new-task-button"].waitForExistence(timeout: 10))
        return app
    }

    private func createTask(_ text: String, in app: XCUIApplication) {
        app.buttons["new-task-button"].click()
        let title = field("task-title-field", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.click()
        title.typeText(text)
        assertValue(text, of: title)
    }

    private func field(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func deletionPrompt(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["Удалить задачу?"].firstMatch
    }

    private func assertValue(_ value: String, of element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 3), .completed, file: file, line: line)
    }
}
