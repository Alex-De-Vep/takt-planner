import XCTest

@MainActor
final class PlannerUITests: XCTestCase {
    // Проверяем пользовательский путь целиком, включая повторное открытие локальной библиотеки.
    func testCreateFocusCompleteAndRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()

        let newFolder = app.buttons["new-folder-button"]
        XCTAssertTrue(newFolder.waitForExistence(timeout: 10))
        newFolder.click()
        let folderName = app.textFields["folder-name-field"]
        XCTAssertTrue(folderName.waitForExistence(timeout: 3))
        folderName.typeText("Тестовый проект")
        app.buttons["save-folder-button"].click()

        app.buttons["new-task-button"].click()
        let title = app.descendants(matching: .any)["task-title-field"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.click()
        title.typeText("Проверить сохранение")

        let today = app.buttons["today-task-button"]
        today.click()
        XCTAssertEqual(today.value as? String, "Включено")
        let complete = app.buttons["complete-task-button"]
        complete.click()
        XCTAssertEqual(complete.value as? String, "Включено")

        app.terminate()
        app.launch()
        let todayRow = app.descendants(matching: .any)["sidebar-today"].firstMatch
        XCTAssertTrue(todayRow.waitForExistence(timeout: 10))
        todayRow.click()
        // Переход в раздел не раскрывает выполненные и не открывает задачу автоматически.
        XCTAssertFalse(app.descendants(matching: .any)["task-title-field"].firstMatch.exists)
        let completedDisclosure = app.buttons["completed-disclosure-button"]
        XCTAssertTrue(completedDisclosure.waitForExistence(timeout: 3))
        completedDisclosure.click()
        let savedTitle = app.staticTexts["Проверить сохранение"].firstMatch
        XCTAssertTrue(savedTitle.waitForExistence(timeout: 5))
        savedTitle.click()
        XCTAssertEqual(app.buttons["complete-task-button"].value as? String, "Включено")
        XCTAssertEqual(app.buttons["today-task-button"].value as? String, "Включено")
        app.buttons["complete-task-button"].click()
        XCTAssertEqual(app.buttons["complete-task-button"].value as? String, "Выключено")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Planner — три колонки"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testLanguageChangesImmediatelyAndPersists() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.click()
        let picker = app.popUpButtons["language-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        app.menuItems["English"].click()
        XCTAssertTrue(app.staticTexts["Interface Language"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Inbox"].firstMatch.exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Inbox"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["My Folders"].firstMatch.exists)
    }
}
