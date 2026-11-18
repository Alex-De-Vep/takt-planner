import AppKit
import SwiftUI
import Testing
@testable import Planner

/// Восстановление состояния и переключение проверяются на нативном окне с пустыми представлениями.
@Suite(.serialized)
@MainActor
struct RightPanelWindowTests {
    @Test(arguments: [RightPanel.assistant, .calendar])
    func overlayHidesCoveredActionsAndKeepsItsHeadingLeading(panel: RightPanel) async throws {
        let container = WorkspaceContainerController()
        let workspace = container.workspace
        let size = NSSize(width: 1050, height: 700)
        container.view.frame.size = size
        workspace.update(sidebar: AnyView(EmptyView()), tasks: AnyView(EmptyView()), detail: AnyView(EmptyView()),
            taskActions: AnyView(EmptyView()), isSidebarVisible: true, newFolderTitle: "Папка", toggleSidebarTitle: "Папки",
            folderTitle: "Входящие", taskCountTitle: "Задач: 1", newTaskTitle: "Создать", newChecklistItemTitle: "Подзадача",
            taskActionsTitle: "Действия с задачей", hasSelectedTask: true, newFolder: {}, newTask: {}, newChecklistItem: {},
            sidebarVisibilityChanged: { _ in })
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = container
        window.orderFront(nil)
        defer { window.orderOut(nil); container.detachWindow(); window.close() }

        var calendarClicks = 0
        var assistantClicks = 0
        func apply(_ width: CGFloat, visible: Bool = true) {
            container.update(calendar: AnyView(EmptyView()), visible: visible, width: width, sidebarVisible: true, panel: panel,
                maximumWidth: CalendarPanelLayout.maximumWidth, widthChanged: { _ in }, visibilityChanged: { _ in },
                updateToolbar: { active in
                    workspace.updateRightPanelToolbar(active: active, calendarTitle: "Календарь", assistantTitle: "ИИ-чат",
                        headingTitle: active == .assistant ? "Помощник" : "Календарь",
                        toggleCalendar: { calendarClicks += 1 }, toggleAssistant: { assistantClicks += 1 })
                })
            container.view.layoutSubtreeIfNeeded()
        }
        func viewForItem(_ suffix: String) throws -> NSView {
            try #require(window.toolbar?.items.first { $0.itemIdentifier == .init("Planner.\(suffix)") }?.view)
        }
        func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

        try await Task.sleep(for: .milliseconds(400))
        let create = try viewForItem("NewTask")
        let otherPanel = try viewForItem("RightPanelSwitch")
        let close = try viewForItem("RightPanelToggle")
        let createOrigin = frame(create).minX
        let closeOrigin = frame(close).midX
        let windowWidth = window.frame.width
        #expect(create.alphaValue == 1 && otherPanel.alphaValue == 1)

        let width: CGFloat = 550
        apply(width)
        try await Task.sleep(for: .milliseconds(450))
        #expect(workspace.splitViewItems.count == 3)
        #expect(window.frame.width == windowWidth)
        #expect(create.alphaValue == 0 && otherPanel.alphaValue == 0 && close.alphaValue == 1)
        for view in [create, otherPanel] {
            #expect(view.hitTest(NSPoint(x: view.frame.midX, y: view.frame.midY)) == nil)
        }
        #expect(abs(frame(create).minX - createOrigin) <= 1)

        var canvas = close.superview
        while let candidate = canvas, !otherPanel.isDescendant(of: candidate) { canvas = candidate.superview }
        let heading = try #require(canvas?.subviews.compactMap { $0 as? WorkspaceCalendarHeadingView }.first)
        let label = try #require(heading.subviews.first as? NSTextField)
        #expect(!heading.isHidden && label.stringValue == (panel == .assistant ? "Помощник" : "Календарь"))
        let panelView = try #require(container.children.first { $0 is CalendarSidebarController }?.view as? CalendarSidebarSurface)
        #expect(panelView.overlayHeaderElements == [label])
        #expect(abs(frame(label).minX - (frame(panelView).minX + CalendarPanelLayout.outerInset + 16)) <= 2)
        #expect(abs(frame(label).midY - frame(close).midY) <= 1)
        #expect(abs(frame(close).midX - closeOrigin) <= 1)

        apply(width, visible: false)
        try await Task.sleep(for: .milliseconds(450))
        #expect(create.alphaValue == 1 && otherPanel.alphaValue == 1 && close.alphaValue == 1)
        #expect(abs(frame(create).minX - createOrigin) <= 1)
        #expect(heading.superview == nil)

        window.setContentSize(NSSize(width: 1130, height: size.height))
        apply(360)
        try await Task.sleep(for: .milliseconds(450))
        #expect(workspace.splitViewItems.count == 3)
        let adjacent = try #require(canvas?.subviews.compactMap { $0 as? WorkspaceToolbarButtonSurface }.first)
        let switchButton = try #require(adjacent.contentView as? NSButton)
        #expect(!adjacent.isHidden && otherPanel.alphaValue == 0)
        #expect(abs(frame(adjacent).maxX - (frame(panelView).minX - 8)) <= 2)
        #expect(panelView.overlayHeaderElements == [label, switchButton])
        let toolbar = try #require(canvas)
        let hitPoint = toolbar.convert(NSPoint(x: adjacent.frame.midX, y: adjacent.frame.midY), to: toolbar.superview)
        #expect(toolbar.hitTest(hitPoint) === switchButton)
        switchButton.performClick(nil)
        #expect(calendarClicks == (panel == .assistant ? 1 : 0))
        #expect(assistantClicks == (panel == .calendar ? 1 : 0))
    }

    @Test(arguments: [1100.0, 1400.0], [RightPanel.calendar, .assistant])
    func panelsOpenedAfterLaunchKeepTheSameCornerRadius(width: Double, first: RightPanel) async throws {
        let size = NSSize(width: width, height: 640)
        let container = WorkspaceContainerController()
        container.view.frame.size = size
        let workspace = container.workspace
        workspace.update(sidebar: AnyView(EmptyView()), tasks: AnyView(EmptyView()), detail: AnyView(EmptyView()),
            taskActions: AnyView(EmptyView()), isSidebarVisible: true, newFolderTitle: "Папка", toggleSidebarTitle: "Папки",
            folderTitle: "Входящие", taskCountTitle: "Задач: 1", newTaskTitle: "Создать", newChecklistItemTitle: "Подзадача",
            taskActionsTitle: "Действия с задачей", hasSelectedTask: false, newFolder: {}, newTask: {}, newChecklistItem: {},
            sidebarVisibilityChanged: { _ in })
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = container
        window.orderFront(nil)
        defer { window.orderOut(nil); container.detachWindow(); window.close() }

        func show(_ panel: RightPanel) {
            container.update(calendar: AnyView(EmptyView()), visible: true, width: panel == .assistant ? 420 : 340,
                sidebarVisible: true, panel: panel,
                minimumWidth: panel == .assistant ? CalendarPanelLayout.assistantMinimumWidth : CalendarPanelLayout.minimumWidth,
                maximumWidth: panel == .assistant ? CalendarPanelLayout.assistantMaximumWidth : CalendarPanelLayout.maximumWidth,
                widthChanged: { _ in }, visibilityChanged: { _ in }, updateToolbar: { active in
                    workspace.updateRightPanelToolbar(active: active, calendarTitle: "Календарь", assistantTitle: "ИИ-чат",
                        headingTitle: panel == .assistant ? "Помощник" : "Календарь", toggleCalendar: {}, toggleAssistant: {})
                })
            container.view.layoutSubtreeIfNeeded()
        }

        try await Task.sleep(for: .milliseconds(400))
        let isOverlay = width == 1100
        for panel in [first, first == .calendar ? .assistant : .calendar, first] {
            show(panel)
            try await Task.sleep(for: .milliseconds(700))
            let host = try #require((container.children + workspace.children)
                .compactMap { $0 as? CalendarSidebarController }.first)
            #expect(host.usesOverlayChrome == isOverlay)
            let glass: NSGlassEffectView
            if isOverlay {
                glass = try #require(host.view.subviews.compactMap { $0 as? NSGlassEffectView }.first)
            } else {
                let parent = try #require(host.view.superview)
                glass = try #require(sequence(first: parent, next: { $0.superview }).first { $0 is NSGlassEffectView }
                    as? NSGlassEffectView)
            }
            #expect(glass.cornerRadius == 18)
        }
    }

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
