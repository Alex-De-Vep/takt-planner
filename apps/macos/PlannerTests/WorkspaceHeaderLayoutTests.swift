import AppKit
import SwiftUI
import Testing
@testable import Planner

/// Геометрию проверяем без показа окна, запуска приложения и обращения к календарям.
@MainActor
struct WorkspaceHeaderLayoutTests {
    @Test func wideCalendarFitsWindowAndRestoresPreferredWidth() throws {
        #expect(CalendarPanelLayout.panelWidth(1100) == 1100)
        #expect(CalendarPanelLayout.panelWidth(1600) == 1200)
        #expect(CalendarPanelLayout.overlayWidth(1200, windowWidth: 900) == 884)
        let container = WorkspaceContainerController()
        container.view.frame = CGRect(x: 0, y: 0, width: 2200, height: 800)
        var persistedWidths: [Double] = []
        func update() {
            container.update(calendar: AnyView(EmptyView()), visible: true, width: 1100, sidebarVisible: true,
                             widthChanged: { persistedWidths.append($0) }, visibilityChanged: { _ in })
            container.view.layoutSubtreeIfNeeded()
        }
        update()
        let calendar = try #require(container.workspace.splitViewItems.dropFirst(3).first).viewController
        #expect(abs(calendar.view.frame.width - 1100) <= 1)
        container.view.frame.size.width = 900
        update()
        #expect(calendar.parent === container)
        #expect(calendar.view.frame.minX >= 0 && calendar.view.frame.maxX <= container.view.bounds.maxX)
        #expect(calendar.view.frame.width == 884)
        container.view.frame.size.width = 2200
        update()
        #expect(calendar.parent === container.workspace)
        #expect(abs(calendar.view.frame.width - 1100) <= 1)
        #expect(persistedWidths.isEmpty)
        container.detachWindow()
    }

    @Test func nativeFullScreenHeaderIsNotCoveredByTheWindowedBackdrop() {
        let bounds = CGRect(x: 0, y: 0, width: 1400, height: 800)
        for sidebarVisible in [true, false] {
            for fullScreen in [true, false] {
                for calendar in [WorkspaceHeaderLayout.CalendarPlacement.closed, .column, .overlay] {
                    let layout = WorkspaceHeaderLayout(sidebarVisible: sidebarVisible, fullScreen: fullScreen,
                                                       calendarPlacement: calendar)
                    let regions = layout.regions(bounds: bounds, headerBottom: 748, sidebarTrailing: 240,
                                                 calendarLeading: 1060, scale: 2)
                    if fullScreen || sidebarVisible {
                        // Шапка полного экрана рисуется AppKit; стекло открытых панелей не перекрываем.
                        #expect(regions == WorkspaceHeaderLayout.Regions())
                    } else {
                        let right: CGFloat = calendar == .closed ? 1400 : 1060
                        #expect(regions.background.minX == 0)
                        #expect(regions.background.maxX == right && regions.separator.maxX == right)
                        #expect(regions.background.minY == 748 && regions.background.height == 52)
                        #expect(regions.separator.minX == 0 && regions.separator.height == 0.5)
                    }
                }
            }
        }
    }

    @Test func headerLayerStaysAboveBothCalendarPresentationsWithoutInterceptingInput() throws {
        let container = WorkspaceContainerController()
        let header = try #require(container.view.subviews.last as? WorkspaceHeaderBackdrop)
        #expect(container.view.wantsLayer && header.wantsLayer)
        #expect(header.hitTest(NSPoint(x: 10, y: 10)) == nil)
        let columns = container.workspace.splitViewItems.map { ObjectIdentifier($0.viewController) }
        for width in [CGFloat(1400), 900, 1400] {
            container.view.frame = CGRect(x: 0, y: 0, width: width, height: 700)
            container.update(calendar: AnyView(EmptyView()), visible: true, width: 340, sidebarVisible: true,
                             widthChanged: { _ in }, visibilityChanged: { _ in })
            #expect(container.view.subviews.last === header)
            #expect(container.workspace.splitViewItems.prefix(3).map { ObjectIdentifier($0.viewController) } == columns)
        }
        container.detachWindow()
        container.view.needsLayout = true
        container.view.layoutSubtreeIfNeeded()
        #expect(header.superview == nil)
    }

    @Test func matchingSidebarHeadersAndNativeTaskSectionSurviveModeChanges() throws {
        let controller = WorkspaceSplitController()
        let calendar = NSViewController()
        calendar.view = NSView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1400, height: 700)
        controller.attachCalendarSidebar(calendar, width: 340, animate: false)
        let calendarItem = try #require(controller.splitViewItems.first { $0.viewController === calendar })
        let insetItem = try #require(controller.splitViewItems.last)
        let columns = controller.splitViewItems.map { ObjectIdentifier($0.viewController) }
        let toolbar = NSToolbar()
        let search = try #require(controller.toolbar(toolbar, itemForItemIdentifier: .init("Planner.Search"), willBeInsertedIntoToolbar: true))
        for fullScreen in [true, false, true, false] {
            controller.updateFullScreenMode(fullScreen)
            #expect(controller.sidebarItem.allowsFullHeightLayout)
            #expect(controller.splitViewItems.allSatisfy { $0.titlebarSeparatorStyle == (fullScreen ? .line : .none) })
            #expect(calendarItem.allowsFullHeightLayout)
            #expect(controller.splitViewItems.map { ObjectIdentifier($0.viewController) } == columns)
            #expect(calendarItem.viewController === calendar)
            // Зазор не сужает общую split view; его скрытая граница сохраняет отдельную шапку календаря.
            #expect(controller.view.frame.width == 1400)
            #expect(insetItem.minimumThickness == 8 && insetItem.maximumThickness == 8)
            #expect(insetItem.holdingPriority < .required)
            let edge = try #require(controller.toolbar(toolbar, itemForItemIdentifier: .init("Planner.CalendarTrailingBoundary"),
                                                       willBeInsertedIntoToolbar: true) as? NSTrackingSeparatorToolbarItem)
            #expect(edge.isHidden && edge.splitView === controller.splitView && edge.dividerIndex == 3)
            #expect(controller.splitView(controller.splitView, shouldHideDividerAt: 3))
            let sidebarIdentifier: NSToolbarItem.Identifier = .sidebarTrackingSeparator
            #expect(controller.toolbarDefaultItemIdentifiers(toolbar)[2] == sidebarIdentifier)
            let sidebarSeparator = try #require(controller.toolbar(toolbar, itemForItemIdentifier: sidebarIdentifier,
                                                                    willBeInsertedIntoToolbar: true) as? NSTrackingSeparatorToolbarItem)
            #expect(sidebarSeparator.splitView === controller.splitView && sidebarSeparator.dividerIndex == 0)
            let separator = try #require(controller.toolbar(toolbar, itemForItemIdentifier: .init("Planner.DetailTrackingSeparator"), willBeInsertedIntoToolbar: true))
            let tracking = try #require(separator as? NSTrackingSeparatorToolbarItem)
            #expect(tracking.splitView === controller.splitView && tracking.dividerIndex == 1)
            // Только документ продолжается под правой панелью; левую часть не затрагиваем.
            #expect(controller.splitViewItems[2].automaticallyAdjustsSafeAreaInsets)
            #expect(!controller.sidebarItem.automaticallyAdjustsSafeAreaInsets)
            #expect(!controller.splitViewItems[1].automaticallyAdjustsSafeAreaInsets)
            #expect(controller.toolbar(toolbar, itemForItemIdentifier: .init("Planner.Search"), willBeInsertedIntoToolbar: true) === search)
            // Открытие и закрытие календаря сохраняют контроллеры колонок и доступность изменения ширины.
            controller.collapseCalendarSidebar(animate: false)
            #expect(calendarItem.isCollapsed && insetItem.isCollapsed)
            controller.attachCalendarSidebar(calendar, width: 360, animate: false)
            #expect(!calendarItem.isCollapsed && !insetItem.isCollapsed)
            #expect(calendarItem.minimumThickness == 320)
            #expect(calendarItem.maximumThickness == 1200)
            #expect(controller.splitViewItems.map { ObjectIdentifier($0.viewController) } == columns)
        }
        controller.detachCalendarSidebar()
        #expect(controller.splitViewItems.count == 3)
    }

    @Test func fullScreenReservesACompleteHeadingAndStandardSearchWidth() {
        for heading in [CGFloat(95), 120, 175] {
            let layout = WorkspaceHeaderLayout(sidebarVisible: true, fullScreen: true,
                                               calendarPlacement: .closed, preferredHeadingWidth: heading)
            let widths = layout.contentWidths(available: layout.minimumTaskWidth - 36)
            #expect(widths.heading >= heading)
            #expect(widths.search == WorkspaceHeaderLayout.standardSearchWidth)
            #expect(widths.heading + widths.search + WorkspaceHeaderLayout.headingSearchSpacing <= layout.minimumTaskWidth - 36)
        }
        // За пределами максимальной ширины колонки сохраняются минимальный поиск и подсказка полного названия.
        let longHeading = WorkspaceHeaderLayout(sidebarVisible: true, fullScreen: true,
                                                calendarPlacement: .closed, preferredHeadingWidth: 500)
        #expect(longHeading.minimumTaskWidth == 420)
        #expect(longHeading.contentWidths(available: 384).search == WorkspaceHeaderLayout.minimumSearchWidth)
        // Обычное окно сохраняет прежние размеры, независимо от длинного названия.
        let windowed = WorkspaceHeaderLayout(sidebarVisible: true, fullScreen: false,
                                             calendarPlacement: .closed, preferredHeadingWidth: 500)
        #expect(windowed.minimumTaskWidth == 260)
    }

    @Test func calendarTitleBelongsToItsToolbarSectionOnlyWhileOpen() throws {
        let controller = WorkspaceSplitController(), toolbar = NSToolbar()
        let headingID = NSToolbarItem.Identifier("Planner.CalendarHeading")
        let calendarID = NSToolbarItem.Identifier("Planner.RightPanelToggle")
        let heading = try #require(controller.toolbar(toolbar, itemForItemIdentifier: headingID, willBeInsertedIntoToolbar: true))
        let button = try #require(controller.toolbar(toolbar, itemForItemIdentifier: calendarID, willBeInsertedIntoToolbar: true))
        #expect(!heading.isBordered)
        for title in ["Календарь", "Calendar"] {
            controller.updateCalendarHeading(title: title)
            for column in [true, false] {
                controller.setCalendarToolbar(column: column, visible: true)
                let ids = controller.toolbarDefaultItemIdentifiers(toolbar)
                let headingIndex = try #require(ids.firstIndex(of: headingID))
                let buttonIndex = try #require(ids.firstIndex(of: calendarID))
                #expect(headingIndex < buttonIndex && ids.filter { $0 == headingID }.count == 1)
                if column { #expect(ids[headingIndex - 1] == .init("Planner.CalendarBoundary")) }
                #expect(controller.toolbar(toolbar, itemForItemIdentifier: headingID, willBeInsertedIntoToolbar: true) === heading)
                #expect(controller.toolbar(toolbar, itemForItemIdentifier: calendarID, willBeInsertedIntoToolbar: true) === button)
                controller.setCalendarToolbar(column: false, visible: false)
                #expect(!controller.toolbarDefaultItemIdentifiers(toolbar).contains(headingID))
            }
        }
    }

    @Test func titleAndSearchShareSpaceInsteadOfHidingTheTitle() {
        let layout = WorkspaceHeaderLayout(sidebarVisible: false, fullScreen: false, calendarPlacement: .closed)
        for available in [CGFloat(200), 224, 260, 300, 420] {
            let widths = layout.contentWidths(available: available)
            #expect(widths.heading >= 80)
            #expect(widths.search >= 100 && widths.search <= 180)
            #expect(widths.heading + widths.search + WorkspaceHeaderLayout.headingSearchSpacing <= available)
        }
        #expect(layout.minimumTaskWidth == 400)
        #expect(!CalendarPanelLayout.isColumn(width: 1000, sidebarVisible: false))
        #expect(CalendarPanelLayout.isColumn(width: 1100, sidebarVisible: false))
        #expect(CalendarPanelLayout.isColumn(width: 1000, sidebarVisible: false, fullScreen: true))
        #expect(!CalendarPanelLayout.isColumn(width: 1100, sidebarVisible: true))
        // На границе помещаемости резервируем внешний зазор, не увеличивая окно принудительно.
        let threshold = CalendarPanelLayout.minimumMainWidth(sidebarVisible: true, fullScreen: true) + 320 + 8
        #expect(!CalendarPanelLayout.isColumn(width: threshold - 1, sidebarVisible: true, fullScreen: true))
        #expect(CalendarPanelLayout.isColumn(width: threshold, sidebarVisible: true, fullScreen: true))
    }

    @Test func calendarHeaderDoesNotFlashDuringOpeningClosingOrAnInterruptedTransition() async throws {
        let controller = WorkspaceSplitController(), toolbar = NSToolbar()
        func item(_ suffix: String) throws -> NSToolbarItem {
            try #require(controller.toolbar(toolbar, itemForItemIdentifier: .init("Planner.\(suffix)"),
                                            willBeInsertedIntoToolbar: true))
        }
        let headingItem = try item("CalendarHeading"), button = try item("RightPanelToggle")
        let heading = try #require(headingItem.view)
        controller.updateCalendarHeading(title: "Календарь")
        for column in [true, false] {
            controller.beginCalendarHeaderTransition()
            controller.setCalendarToolbar(column: column, visible: true)
            // Повторное обновление раскладки не проявляет подпись рядом с кнопкой.
            controller.setCalendarToolbar(column: column, visible: true)
            #expect(heading.alphaValue == 0 && !headingItem.isHidden)
            let boundary = try #require(item("CalendarBoundary") as? NSTrackingSeparatorToolbarItem)
            #expect(!boundary.isHidden && boundary.dividerIndex == 2 && boundary.splitView === controller.splitView)

            controller.finishCalendarHeaderTransition(afterLayout: true)
            // Закрытие началось раньше отложенного показа заголовка от предыдущего раскрытия.
            controller.beginCalendarHeaderTransition()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(heading.alphaValue == 0)
            controller.setCalendarToolbar(column: false, visible: false)
            controller.finishCalendarHeaderTransition(afterLayout: false)
            #expect(heading.alphaValue == 0)

            controller.beginCalendarHeaderTransition()
            controller.setCalendarToolbar(column: column, visible: true)
            controller.finishCalendarHeaderTransition(afterLayout: true)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(heading.alphaValue == 1)
            // Нативная граница удерживает место секции на протяжении всего перехода.
            #expect(try !item("CalendarBoundary").isHidden)
            #expect(try item("CalendarHeading") === headingItem)
            #expect(try item("RightPanelToggle") === button)
        }
    }

    @Test func separatorUsesOnePhysicalPixelAndEmptyGeometryDrawsNothing() {
        let layout = WorkspaceHeaderLayout(sidebarVisible: false, fullScreen: false, calendarPlacement: .overlay)
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        for scale in [CGFloat(1), 2] {
            let regions = layout.regions(bounds: bounds, headerBottom: 547.25, sidebarTrailing: 0,
                                         calendarLeading: 560, scale: scale)
            #expect(regions.separator.height == 1 / scale)
            #expect(regions.separator.minY * scale == (547.25 * scale).rounded())
        }
        #expect(layout.regions(bounds: bounds, headerBottom: 600, sidebarTrailing: 0,
                               calendarLeading: 560, scale: 2) == WorkspaceHeaderLayout.Regions())
        #expect(layout.regions(bounds: bounds, headerBottom: 548, sidebarTrailing: 0,
                               calendarLeading: 0, scale: 2) == WorkspaceHeaderLayout.Regions())
    }

    @Test func sidebarButtonsChangeSurfaceWithoutReplacingControlsOrSearch() throws {
        let controller = WorkspaceSplitController(), toolbar = NSToolbar()
        func item(_ suffix: String) throws -> NSToolbarItem {
            try #require(controller.toolbar(toolbar, itemForItemIdentifier: .init("Planner.\(suffix)"),
                                            willBeInsertedIntoToolbar: true))
        }
        let folder = try item("NewFolder"), toggle = try item("ToggleSidebar"), heading = try item("FolderHeading")
        let folderSurface = try #require(folder.view as? WorkspaceToolbarButtonSurface)
        let toggleSurface = try #require(toggle.view as? WorkspaceToolbarButtonSurface)
        let folderButton = try #require(folderSurface.contentView as? NSButton)
        let toggleButton = try #require(toggleSurface.contentView as? NSButton)
        let search = try #require(item("Search").view as? WorkspaceToolbarSearchView)
        let searchField = search.searchField
        let sidebarSeparator = try #require(controller.toolbar(toolbar, itemForItemIdentifier: .sidebarTrackingSeparator,
                                                               willBeInsertedIntoToolbar: true))
        let calendarItem = try item("RightPanelToggle")
        let calendarSurface = try #require((calendarItem.view as? WorkspaceRightPanelSlot)?.surface)
        let calendarButton = try #require(calendarSurface.contentView as? NSButton)
        controller.updateSearch(text: "Запрос", title: "Поиск", clearTitle: "Очистить", changed: { _ in })
        let columns = controller.splitViewItems.map { ObjectIdentifier($0.viewController) }
        var createdFolders = 0
        for visible in [true, false, true] {
            controller.updateRightPanelToolbar(active: visible ? .calendar : nil,
                calendarTitle: "Календарь", assistantTitle: "Помощник", headingTitle: "Календарь",
                toggleCalendar: {}, toggleAssistant: {})
            controller.setCalendarToolbar(column: true, visible: visible)
            #expect(calendarSurface.presentation == (visible ? .sidebar : .circle))
            #expect(calendarSurface.contentView === calendarButton && (calendarItem.view as? WorkspaceRightPanelSlot)?.surface === calendarSurface)
            #expect(calendarButton.borderShape == (visible ? .capsule : .circle))
            controller.update(sidebar: AnyView(EmptyView()), tasks: AnyView(EmptyView()), detail: AnyView(EmptyView()),
                taskActions: AnyView(EmptyView()), isSidebarVisible: visible, newFolderTitle: "Новая папка",
                toggleSidebarTitle: visible ? "Скрыть папки" : "Показать папки", folderTitle: "Входящие",
                taskCountTitle: "Задач: 4", newTaskTitle: "Новая задача", newChecklistItemTitle: "Подзадача",
                taskActionsTitle: "Действия", hasSelectedTask: true, newFolder: { createdFolders += 1 },
                newTask: {}, newChecklistItem: {}, sidebarVisibilityChanged: { _ in })
            #expect(folder.isHidden == !visible && !heading.isHidden)
            let toolbarIDs = controller.toolbarDefaultItemIdentifiers(toolbar)
            #expect(toolbarIDs.contains(.sidebarTrackingSeparator) == visible)
            if !visible {
                let toggleIndex = try #require(toolbarIDs.firstIndex(of: .init("Planner.ToggleSidebar")))
                #expect(toolbarIDs[toggleIndex + 1] == .init("Planner.FolderHeading"))
            }
            #expect(controller.toolbar(toolbar, itemForItemIdentifier: .sidebarTrackingSeparator,
                                       willBeInsertedIntoToolbar: true) === sidebarSeparator)
            #expect(folderSurface.presentation == .sidebar)
            #expect(toggleSurface.presentation == (visible ? .sidebar : .circle))
            #expect(folderButton.showsBorderOnlyWhileMouseInside && folderButton.borderShape == .capsule)
            #expect(toggleButton.borderShape == (visible ? .capsule : .circle))
            #expect(toggleSurface.contentView === toggleButton && folderSurface.contentView === folderButton)
            #expect(search.searchField === searchField && searchField.stringValue == "Запрос")
            #expect(controller.splitViewItems.map { ObjectIdentifier($0.viewController) } == columns)
        }
        folderButton.performClick(nil)
        #expect(createdFolders == 1)
        // Системный разделитель шапки совпадает с границей списка в обоих режимах окна.
        #expect(try item("DetailTrackingSeparator") is NSTrackingSeparatorToolbarItem)
    }
}
