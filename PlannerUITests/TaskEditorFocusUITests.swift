import AppKit
import XCTest

/// Проверяем смену фокуса и ввод в середине текста в отдельной библиотеке с подменой календаря.
@MainActor
final class TaskEditorFocusUITests: XCTestCase {
    func testMouseSelectionCopiesTaskInDisplayOrderAndFieldsRemainEditable() {
        let app = launchPreparedApp()
        let title = field("task-title-field", in: app)
        let description = field("task-description-field", in: app)
        let items = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "checklist-title-"))
        app.buttons["add-checklist-item-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 3))
        app.typeText("Первый пункт")
        app.typeKey(.return, modifierFlags: [])
        let last = items.element(boundBy: 1)
        XCTAssertTrue(last.waitForExistence(timeout: 3))
        app.typeText("Второй пункт")
        expect("Второй пункт", in: last)

        let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.35)).withOffset(CGVector(dx: 1, dy: 0))
        let end = last.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.4))
        let expected = "Начало конец\nНачало конец\nПервый пункт\nВторой пункт"
        start.press(forDuration: 0.1, thenDragTo: end)
        expectCopied(expected, in: app)
        attachWindow(app, name: "Выделение всех полей задачи")
        end.press(forDuration: 0.1, thenDragTo: start)
        expectCopied(expected, in: app)

        description.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.2)).click()
        app.typeKey("a", modifierFlags: .command)
        expectCopied("Начало конец", in: app)
        app.typeText("Изменённое описание")
        expect("Изменённое описание", in: description)
        expect("Начало конец", in: title)
        expect("Первый пункт", in: items.firstMatch)
        expect("Второй пункт", in: last)
    }

    func testLargeTaskActionsWorkWhileEditing() {
        let app = launchPreparedApp()
        let today = app.buttons["today-task-button"]
        let complete = app.buttons["complete-task-button"]
        let star = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-star-")).firstMatch
        today.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        expect("Включено", in: today)
        expect("Включено", in: star)
        attachWindow(app, name: "Большая кнопка На сегодня включена")
        // Проверяем также свободное место кнопки, а не только её надпись.
        today.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
        expect("Выключено", in: today)
        expect("Выключено", in: star)

        field("task-description-field", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.03)).click()
        complete.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        expect("Включено", in: complete)
        let disclosure = app.buttons["completed-disclosure-button"]
        expect("Свернуто", in: disclosure)
        XCTAssertFalse(field("completed-task-list", in: app).exists)
        disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click()
        expect("Развернуто", in: disclosure)
        let rowCompletion = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-complete-")).firstMatch
        expect("Выполнено", in: rowCompletion)
        expect("Начало конец", in: field("task-title-field", in: app))
        attachWindow(app, name: "Большая кнопка Выполнено включена")
        complete.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
        expect("Выключено", in: complete)
        expect("Не выполнено", in: rowCompletion)
        expect("Начало конец", in: field("task-description-field", in: app))
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: disclosure)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 3), .completed)
        complete.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        expect("Включено", in: complete)
        expect("Свернуто", in: disclosure)
        XCTAssertFalse(field("completed-task-list", in: app).exists)
    }

    func testMiddleTypingAfterLeavingTitleAndDescription() {
        let app = launchPreparedApp()
        for identifier in ["task-title-field", "task-description-field"] {
            let editor = field(identifier, in: app)
            positionInMiddle(editor, in: app)
            for _ in 0..<5 { app.typeKey(.rightArrow, modifierFlags: .shift) }
            let otherID = identifier == "task-title-field" ? "task-description-field" : "task-title-field"
            field(otherID, in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.03)).click()
            attachWindow(app, name: "\(identifier) после ухода фокуса")

            positionInMiddle(editor, in: app)
            app.typeText("т")
            expect("Начало тконец", in: editor)
            app.typeText("е")
            expect("Начало теконец", in: editor)
        }
    }

    func testMiddleTypingAfterSwitchingTasks() {
        let app = launchPreparedApp()
        // Выделение заголовка снимается при переходе в описание; затем описание теряет фокус при смене задачи.
        for identifier in ["task-title-field", "task-description-field"] {
            positionInMiddle(field(identifier, in: app), in: app)
            for _ in 0..<5 { app.typeKey(.rightArrow, modifierFlags: .shift) }
        }
        app.buttons["new-task-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.typeText("Другая задача")
        expect("Другая задача", in: field("task-title-field", in: app))
        let original = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-row-"))
            .containing(.staticText, identifier: "Начало конец").firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 3))
        original.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).click()
        expect("Начало конец", in: field("task-title-field", in: app))
        expect("Начало конец", in: field("task-description-field", in: app))
        attachWindow(app, name: "Выделение после возвращения к задаче")
        for identifier in ["task-title-field", "task-description-field"] {
            let editor = field(identifier, in: app)
            positionInMiddle(editor, in: app)
            app.typeText("т")
            expect("Начало тконец", in: editor)
            app.typeText("е")
            expect("Начало теконец", in: editor)
        }
    }

    private func launchPreparedApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["PLANNER_UI_TEST_CALENDAR"] = "1"
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-calendarOpen", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["empty-create-task-button"].waitForExistence(timeout: 10))
        app.buttons["empty-create-task-button"].click()
        XCTAssertTrue(field("task-title-field", in: app).waitForExistence(timeout: 3))
        app.typeText("Начало конец")
        expect("Начало конец", in: field("task-title-field", in: app))
        field("task-description-field", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.03)).click()
        app.typeText("Начало конец")
        expect("Начало конец", in: field("task-description-field", in: app))
        return app
    }

    private func positionInMiddle(_ editor: XCUIElement, in app: XCUIApplication) {
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.03)).click()
        app.typeKey(.upArrow, modifierFlags: .command)
        for _ in 0..<7 { app.typeKey(.rightArrow, modifierFlags: []) }
    }

    private func field(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func expect(_ text: String, in field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed,
                       "Текущий текст: \(String(describing: field.value))", file: file, line: line)
    }

    private func expectCopied(_ text: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        app.typeKey("c", modifierFlags: .command)
        guard pasteboard.changeCount != changeCount else {
            XCTFail("Команда копирования не обновила буфер обмена", file: file, line: line)
            return
        }
        XCTAssertEqual(pasteboard.string(forType: .string), text, file: file, line: line)
    }

    private func attachWindow(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
