import XCTest

@MainActor final class NotificationSettingsUITests: XCTestCase {
    func testDailyReminderSettingsPersistAndTestActionIsAvailable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["PLANNER_UI_TEST_CALENDAR"] = "1"
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch(); app.activate()
        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.click()
        let review = element("review-notifications-toggle", app)
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertFalse(element("review-notification-time", app).exists)
        review.click()
        XCTAssertTrue(element("review-notification-time", app).waitForExistence(timeout: 3))
        let weekdays = element("review-weekdays-toggle", app)
        XCTAssertTrue(weekdays.exists); weekdays.click()
        let selectedWeekdays = weekdays.value as? String
        let test = app.buttons["test-notification-button"]
        XCTAssertTrue(test.isEnabled); test.click()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Notification settings"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate(); app.launch(); app.activate()
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.click()
        XCTAssertTrue(element("review-notification-time", app).waitForExistence(timeout: 5))
        XCTAssertEqual(weekdays.value as? String, selectedWeekdays)
        review.click()
        XCTAssertFalse(element("review-notification-time", app).exists)
    }

    func testCalendarShowsMultipleAlarmsAndCanRemoveAnAbsoluteAlarm() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["PLANNER_UI_TEST_CALENDAR"] = "1"
        app.launchEnvironment["PLANNER_UI_TEST_CALENDAR_ALARMS"] = "1"
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-calendarOpen", "YES"]
        app.launch(); app.activate()
        let card = app.descendants(matching: .button).matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendar-event-ui-meeting-")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10)); card.click()
        let relative = app.popUpButtons["calendar-alarm-offset-ui-relative"]
        XCTAssertTrue(relative.waitForExistence(timeout: 5))
        XCTAssertTrue(element("calendar-alarm-date-ui-absolute", app).exists)
        relative.click(); app.menuItems["За 5 минут"].click()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Calendar multiple and absolute alerts"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["remove-calendar-alarm-ui-absolute"].click()
        XCTAssertFalse(element("calendar-alarm-date-ui-absolute", app).exists)
        app.buttons["Сохранить"].click()
        card.click()
        XCTAssertTrue(relative.waitForExistence(timeout: 5))
        XCTAssertEqual(relative.value as? String, "За 5 минут")
        XCTAssertFalse(element("calendar-alarm-date-ui-absolute", app).exists)
        app.buttons["clear-calendar-alarms"].click()
        app.buttons["Сохранить"].click()
        card.click()
        XCTAssertTrue(app.buttons["add-calendar-alarm"].waitForExistence(timeout: 5))
        XCTAssertFalse(relative.exists)
        app.buttons["Отмена"].click()
    }

    private func element(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }
}
