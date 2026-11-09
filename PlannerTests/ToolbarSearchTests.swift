import AppKit
import Testing
@testable import Planner

/// Проверяем связь нативного поля с состоянием поиска без открытия окна.
@MainActor
struct ToolbarSearchTests {
    @Test func searchSendsEditsAndAcceptsFolderResetWithoutEcho() throws {
        let controller = WorkspaceSplitController()
        var edits: [String] = []
        controller.updateSearch(text: "", title: "Поиск", clearTitle: "Очистить поиск", changed: { edits.append($0) })
        let item = try #require(controller.toolbar(NSToolbar(),
            itemForItemIdentifier: NSToolbarItem.Identifier("Planner.Search"),
            willBeInsertedIntoToolbar: true))
        let view = try #require(item.view as? WorkspaceToolbarSearchView)
        let field = view.searchField
        #expect(field.placeholderString == "Поиск")
        #expect(field.usesSingleLineMode && field.focusRingType == .none)
        #expect(view.clearButton.isHidden)
        field.stringValue = "Описание задачи"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(edits == ["Описание задачи"])
        #expect(!view.clearButton.isHidden)
        controller.updateSearch(text: "Описание задачи", title: "Search", clearTitle: "Clear search", changed: { edits.append($0) })
        #expect(view.searchField === field && field.stringValue == "Описание задачи")
        #expect(field.placeholderString == "Search" && edits.count == 1)
        // Смена раздела очищает запрос из модели, не порождая повторного пользовательского действия.
        controller.updateSearch(text: "", title: "Поиск", clearTitle: "Очистить поиск", changed: { edits.append($0) })
        #expect(field.stringValue.isEmpty && edits.count == 1)
        #expect(view.clearButton.isHidden)
        // Очистка кнопкой и Escape отправляет новое значение сразу, без ожидания Enter.
        view.setText("Первый запрос")
        view.clearButton.performClick(nil)
        #expect(field.stringValue.isEmpty && edits == ["Описание задачи", ""])
        view.setText("Второй запрос")
        #expect(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(field.stringValue.isEmpty && view.clearButton.isHidden && edits.count == 3)
    }

    @Test func searchStaysAboveTaskListAndCalendarRemainsTrailing() throws {
        let controller = WorkspaceSplitController(), toolbar = NSToolbar()
        let identifier = NSToolbarItem.Identifier("Planner.Search")
        controller.updateSearch(text: "Сохранить запрос", title: "Поиск", clearTitle: "Очистить поиск", changed: { _ in })
        let original = try #require(controller.toolbar(toolbar, itemForItemIdentifier: identifier,
            willBeInsertedIntoToolbar: true))
        let view = try #require(original.view as? WorkspaceToolbarSearchView)
        for (column, visible) in [(false, false), (true, true), (false, true), (false, false)] {
            controller.setCalendarToolbar(column: column, visible: visible)
            let identifiers = controller.toolbarDefaultItemIdentifiers(toolbar)
            // Невидимая граница внешнего отступа календаря не является кнопкой шапки.
            #expect(identifiers.last { $0 != NSToolbarItem.Identifier("Planner.CalendarTrailingBoundary") }
                    == NSToolbarItem.Identifier("Planner.RightPanelToggle"))
            #expect(identifiers.filter { $0 == identifier }.count == 1)
            let index = try #require(identifiers.firstIndex(of: identifier))
            #expect(identifiers[index - 2] == NSToolbarItem.Identifier("Planner.FolderHeading"))
            #expect(identifiers[index - 1] == .flexibleSpace)
            #expect(identifiers[index + 1] == NSToolbarItem.Identifier("Planner.DetailTrackingSeparator"))
            let current = try #require(controller.toolbar(toolbar, itemForItemIdentifier: identifier,
                willBeInsertedIntoToolbar: true))
            #expect(current === original && current.view === view && view.searchField.stringValue == "Сохранить запрос")
        }
    }

    @Test func searchTextDoesNotOverlapIconsAtSupportedWidths() throws {
        let view = WorkspaceToolbarSearchView()
        let field = view.searchField
        field.placeholderString = "Поиск"
        for width in [CGFloat(100), 140, 180] {
            view.setAvailableWidth(width)
            view.frame.size = NSSize(width: width, height: 32)
            view.layoutSubtreeIfNeeded()
            for text in ["", "Длинный поисковый запрос"] {
                view.setText(text)
                view.layoutSubtreeIfNeeded()
                #expect(!field.isHidden && field.frame.height == field.intrinsicContentSize.height)
                #expect(abs(field.frame.midY - view.bounds.midY) < 0.5)
                // AppKit округляет рамку значка с чётной высотой и текста с нечётной высотой до 0,5 pt.
                #expect(abs(field.frame.midY - view.searchIcon.frame.midY) <= 0.5)
                #expect(abs(field.frame.midY - view.clearButton.frame.midY) < 0.5)
                #expect(field.frame.width > 30)
                #expect(field.frame.minX > view.searchIcon.frame.maxX)
                #expect(field.frame.maxX < view.clearButton.frame.minX)
            }
        }
    }
}
