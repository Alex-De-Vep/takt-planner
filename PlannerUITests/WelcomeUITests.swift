import XCTest

@MainActor
final class WelcomeUITests: XCTestCase {
    func testFirstLaunchShowsFeaturesAndStorageChoices() {
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["PLANNER_SHOW_WELCOME"] = "1"
        app.launch()
        let local = app.buttons["welcome-local"]
        XCTAssertTrue(local.waitForExistence(timeout: 5))
        let sync = app.buttons["welcome-sync"]
        XCTAssertTrue(sync.exists)
        XCTAssertFalse(app.textFields["sync-email"].exists)
        for feature in ["tasks", "calendar", "assistant"] {
            XCTAssertTrue(app.staticTexts["welcome-feature-\(feature)"].exists)
        }
        sync.click()
        XCTAssertTrue(app.textFields["sync-email"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sync-submit"].exists)
    }
}
