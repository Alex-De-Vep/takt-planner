import XCTest

/// Проверки готовятся к сборке; запуск и проверку реального интерфейса выполняет пользователь.
@MainActor
final class TaskInteractionUITests: XCTestCase {
    func testOpenTaskKeepsNativeSelectionWhileEditingAndAfterBlankClick() {
        let app = launchIsolatedApp()
        createTask("Постоянно выбранная", in: app)
        let nativeRows = app.descendants(matching: .tableRow).containing(.staticText, identifier: "Постоянно выбранная")
        let nativeRow = nativeRows.firstMatch.exists ? nativeRows.firstMatch
            : app.descendants(matching: .outlineRow).containing(.staticText, identifier: "Постоянно выбранная").firstMatch
        XCTAssertTrue(nativeRow.waitForExistence(timeout: 3))
        assertSelected(nativeRow)
        replace(field("task-description-field", in: app), with: "Ввод не снимает выбор")
        assertSelected(nativeRow)
        app.typeText("X")
        assertValue("Ввод не снимает выборX", of: field("task-description-field", in: app))

        // Клик по пустому месту списка не закрывает карточку и не убирает штатную подсветку.
        field("task-list", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).click()
        assertValue("Постоянно выбранная", of: field("task-title-field", in: app))
        assertSelected(nativeRow)

        // Та же строка снова получает фокус с первого клика, даже если её идентификатор не менялся.
        row("Постоянно выбранная", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).click()
        assertSelected(nativeRow)
        app.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(app.buttons["empty-create-task-button"].waitForExistence(timeout: 3))
        XCTAssertFalse(field("task-title-field", in: app).exists)
    }

    func testWholeRowOpensOnOneClickAndActionButtonsKeepTheOpenTask() {
        let app = launchIsolatedApp()
        createTask("Первая задача", in: app)
        createTask("Вторая задача", in: app)

        // Включаем текст, пустую часть и край над кнопками, где ранее клик терялся.
        for point in [CGVector(dx: 0.08, dy: 0.45), CGVector(dx: 0.35, dy: 0.2),
                      CGVector(dx: 0.60, dy: 0.65), CGVector(dx: 0.96, dy: 0.04)] {
            reopenInbox(in: app)
            XCTAssertFalse(field("task-title-field", in: app).exists)
            let first = row("Первая задача", in: app)
            XCTAssertTrue(first.waitForExistence(timeout: 3))
            first.coordinate(withNormalizedOffset: point).click()
            assertValue("Первая задача", of: field("task-title-field", in: app))
        }
        let other = row("Вторая задача", in: app)
        let star = other.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-star-")).firstMatch
        XCTAssertTrue(star.exists)
        star.click()
        assertValue("Включено", of: star)
        assertValue("Первая задача", of: field("task-title-field", in: app))
        star.click()
        assertValue("Выключено", of: star)

        let complete = other.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-complete-")).firstMatch
        complete.click()
        assertValue("Первая задача", of: field("task-title-field", in: app))
        assertValue("Свернуто", of: field("completed-disclosure-button", in: app))
        field("completed-disclosure-button", in: app).click()
        let finished = row("Вторая задача", in: app)
        XCTAssertTrue(finished.waitForExistence(timeout: 3))
        finished.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).click()
        assertValue("Вторая задача", of: field("task-title-field", in: app))
    }

    func testSavedAndCompletedTaskRemainsEditableAfterRelaunchAndSwitching() {
        let app = launchIsolatedApp()
        createTask("Сохранённая задача", in: app)
        replace(field("task-description-field", in: app), with: "Описание\nВторая строка")
        app.buttons["add-checklist-item-button"].click()
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "checklist-title-")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        replace(item, with: "Первый пункт")
        createTask("Другая задача", in: app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["new-task-button"].waitForExistence(timeout: 10))

        row("Сохранённая задача", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).click()
        replace(field("task-title-field", in: app), with: "Изменённая задача")
        replace(field("task-description-field", in: app), with: "Изменённое описание\nНовая строка")
        row("Другая задача", in: app).click()
        row("Изменённая задача", in: app).click()
        assertValue("Изменённое описание\nНовая строка", of: field("task-description-field", in: app))

        // Выполнение не переводит название, описание и подзадачи в режим только чтения.
        app.buttons["complete-task-button"].click()
        replace(field("task-title-field", in: app), with: "Изменённая выполненная")
        replace(field("task-description-field", in: app), with: "Описание выполненной")
        replace(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "checklist-title-")).firstMatch,
                with: "Обновлённый пункт")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["new-task-button"].waitForExistence(timeout: 10))
        let disclosure = field("completed-disclosure-button", in: app)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3))
        assertValue("Свернуто", of: disclosure)
        disclosure.click()
        row("Изменённая выполненная", in: app).click()
        assertValue("Описание выполненной", of: field("task-description-field", in: app))
        assertValue("Обновлённый пункт", of: app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "checklist-title-")).firstMatch)
        replace(field("task-title-field", in: app), with: "Снова доступна для ввода")
    }

    func testRowDragStillMovesTheSameTaskToAFolder() {
        let app = launchIsolatedApp()
        createTask("Переносимая задача", in: app)
        createTask("Оставить во входящих", in: app)
        assertValue("Оставить во входящих", of: field("task-title-field", in: app))
        let source = row("Переносимая задача", in: app)
        let week = field("sidebar-week", in: app)
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.3, thenDragTo: week.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: source)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 3), .completed)
        XCTAssertTrue(row("Оставить во входящих", in: app).exists)
        assertValue("Оставить во входящих", of: field("task-title-field", in: app))
        week.click()
        XCTAssertFalse(field("task-title-field", in: app).exists)
        let moved = row("Переносимая задача", in: app)
        XCTAssertTrue(moved.waitForExistence(timeout: 3))
        moved.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).click()
        replace(field("task-description-field", in: app), with: "Редактируется после переноса")
    }

    func testOwnFolderDropAndDropOutsideSidebarKeepNavigationAndSelection() {
        let app = launchIsolatedApp()
        createTask("Переносимая", in: app)
        createTask("Открытая", in: app)
        let source = row("Переносимая", in: app)
        let inbox = field("sidebar-inbox", in: app)
        // Собственная папка — серое назначение без перемещения и без выбора переносимой задачи.
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.3, thenDragTo: inbox.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        assertValue("Открытая", of: field("task-title-field", in: app))
        XCTAssertTrue(source.exists)
        XCTAssertTrue(row("Открытая", in: app).exists)
        // Отпускание над документом не переносит задачу и не оставляет блокировку навигации.
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.3, thenDragTo: field("task-description-field", in: app)
                .coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)))
        assertValue("Открытая", of: field("task-title-field", in: app))
        XCTAssertTrue(source.exists)
        field("sidebar-week", in: app).click()
        XCTAssertTrue(app.buttons["empty-create-task-button"].waitForExistence(timeout: 3))
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

    private func createTask(_ title: String, in app: XCUIApplication) {
        app.buttons["new-task-button"].click()
        replace(field("task-title-field", in: app), with: title)
    }
    private func reopenInbox(in app: XCUIApplication) {
        field("sidebar-week", in: app).click()
        field("sidebar-inbox", in: app).click()
    }
    private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-row-"))
            .containing(.staticText, identifier: title).firstMatch
    }
    private func field(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }
    private func replace(_ field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
        assertValue(value, of: field)
    }
    private func assertValue(_ value: String, of field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 3), .completed, file: file, line: line)
    }
    private func assertSelected(_ row: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed, file: file, line: line)
    }
}
