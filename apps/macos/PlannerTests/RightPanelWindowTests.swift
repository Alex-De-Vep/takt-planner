import AppKit
import SwiftUI
import Testing
@testable import Planner

/// Восстановление состояния и переключение проверяются на нативном окне с пустыми представлениями.
@Suite(.serialized)
@MainActor
struct RightPanelWindowTests {
    @Test(arguments: [1100.0, 1140.0, 1170.0, 1180.0, 1400.0])
    func restoredChatSwitchesToCalendarWithoutResizingTheWindow(width: Double) async throws {
        let container = WorkspaceContainerController()
        container.view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        let workspace = container.workspace
        workspace.update(sidebar: AnyView(EmptyView()), tasks: AnyView(EmptyView()), detail: AnyView(EmptyView()),
            taskActions: AnyView(EmptyView()), isSidebarVisible: true, newFolderTitle: "Папка", toggleSidebarTitle: "Папки",
            folderTitle: "Входящие", taskCountTitle: "Задач: 1", newTaskTitle: "Создать", newChecklistItemTitle: "Подзадача",
            taskActionsTitle: "Действия с задачей", hasSelectedTask: true, newFolder: {}, newTask: {}, newChecklistItem: {},
            sidebarVisibilityChanged: { _ in })

        var presentations: [RightPanel?] = []
        func apply(_ panel: RightPanel?) {
            container.update(calendar: AnyView(EmptyView()), visible: panel != nil, width: panel == .assistant ? 420 : 340,
                sidebarVisible: true, panel: panel,
                minimumWidth: panel == .assistant ? CalendarPanelLayout.assistantMinimumWidth : CalendarPanelLayout.minimumWidth,
                maximumWidth: panel == .assistant ? CalendarPanelLayout.assistantMaximumWidth : CalendarPanelLayout.maximumWidth,
                widthChanged: { _ in }, visibilityChanged: { _ in }, updateToolbar: { active in
                    presentations.append(active)
                    workspace.updateRightPanelToolbar(active: active, calendarTitle: "Календарь", assistantTitle: "ИИ-чат",
                        headingTitle: active == .assistant ? "Помощник" : "Календарь", toggleCalendar: {}, toggleAssistant: {})
                })
            container.view.layoutSubtreeIfNeeded()
        }

        // Настройки открывают чат до того, как корневой контроллер получит NSWindow.
        apply(.assistant)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: width, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 560)
        window.contentViewController = container
        window.orderFront(nil)
        defer { window.orderOut(nil); container.detachWindow(); window.close() }

        func toolbarButton(_ suffix: String) throws -> NSButton {
            let toolbar = try #require(window.toolbar)
            let item = try #require(toolbar.items.first { $0.itemIdentifier == .init("Planner.\(suffix)") })
            let surface = try #require(item.view as? WorkspaceToolbarButtonSurface)
            return try #require(surface.contentView as? NSButton)
        }
        func centerX(_ button: NSButton) -> CGFloat {
            button.convert(button.bounds, to: nil).midX
        }
        func checkFrame(_ expected: NSRect) {
            #expect(abs(window.frame.width - expected.width) < 1)
            #expect(abs(window.frame.height - expected.height) < 1)
        }

        try await Task.sleep(for: .milliseconds(420))
        let original = window.frame
        let originalColumnCount = workspace.splitViewItems.count
        let isColumn = CalendarPanelLayout.isColumn(width: original.width, sidebarVisible: true)
        let originalDocumentWidth = workspace.documentColumnFrame(in: container.view).width
        #expect(originalColumnCount == (isColumn ? 5 : 3))

        let outer = try toolbarButton("RightPanelSwitch"), trailing = try toolbarButton("RightPanelToggle")
        let closeImage = try #require(trailing.image)
        #expect(outer.accessibilityIdentifier() == "toggle-calendar-button")
        #expect(trailing.accessibilityIdentifier() == "toggle-assistant-button")

        let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for panel in [RightPanel.calendar, .assistant, .calendar] {
            let index = presentations.count
            let outgoingIcon = outer.image
            let initialOuterX = centerX(outer), initialTrailingX = centerX(trailing)
            var outerPositions = [initialOuterX]
            apply(panel)
            #expect(try toolbarButton("RightPanelSwitch") === outer)
            #expect(try toolbarButton("RightPanelToggle") === trailing)
            if animated {
                #expect(presentations.count == index)
                #expect(trailing.image === closeImage && outer.image === outgoingIcon)
                try await Task.sleep(for: .milliseconds(90))
                #expect(presentations.count == index)
                #expect(trailing.image === closeImage && outer.image === outgoingIcon)
                #expect(abs(centerX(outer) - initialOuterX) <= 2)
                #expect(abs(centerX(trailing) - initialTrailingX) <= 2)
                checkFrame(original)
            }
            for _ in 0..<25 {
                try await Task.sleep(for: .milliseconds(25))
                #expect(abs(centerX(trailing) - initialTrailingX) <= 2)
                outerPositions.append(centerX(outer))
            }
            let finalOuterX = centerX(outer)
            let acceptable = (min(initialOuterX, finalOuterX) - 8)...(max(initialOuterX, finalOuterX) + 8)
            #expect(outerPositions.allSatisfy { acceptable.contains($0) })
            if animated, abs(finalOuterX - initialOuterX) > 20 {
                // Изменение ширины панели может сдвинуть внешнюю кнопку только к её конечному месту.
                let direction: CGFloat = finalOuterX > initialOuterX ? 1 : -1
                #expect(zip(outerPositions, outerPositions.dropFirst()).allSatisfy { pair in direction * (pair.1 - pair.0) >= -8 })
                #expect(outerPositions.dropFirst().dropLast().contains { abs($0 - initialOuterX) > 8 && abs($0 - finalOuterX) > 8 })
            }
            #expect(Array(presentations.dropFirst(index)) == [panel])
            #expect(try toolbarButton("RightPanelSwitch") === outer)
            #expect(try toolbarButton("RightPanelToggle") === trailing)
            #expect(trailing.image === closeImage && outer.image !== closeImage)
            #expect(trailing.accessibilityIdentifier() == (panel == .calendar ? "toggle-calendar-button" : "toggle-assistant-button"))
            checkFrame(original)
            #expect(workspace.splitViewItems.count == originalColumnCount)
            let documentWidth = workspace.documentColumnFrame(in: container.view).width
            if isColumn { #expect(documentWidth >= 319) }
            else { #expect(abs(documentWidth - originalDocumentWidth) < 1) }
        }

        if animated, width == 1140 {
            let index = presentations.count
            apply(.assistant)
            apply(nil)
            #expect(trailing.image === closeImage)
            try await Task.sleep(for: .milliseconds(650))
            #expect(Array(presentations.dropFirst(index)) == [nil])
            #expect(trailing.image !== closeImage)
        }

        apply(nil)
        #expect(try toolbarButton("RightPanelSwitch") === outer)
        #expect(try toolbarButton("RightPanelToggle") === trailing)
        #expect(trailing.image !== closeImage)
        try await Task.sleep(for: .milliseconds(400))
        checkFrame(original)
    }
}
