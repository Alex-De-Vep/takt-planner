import XCTest

@MainActor final class CalendarAgendaUITests: XCTestCase {
    func testModesMoveToEmptyDayAndUndo() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["PLANNER_UI_TEST_CALENDAR"] = "1"
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-calendarOpen", "YES"]
        app.launch()
        app.activate()
        let toggle = app.buttons["toggle-calendar-button"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let picker = element("calendar-agenda-mode", in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let list = element("calendar-agenda-list", in: app)
        XCTAssertLessThan(picker.frame.maxY, list.frame.minY + 2)
        choose("3 дня", in: app)

        let today = Calendar.current.startOfDay(for: .now)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let from = element("calendar-event-ui-meeting-" + key(today), in: app)
        let target = element("calendar-day-" + key(tomorrow), in: app)
        XCTAssertTrue(from.waitForExistence(timeout: 3))
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        // Захватываем внутри карточки, отдельно от заголовка дня и цветового маркера.
        from.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.4, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        let moved = element("calendar-event-ui-meeting-" + key(tomorrow), in: app)
        XCTAssertTrue(moved.waitForExistence(timeout: 5))
        XCTAssertFalse(from.exists)
        let undo = app.buttons["calendar-undo-move"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        undo.click()
        XCTAssertTrue(from.waitForExistence(timeout: 5))
        XCTAssertFalse(moved.exists)

        choose("Неделя", in: app)
        let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: today)!.start
        for offset in 0..<7 {
            let day = Calendar.current.date(byAdding: .day, value: offset, to: weekStart)!
            XCTAssertTrue(element("calendar-day-" + key(day), in: app).exists)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Calendar week"; screenshot.lifetime = .keepAlways; add(screenshot)
        toggle.click(); toggle.click()
        XCTAssertTrue(element("calendar-day-" + key(weekStart), in: app).waitForExistence(timeout: 3))
        app.terminate(); app.launch()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(element("calendar-day-" + key(weekStart), in: app).waitForExistence(timeout: 3))
    }

    func testNarrowAgendaAutoscrollsWhileDragging() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["PLANNER_UI_TEST_CALENDAR"] = "1"
        app.launchEnvironment["PLANNER_UI_TEST_CALENDAR_DENSE"] = "1"
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-calendarOpen", "YES",
                               "-calendarWidth", "320", "-calendarAgendaMode", "threeDays"]
        app.launch(); app.activate()
        let today = Calendar.current.startOfDay(for: .now)
        let third = Calendar.current.date(byAdding: .day, value: 2, to: today)!
        let source = element("calendar-event-ui-meeting-" + key(today), in: app)
        let list = element("calendar-agenda-list", in: app)
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(list.frame.width, 320)
        XCTAssertFalse(element("calendar-day-" + key(third), in: app).isHittable)
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.4, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)),
                   withVelocity: .slow, thenHoldForDuration: 4)
        XCTAssertTrue(element("calendar-event-ui-meeting-" + key(third), in: app).waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Calendar narrow after autoscroll"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testHorizontalLayoutMoveAndPersistence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["PLANNER_UI_TEST_CALENDAR"] = "1"
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-calendarOpen", "YES",
                               "-calendarWidth", "320", "-calendarAgendaMode", "threeDays"]
        app.launch(); app.activate()
        let toggle = app.buttons["calendar-agenda-layout"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.click()
        XCTAssertEqual(toggle.value as? String, "Горизонтальные колонки")

        let today = Calendar.current.startOfDay(for: .now)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let third = Calendar.current.date(byAdding: .day, value: 2, to: today)!
        let firstHeading = element("calendar-day-" + key(today), in: app)
        let secondHeading = element("calendar-day-" + key(tomorrow), in: app)
        XCTAssertEqual(firstHeading.frame.minY, secondHeading.frame.minY, accuracy: 2)
        XCTAssertGreaterThan(secondHeading.frame.minX, firstHeading.frame.maxX)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Calendar horizontal columns"; screenshot.lifetime = .keepAlways; add(screenshot)

        let source = element("calendar-event-ui-meeting-" + key(today), in: app)
        let list = element("calendar-agenda-list", in: app)
        // Удержание у правого края открывает третью колонку и позволяет отпустить событие в её пустой области.
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.4, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 4)
        XCTAssertTrue(element("calendar-event-ui-meeting-" + key(third), in: app).waitForExistence(timeout: 5))
        app.buttons["calendar-undo-move"].click()
        XCTAssertTrue(source.waitForExistence(timeout: 5))

        toggle.click()
        XCTAssertEqual(toggle.value as? String, "Вертикальный список")
        XCTAssertGreaterThan(secondHeading.frame.minY, firstHeading.frame.maxY)
        XCTAssertEqual(secondHeading.frame.minX, firstHeading.frame.minX, accuracy: 2)
        toggle.click()
        choose("День", in: app)
        XCTAssertFalse(toggle.isEnabled)
        choose("3 дня", in: app)
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertEqual(toggle.value as? String, "Горизонтальные колонки")

        app.terminate(); app.launch()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "Горизонтальные колонки")
        XCTAssertGreaterThan(secondHeading.frame.minX, firstHeading.frame.maxX)
    }

    func testCalendarResizesBeyond400AndKeepsWidth() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["PLANNER_UI_TEST_CALENDAR"] = "1"
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-calendarOpen", "YES",
                               "-calendarAgendaMode", "threeDays", "-calendarAgendaLayout", "horizontal"]
        app.launch(); app.activate()
        let list = element("calendar-agenda-list", in: app)
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        // Размер окна восстанавливается macOS отдельно от изолированных настроек теста.
        let initialCorner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -6, dy: -6))
        initialCorner.press(forDuration: 0.3, thenDragTo: initialCorner.withOffset(CGVector(dx: 1340 - window.frame.width, dy: 0)))
        let originalWindowWidth = window.frame.width
        let handle = list.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: -2, dy: 0))
        handle.press(forDuration: 0.3, thenDragTo: handle.withOffset(CGVector(dx: -240, dy: 0)))
        XCTAssertGreaterThan(list.frame.width, 450)
        XCTAssertEqual(window.frame.width, originalWindowWidth, accuracy: 2)
        let wideWidth = list.frame.width
        let toggle = app.buttons["toggle-calendar-button"]
        toggle.click(); toggle.click()
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertEqual(list.frame.width, wideWidth, accuracy: 2)
        app.terminate(); app.launch()
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertEqual(list.frame.width, wideWidth, accuracy: 2)

        // Уменьшаем окно: календарь переходит в накладной режим, сохраняя возможность изменения ширины.
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -6, dy: -6))
        corner.press(forDuration: 0.3, thenDragTo: corner.withOffset(CGVector(dx: 900 - window.frame.width, dy: 0)))
        XCTAssertEqual(window.frame.width, 900, accuracy: 3)
        XCTAssertEqual(list.frame.width, wideWidth - 16, accuracy: 2)
        let overlayHandle = list.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: -8, dy: 0))
        overlayHandle.press(forDuration: 0.3, thenDragTo: overlayHandle.withOffset(CGVector(dx: -160, dy: 0)))
        XCTAssertGreaterThan(list.frame.width, wideWidth + 100)
        XCTAssertGreaterThanOrEqual(list.frame.minX, window.frame.minX)
        XCTAssertLessThanOrEqual(list.frame.maxX, window.frame.maxX)
        XCTAssertEqual(window.frame.width, 900, accuracy: 3)
        XCTAssertTrue(toggle.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Wide calendar overlay"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }
    private func choose(_ title: String, in app: XCUIApplication) {
        let radio = app.radioButtons[title]
        if radio.exists { radio.click() } else { app.buttons[title].click() }
    }
    private func key(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
