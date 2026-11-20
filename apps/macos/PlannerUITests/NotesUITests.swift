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
        app.typeText("Заметки проекта")
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

        app.buttons["toggle-assistant-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let noteContext = app.staticTexts["Заметка · Заметки проекта"].firstMatch
        XCTAssertTrue(noteContext.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Папка: Мои заметки"].exists)
        app.descendants(matching: .any).matching(identifier: "tasks-mode").firstMatch.click()
        XCTAssertFalse(noteContext.exists)
    }

    func testCreatedTaskAndNoteAreFullyVisibleAfterScrolling() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["PLANNER_UI_TEST_CALENDAR"] = "1"
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-appLanguage", "ru"]
        app.launch()
        app.activate()

        let folder = app.buttons["new-folder-button"]
        XCTAssertTrue(folder.waitForExistence(timeout: 8))
        folder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let folderName = app.textFields["folder-name-field"]
        XCTAssertTrue(folderName.waitForExistence(timeout: 5))
        folderName.typeText("Видимость")
        app.buttons["save-folder-button"].click()

        let notesMode = app.descendants(matching: .any)["notes-mode"].firstMatch
        XCTAssertTrue(notesMode.waitForExistence(timeout: 5))
        let create = app.buttons["new-task-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let taskTitle = app.descendants(matching: .any)["task-title-field"].firstMatch
        let noteTitle = app.textFields["note-title"]

        func verifyCreation(in listID: String, mode: XCUIElement, title: XCUIElement, prefix: String) {
            for _ in 0..<10 { create.click() }
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            title.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
            app.typeText(prefix + " верх")
            let list = app.descendants(matching: .any)[listID].firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 5))
            let previousFirst = list.staticTexts[prefix + " верх"].firstMatch
            XCTAssertTrue(previousFirst.waitForExistence(timeout: 5))
            let threshold = max(list.frame.minY, mode.frame.maxY)
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).scroll(byDeltaX: 0, deltaY: -625)
            XCTAssertTrue(!previousFirst.exists || previousFirst.frame.minY < threshold,
                          "Перед созданием начало списка должно быть прокручено")

            create.click()
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            title.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
            app.typeText(prefix + " новая")
            let newRowTitle = list.staticTexts[prefix + " новая"].firstMatch
            XCTAssertTrue(newRowTitle.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(newRowTitle.frame.minY, threshold - 1, "Заголовок новой строки должен быть ниже переключателя")
            XCTAssertLessThanOrEqual(newRowTitle.frame.maxY, list.frame.maxY, "Заголовок новой строки должен быть виден целиком")
        }

        let tasksMode = app.descendants(matching: .any)["tasks-mode"].firstMatch
        verifyCreation(in: "task-list", mode: tasksMode, title: taskTitle, prefix: "Задача")
        notesMode.click()
        verifyCreation(in: "note-list", mode: notesMode, title: noteTitle, prefix: "Заметка")
    }

    func testDeleteInNoteEditorAndList() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["PLANNER_UI_TEST_CALENDAR"] = "1"
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-appLanguage", "ru"]
        app.launch()
        app.activate()

        let newFolder = app.buttons["new-folder-button"]
        XCTAssertTrue(newFolder.waitForExistence(timeout: 8))
        newFolder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let folder = app.textFields["folder-name-field"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.typeText("Проверка удаления")
        app.buttons["save-folder-button"].click()
        let mode = app.descendants(matching: .any)["notes-mode"].firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.click()

        let create = app.buttons["new-task-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let title = app.textFields["note-title"]
        let list = app.descendants(matching: .any)["note-list"].firstMatch

        func makeNote(_ name: String) -> XCUIElement {
            create.click()
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            let blankTitle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", ""), object: title)
            XCTAssertEqual(XCTWaiter.wait(for: [blankTitle], timeout: 5), .completed)
            app.typeText(name)
            XCTAssertEqual(title.value as? String, name)
            let row = list.staticTexts[name].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            return row
        }

        let neighbour = makeNote("Соседняя заметка")
        _ = makeNote("Целевая заметкаа")
        app.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(title.value as? String, "Целевая заметка")

        let removed = list.staticTexts["Целевая заметка"].firstMatch
        removed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(removed.waitForNonExistence(timeout: 5))
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertTrue(neighbour.exists)

        let second = makeNote("Вторая заметка")
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.typeText(XCUIKeyboardKey.forwardDelete.rawValue)
        XCTAssertTrue(second.waitForNonExistence(timeout: 5))
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))

        let trash = app.descendants(matching: .any)["sidebar-deleted-notes"].firstMatch
        trash.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(removed.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        removed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let restore = app.buttons["Восстановить"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.click()
        XCTAssertTrue(removed.waitForNonExistence(timeout: 5))
    }

    func testRecordingCardClicksAndRestoresAudioAfterRestart() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLANNER_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["PLANNER_UI_TEST_CALENDAR"] = "1"
        app.launchEnvironment["PLANNER_UI_TEST_VOICE"] = "1"
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-appLanguage", "ru"]
        app.launch()

        func click(_ element: XCUIElement, line: UInt = #line) {
            guard element.exists || element.waitForExistence(timeout: 8) else {
                add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
                XCTFail("Кнопка или строка недоступна: \(element.debugDescription)", line: line)
                return
            }
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }

        let mode = app.descendants(matching: .any).matching(identifier: "notes-mode").firstMatch
        click(app.buttons["new-folder-button"])
        let folderName = app.textFields["folder-name-field"]
        XCTAssertTrue(folderName.waitForExistence(timeout: 5))
        folderName.typeText("Аудиопроверка")
        click(app.buttons["save-folder-button"])
        click(mode)
        click(app.buttons["new-task-button"])
        let voice = app.buttons["note-record-voice"]
        let call = app.buttons["note-record-call"]
        let toggle = app.buttons["note-toggle-recording"]
        let finish = app.buttons["note-finish-recording"]
        let transcribe = app.buttons["note-transcribe"]
        let discard = app.buttons["note-discard-recording"]
        let reveal = app.buttons["note-show-recording"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        let create = app.buttons["new-task-button"]
        XCTAssertEqual(voice.frame.midY, create.frame.midY, accuracy: 3)
        XCTAssertEqual(call.frame.midY, create.frame.midY, accuracy: 3)

        func pauseResumeAndFinish(_ start: XCUIElement) {
            click(start)
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            XCTAssertEqual(toggle.label, "Пауза")
            XCTAssertGreaterThan(finish.frame.minX, toggle.frame.maxX)
            click(toggle)
            XCTAssertEqual(toggle.label, "Продолжить")
            click(toggle)
            XCTAssertEqual(toggle.label, "Пауза")
            click(toggle)
            XCTAssertEqual(toggle.label, "Продолжить")
            click(finish)
            XCTAssertTrue(transcribe.waitForExistence(timeout: 5))
            XCTAssertFalse(finish.exists)
            XCTAssertFalse(start.isEnabled)
        }

        pauseResumeAndFinish(voice)
        app.terminate()
        app.launch()
        click(app.descendants(matching: .any).matching(identifier: "folder-row-Аудиопроверка").firstMatch)
        click(mode)
        click(app.staticTexts["Новая заметка"].firstMatch)
        XCTAssertTrue(transcribe.waitForExistence(timeout: 5))
        XCTAssertTrue(reveal.isEnabled)
        XCTAssertFalse(voice.isEnabled)

        click(transcribe)
        let closeModelPicker = app.buttons["Готово"].firstMatch
        click(closeModelPicker)
        click(reveal)
        XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.finder").wait(for: .runningForeground, timeout: 5))
        app.activate()
        click(discard)
        let warning = app.staticTexts["Удалить временную запись?"].firstMatch
        let dialog = app.windows.containing(.staticText, identifier: "Удалить временную запись?").firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        click(dialog.buttons["Отмена"].firstMatch)
        XCTAssertTrue(transcribe.exists)
        click(discard)
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        let confirm = dialog.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@",
                                                        "Удалить запись", "note-discard-recording")).firstMatch
        click(confirm)
        XCTAssertFalse(transcribe.exists)

        pauseResumeAndFinish(call)
        XCTAssertTrue(app.staticTexts["Запись звонка"].exists)
        XCTAssertTrue(reveal.isEnabled)
    }
}
