import XCTest

@MainActor final class NotesUITests: XCTestCase {
    func testNoteSurvivesModeSwitchAndRestart() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["PLANNER_UI_TEST_CALENDAR"] = "1"
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-appLanguage", "ru"]
        app.launch()
        let mode = app.descendants(matching: .any).matching(identifier: "notes-mode").firstMatch
        XCTAssertTrue(app.buttons["new-folder-button"].waitForExistence(timeout: 8))
        XCTAssertFalse(mode.exists)
        app.buttons["new-folder-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let folderName = app.textFields["folder-name-field"]
        XCTAssertTrue(folderName.waitForExistence(timeout: 5))
        folderName.typeText("Мои заметки")
        app.buttons["save-folder-button"].click()
        XCTAssertTrue(mode.waitForExistence(timeout: 8))
        let create = app.buttons["new-task-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        create.click()
        let taskTitle = app.descendants(matching: .any).matching(identifier: "task-title-field").firstMatch
        XCTAssertTrue(taskTitle.waitForExistence(timeout: 5))
        taskTitle.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
        app.typeText("Задача проекта")
        mode.click()
        app.buttons["new-task-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let title = app.textFields["note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        title.typeText("Заметки проекта")
        XCTAssertEqual(title.value as? String, "Заметки проекта")
        let body = app.textViews.matching(identifier: "note-body").firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.05)).click()
        app.typeText("Первая строка\nВторая строка")
        XCTAssertEqual(body.value as? String, "Первая строка\nВторая строка", "body frame: \(body.frame); title: \(title.value ?? "nil")")
        app.descendants(matching: .any).matching(identifier: "tasks-mode").firstMatch.click()
        let taskRow = app.staticTexts["Задача проекта"].firstMatch
        XCTAssertTrue(taskRow.waitForExistence(timeout: 5))
        XCTAssertTrue(taskRow.isHittable)
        mode.click()
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertEqual(body.value as? String, "Первая строка\nВторая строка")
        for id in ["inbox", "today", "week", "month", "all"] {
            app.descendants(matching: .any).matching(identifier: "sidebar-\(id)").firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            XCTAssertFalse(mode.exists)
            XCTAssertFalse(body.exists)
        }
        app.staticTexts["Мои заметки"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.click()
        app.staticTexts["Заметки проекта"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Takt notes workspace"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.menuBars.menuBarItems["Takt"].click()
        app.menuItems["terminate:"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launch()
        let savedFolder = app.descendants(matching: .any).matching(identifier: "folder-row-Мои заметки").firstMatch
        XCTAssertTrue(savedFolder.waitForExistence(timeout: 8))
        savedFolder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(mode.waitForExistence(timeout: 8))
        mode.click()
        let note = app.staticTexts["Заметки проекта"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Заметки проекта")
        XCTAssertEqual(body.value as? String, "Первая строка\nВторая строка")
    }
}
