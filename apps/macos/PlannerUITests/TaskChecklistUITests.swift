import XCTest

/// Проверяем реальные клики в отдельной библиотеке и с подменой календаря.
@MainActor
final class TaskChecklistUITests: XCTestCase {
    func testEditingInMiddleKeepsInsertionPointAfterEachSave() {
        checkMiddleEditing(in: "Начало конец")
    }

    func testEditingWrappedSubtaskKeepsInsertionPointAfterEachSave() {
        checkMiddleEditing(in: "Начало " + String(repeating: "длинный текст подзадачи с переносом. ", count: 4))
    }

    private func checkMiddleEditing(in initialText: String) {
        let app = launchIsolatedApp()
        createTask(in: app)
        app.buttons["add-checklist-item-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let title = titles(in: app).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        app.typeText(initialText)
        app.typeKey(.tab, modifierFlags: [])
        expectValue(initialText, of: title)
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).click()
        // Навигационные клавиши не зависят от раскладки; Cmd+Up ставит курсор в начало документа.
        app.typeKey(.upArrow, modifierFlags: .command)
        for _ in 0..<"Начало ".count { app.typeKey(.rightArrow, modifierFlags: []) }

        // Отдельные вызовы дают сохранению и обновлению карточки закончиться между символами.
        app.typeText("т")
        expectValue("Начало т" + initialText.dropFirst(7), of: title)
        app.typeText("е")
        expectValue("Начало те" + initialText.dropFirst(7), of: title)
        app.typeText("к")
        expectValue("Начало тек" + initialText.dropFirst(7), of: title)
        if initialText.count > 100 { XCTAssertGreaterThan(title.frame.height, 50) }
    }

    func testInlineButtonAddsSeveralSubtasks() {
        let app = launchIsolatedApp()
        createTask(in: app)
        // AX-обёртка toolbar шире круглой кнопки: нажимаем в центр видимого значка.
        app.buttons["add-checklist-item-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let first = titles(in: app).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
        first.typeText("Первый пункт")

        let append = app.buttons["append-checklist-item-button"]
        XCTAssertTrue(append.waitForExistence(timeout: 3))
        append.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
        expectCount(2, in: app)
        app.typeText("Второй пункт")
        // Прозрачная правая часть строки тоже остаётся действующей областью кнопки.
        append.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
        expectCount(3, in: app)
        app.typeText("Третий пункт")
        XCTAssertEqual(titles(in: app).element(boundBy: 0).value as? String, "Первый пункт")
        XCTAssertEqual(titles(in: app).element(boundBy: 1).value as? String, "Второй пункт")
        XCTAssertEqual(titles(in: app).element(boundBy: 2).value as? String, "Третий пункт")
    }

    func testLongSubtaskWrapsAndSurvivesReopening() {
        let app = launchIsolatedApp()
        createTask(in: app)
        app.buttons["add-checklist-item-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let first = titles(in: app).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        let longTitle = String(repeating: "Длинный текст подзадачи должен полностью переноситься на следующие строки. ", count: 3) + "Конец текста."
        app.typeText(longTitle)
        XCTAssertEqual(first.value as? String, longTitle)
        XCTAssertGreaterThan(first.frame.height, 50)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Многострочная подзадача"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["append-checklist-item-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
        expectCount(2, in: app)
        app.typeText("Следующий пункт")
        XCTAssertGreaterThanOrEqual(titles(in: app).element(boundBy: 1).frame.minY, first.frame.maxY)
        // Enter на заполненном пункте продолжает список даже после перехода к многострочному полю.
        app.typeKey(.return, modifierFlags: [])
        expectCount(3, in: app)
        app.typeText("Создано клавишей ввода")
        // Завершаем редактирование перед принудительным завершением процесса XCTest.
        app.typeKey(.tab, modifierFlags: [])
        expectValue("Создано клавишей ввода", of: titles(in: app).element(boundBy: 2))
        app.terminate()
        app.launch()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-row-"))
            .containing(.staticText, identifier: "Проверка подзадач").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).click()
        expectCount(3, in: app)
        XCTAssertEqual(titles(in: app).element(boundBy: 0).value as? String, longTitle)
        XCTAssertGreaterThan(titles(in: app).element(boundBy: 0).frame.height, 50)
        XCTAssertEqual(titles(in: app).element(boundBy: 1).value as? String, "Следующий пункт")
        XCTAssertEqual(titles(in: app).element(boundBy: 2).value as? String, "Создано клавишей ввода")
        let deletionID = titles(in: app).element(boundBy: 1).identifier.replacingOccurrences(of: "checklist-title-", with: "delete-checklist-item-")
        app.buttons[deletionID].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        expectCount(2, in: app)
        XCTAssertEqual(titles(in: app).element(boundBy: 0).value as? String, longTitle)
        XCTAssertEqual(titles(in: app).element(boundBy: 1).value as? String, "Создано клавишей ввода")
        let completionID = titles(in: app).element(boundBy: 0).identifier.replacingOccurrences(of: "checklist-title-", with: "complete-checklist-item-")
        let complete = app.buttons[completionID]
        complete.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        expectValue("Выполнено", of: complete)
        XCTAssertEqual(titles(in: app).element(boundBy: 0).value as? String, longTitle)
        XCTAssertGreaterThan(titles(in: app).element(boundBy: 0).frame.height, 50)
    }

    private func launchIsolatedApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["PLANNER_UI_TEST_CALENDAR"] = "1"
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-calendarOpen", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["new-task-button"].waitForExistence(timeout: 10))
        return app
    }

    private func createTask(in app: XCUIApplication) {
        app.buttons["empty-create-task-button"].click()
        let title = app.descendants(matching: .any)["task-title-field"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        // Создание уже передало фокус нативному редактору; не полагаемся на его AX hit point.
        app.typeText("Проверка подзадач")
    }

    private func titles(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "checklist-title-"))
    }

    private func expectCount(_ count: Int, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", count), object: titles(in: app))
        let result = XCTWaiter.wait(for: [expectation], timeout: 4)
        if result != .completed {
            let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            attachment.lifetime = .keepAlways
            add(attachment)
            print(app.debugDescription)
        }
        XCTAssertEqual(result, .completed, file: file, line: line)
    }

    private func expectValue(_ value: String, of field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed,
                       "Текущий текст: \(String(describing: field.value)); ожидался: \(value)", file: file, line: line)
    }
}
