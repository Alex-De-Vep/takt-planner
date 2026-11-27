import XCTest

@MainActor final class AssistantConnectionUITests: XCTestCase {
    func testDisconnectedChatOpensAssistantSettingsWithoutAModelPicker() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["PLANNER_UI_TEST_CALENDAR"] = "1"
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-appLanguage", "ru"]
        app.launch()

        let panelButton = app.buttons["toggle-assistant-button"]
        XCTAssertTrue(panelButton.waitForExistence(timeout: 8))
        panelButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        let connect = app.buttons["assistant-chat-connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertEqual(connect.label, "Подключить")
        XCTAssertTrue(app.staticTexts["Ваш ИИ-помощник в Takt"].exists)
        XCTAssertTrue(app.staticTexts["Подключите любимый ИИ-сервис, чтобы обсуждать идеи, редактировать заметки и планировать задачи и события прямо в чате."].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "assistant-model-picker").firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Выбрать модель"].exists)

        connect.click()
        XCTAssertTrue(app.buttons["assistant-connect-provider"].waitForExistence(timeout: 5))
    }
}
