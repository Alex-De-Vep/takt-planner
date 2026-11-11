import XCTest

/// Выполнение меняет данные и счётчик; раскрытие выполненных принадлежит только пользователю.
@MainActor
final class TaskCompletionDisclosureUITests: XCTestCase {
    func testCompletingSelectedAndOtherTaskKeepsSectionClosed() {
        let app = launchIsolatedApp()
        createTask("Первая задача", in: app, first: true)
        createTask("Вторая задача", in: app)
        completionButton(in: row("Первая задача", in: app)).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        expectCollapsed(in: app)
        expect("Вторая задача", in: field("task-title-field", in: app))
        completionButton(in: row("Вторая задача", in: app)).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        expectCollapsed(in: app)
        expect("Вторая задача", in: field("task-title-field", in: app))
        let disclosure = app.buttons["completed-disclosure-button"]
        disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click()
        expect("Развернуто", in: disclosure)
        XCTAssertTrue(row("Первая задача", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(row("Вторая задача", in: app).exists)
        disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click()
        expectCollapsed(in: app)
        expect("Вторая задача", in: field("task-title-field", in: app))
    }

    func testManuallyExpandedSectionStaysExpandedWhenCompletingAnotherTask() {
        let app = launchIsolatedApp()
        createTask("Первая задача", in: app, first: true)
        app.buttons["complete-task-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        expectCollapsed(in: app)
        let disclosure = app.buttons["completed-disclosure-button"]
        disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click()
        expect("Развернуто", in: disclosure)
        createTask("Вторая задача", in: app)
        app.buttons["complete-task-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        expect("Включено", in: app.buttons["complete-task-button"])
        expect("Развернуто", in: disclosure)
        XCTAssertTrue(row("Первая задача", in: app).exists)
        XCTAssertTrue(row("Вторая задача", in: app).exists)
        expect("Вторая задача", in: field("task-title-field", in: app))
    }

    func testDownArrowDoesNotExpandClosedSection() {
        let app = launchIsolatedApp()
        createTask("Завершённая", in: app, first: true)
        createTask("Активная", in: app)
        completionButton(in: row("Завершённая", in: app)).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        expectCollapsed(in: app)
        row("Активная", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).click()
        app.typeKey(.downArrow, modifierFlags: [])
        expectCollapsed(in: app)
        expect("Активная", in: field("task-title-field", in: app))
    }

    private func launchIsolatedApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["PLANNER_UI_TEST_CALENDAR"] = "1"
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-calendarOpen", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["empty-create-task-button"].waitForExistence(timeout: 10))
        return app
    }

    private func createTask(_ title: String, in app: XCUIApplication, first: Bool = false) {
        if first { app.buttons["empty-create-task-button"].click() }
        else { app.buttons["new-task-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click() }
        XCTAssertTrue(field("task-title-field", in: app).waitForExistence(timeout: 3))
        app.typeText(title)
        expect(title, in: field("task-title-field", in: app))
    }

    private func field(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-row-"))
            .containing(.staticText, identifier: title).firstMatch
    }

    private func completionButton(in row: XCUIElement) -> XCUIElement {
        row.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-complete-")).firstMatch
    }

    private func expectCollapsed(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let disclosure = app.buttons["completed-disclosure-button"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3), file: file, line: line)
        let noAutomaticExpansion = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Развернуто"), object: disclosure)
        noAutomaticExpansion.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [noAutomaticExpansion], timeout: 1.2), .completed, file: file, line: line)
        expect("Свернуто", in: disclosure, file: file, line: line)
        XCTAssertFalse(field("completed-task-list", in: app).exists, file: file, line: line)
    }

    private func expect(_ value: String, in field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed,
                       "Текущее значение: \(String(describing: field.value))", file: file, line: line)
    }
}
