import XCTest

@MainActor
final class PlannerHelpUITests: XCTestCase {
    func testHelpMenuOpensEnglishGuide() {
        checkGuide(language: "en", locale: "en_US", title: "Planner Help", first: "Getting started", today: "Today")
    }

    func testHelpMenuOpensRussianGuide() {
        checkGuide(language: "ru", locale: "ru_RU", title: "Справка по приложению", first: "Быстрый старт", today: "Список «Сегодня»")
    }

    func testSettingsOpensTheSameGuide() {
        let app = launch(language: "en", locale: "en_US")
        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()

        let help = app.buttons["settings-help"]
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        XCTAssertEqual(help.label, "Help")
        help.click()

        let guide = app.windows["Planner Help"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        XCTAssertEqual(guide.staticTexts["help-chapter-title"].label, "Getting started")
    }

    private func launch(language: String, locale: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["PLANNER_UI_TEST_CALENDAR"] = "1"
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-appLanguage", language]
        app.launch()
        return app
    }

    private func checkGuide(language: String, locale: String, title: String, first: String, today: String) {
        let app = launch(language: language, locale: locale)
        let help = app.menuBars.menuBarItems.matching(NSPredicate(format: "title IN %@", ["Help", "Справка"])).firstMatch
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        help.click()
        help.menuItems[title].click()

        let guide = app.windows[title]
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        let heading = guide.staticTexts["help-chapter-title"]
        XCTAssertEqual(heading.label, first)
        guide.staticTexts["help-topic-4"].click()
        XCTAssertEqual(heading.label, today)
        let attachment = XCTAttachment(screenshot: guide.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
