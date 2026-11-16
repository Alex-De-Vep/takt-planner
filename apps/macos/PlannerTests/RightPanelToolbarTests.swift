import AppKit
import SwiftUI
import Testing
@testable import Planner

/// Шапку проверяем без запуска приложения, открытия окон или доступа к библиотеке пользователя.
@MainActor
struct RightPanelToolbarTests {
    private func item(_ controller: WorkspaceSplitController, _ suffix: String) throws -> NSToolbarItem {
        try #require(controller.toolbar(NSToolbar(), itemForItemIdentifier: .init("Planner.\(suffix)"), willBeInsertedIntoToolbar: true))
    }
    private func surface(_ item: NSToolbarItem) throws -> WorkspaceToolbarButtonSurface {
        try #require(item.view as? WorkspaceToolbarButtonSurface)
    }
    private func button(_ item: NSToolbarItem) throws -> NSButton {
        try #require(surface(item).contentView as? NSButton)
    }
    private func update(_ controller: WorkspaceSplitController, active: RightPanel?, english: Bool = false,
                        calendar: @escaping () -> Void = {}, assistant: @escaping () -> Void = {}) {
        controller.updateRightPanelToolbar(active: active,
            calendarTitle: english ? (active == .calendar ? "Close calendar" : "Open calendar")
                : (active == .calendar ? "Закрыть календарь" : "Открыть календарь"),
            assistantTitle: english ? (active == .assistant ? "Close AI chat" : "Open AI chat")
                : (active == .assistant ? "Закрыть ИИ-чат" : "Открыть ИИ-чат"),
            headingTitle: english ? (active == .assistant ? "Assistant" : "Calendar")
                : (active == .assistant ? "Помощник" : "Календарь"),
            toggleCalendar: calendar, toggleAssistant: assistant)
    }

    @Test func rolesFollowActivePanelWithoutTwoIndependentOpenFlags() {
        #expect(RightPanelToolbarRoles(active: nil) == RightPanelToolbarRoles(active: .calendar))
        #expect(RightPanelToolbarRoles(active: nil).outer == .assistant)
        #expect(RightPanelToolbarRoles(active: nil).trailing == .calendar)
        #expect(RightPanelToolbarRoles(active: .assistant).outer == .calendar)
        #expect(RightPanelToolbarRoles(active: .assistant).trailing == .assistant)
    }

    @Test func controlsAndSurfacesStayIdenticalWhileRolesAndLanguagesChange() throws {
        let controller = WorkspaceSplitController()
        let outer = try item(controller, "RightPanelSwitch"), trailing = try item(controller, "RightPanelToggle")
        let outerSlot = outer.view, trailingSlot = trailing.view
        let fixedOuter = try button(outer), fixedTrailing = try button(trailing)
        let assistantImage = try #require(fixedOuter.image), calendarImage = try #require(fixedTrailing.image)
        update(controller, active: .calendar)
        let closeImage = try #require(fixedTrailing.image)
        #expect(closeImage !== calendarImage && closeImage !== assistantImage)
        let outerAction = fixedOuter.action, trailingAction = fixedTrailing.action
        let search = try item(controller, "Search").view
        let controllers = controller.splitViewItems.map { ObjectIdentifier($0.viewController) }
        for english in [false, true] {
            for active in ([nil, .calendar, .assistant, .calendar, nil] as [RightPanel?]) {
                update(controller, active: active, english: english)
                controller.setCalendarToolbar(column: true, visible: active != nil)
                #expect(try item(controller, "RightPanelSwitch") === outer)
                #expect(try item(controller, "RightPanelToggle") === trailing)
                #expect(outer.view === outerSlot && trailing.view === trailingSlot)
                let outerSurface = try surface(outer), trailingSurface = try surface(trailing)
                let outerButton = try button(outer), trailingButton = try button(trailing)
                #expect(outerButton === fixedOuter && trailingButton === fixedTrailing)
                #expect(outerButton.image === (active == .assistant ? calendarImage : assistantImage))
                #expect(trailingButton.image === (active == nil ? calendarImage : closeImage))
                #expect(outerButton.action == outerAction && trailingButton.action == trailingAction)
                #expect(outerSurface.presentation == .circle)
                #expect(trailingSurface.presentation == (active == nil ? .circle : .sidebar))
                #expect(outerButton.borderShape == .circle)
                #expect(trailingButton.borderShape == (active == nil ? .circle : .capsule))
                #expect(outerButton.contentTintColor == .labelColor && trailingButton.contentTintColor == .labelColor)
                #expect(outerButton.accessibilityIdentifier() == (active == .assistant ? "toggle-calendar-button" : "toggle-assistant-button"))
                #expect(trailingButton.accessibilityIdentifier() == (active == .assistant ? "toggle-assistant-button" : "toggle-calendar-button"))
                let expectedOuter = english ? (active == .assistant ? "Open calendar" : "Open AI chat")
                    : (active == .assistant ? "Открыть календарь" : "Открыть ИИ-чат")
                let expectedTrailing = english ? (active == nil ? "Open calendar" : active == .assistant ? "Close AI chat" : "Close calendar")
                    : (active == nil ? "Открыть календарь" : active == .assistant ? "Закрыть ИИ-чат" : "Закрыть календарь")
                #expect(outerButton.toolTip == expectedOuter && outerButton.accessibilityLabel() == expectedOuter)
                #expect(trailingButton.toolTip == expectedTrailing && trailingButton.accessibilityLabel() == expectedTrailing)
                #expect(try item(controller, "Search").view === search)
                #expect(controller.splitViewItems.map { ObjectIdentifier($0.viewController) } == controllers)
            }
        }
    }

    @Test func rightSectionContainsEachSlotOnceAndHeadingInsidePanel() throws {
        let controller = WorkspaceSplitController()
        let outerID = NSToolbarItem.Identifier("Planner.RightPanelSwitch")
        let trailingID = NSToolbarItem.Identifier("Planner.RightPanelToggle")
        let headingID = NSToolbarItem.Identifier("Planner.CalendarHeading")
        let boundaryID = NSToolbarItem.Identifier("Planner.CalendarBoundary")
        for active in ([nil, .calendar, .assistant] as [RightPanel?]) {
            for column in [false, true] {
                update(controller, active: active)
                controller.setCalendarToolbar(column: column, visible: active != nil)
                let ids = controller.toolbarDefaultItemIdentifiers(NSToolbar())
                #expect(ids.filter { $0 == outerID }.count == 1 && ids.filter { $0 == trailingID }.count == 1)
                let outerIndex = try #require(ids.firstIndex(of: outerID)), trailingIndex = try #require(ids.firstIndex(of: trailingID))
                #expect(outerIndex < trailingIndex)
                if active != nil {
                    let headingIndex = try #require(ids.firstIndex(of: headingID))
                    #expect(outerIndex < headingIndex && headingIndex < trailingIndex)
                    if column {
                        let boundaryIndex = try #require(ids.firstIndex(of: boundaryID))
                        #expect(outerIndex < boundaryIndex && boundaryIndex < headingIndex)
                    } else { #expect(!ids.contains(boundaryID)) }
                } else { #expect(!ids.contains(headingID) && !ids.contains(boundaryID)) }
            }
        }
    }

    @Test func clickAndOverflowActionsFollowRolesAfterSwitching() throws {
        let controller = WorkspaceSplitController()
        let outer = try item(controller, "RightPanelSwitch"), trailing = try item(controller, "RightPanelToggle")
        var calendarClicks = 0, assistantClicks = 0
        for active in ([nil, .calendar, .assistant, .calendar, .assistant, nil] as [RightPanel?]) {
            update(controller, active: active, calendar: { calendarClicks += 1 }, assistant: { assistantClicks += 1 })
            controller.setCalendarToolbar(column: true, visible: active != nil)
            let beforeCalendar = calendarClicks, beforeAssistant = assistantClicks
            try button(outer).performClick(nil)
            #expect(calendarClicks == beforeCalendar + (active == .assistant ? 1 : 0))
            #expect(assistantClicks == beforeAssistant + (active == .assistant ? 0 : 1))
            try button(trailing).performClick(nil)
            #expect(calendarClicks == beforeCalendar + 1 && assistantClicks == beforeAssistant + 1)
            #expect(outer.menuFormRepresentation?.action == (try button(outer)).action)
            #expect(trailing.menuFormRepresentation?.action == (try button(trailing)).action)
            #expect(outer.menuFormRepresentation?.title == outer.label && trailing.menuFormRepresentation?.title == trailing.label)
        }
    }

    @Test func transitionsDoNotRevealHeadingBeforeLayoutOrRenameClosingChat() throws {
        let controller = WorkspaceSplitController()
        let heading = try #require(item(controller, "CalendarHeading").view)
        for active in [RightPanel.calendar, .assistant, .calendar, .assistant] {
            controller.beginCalendarHeaderTransition()
            update(controller, active: active)
            controller.setCalendarToolbar(column: false, visible: true)
            #expect(heading.alphaValue == 0)
            controller.finishCalendarHeaderTransition(afterLayout: false)
            #expect(heading.alphaValue == 1)
            let label = try #require(heading.subviews.first as? NSTextField)
            #expect(label.stringValue == (active == .assistant ? "Помощник" : "Календарь"))
            #expect(label.accessibilityIdentifier() == (active == .assistant ? "assistant-panel-heading" : "calendar-panel-heading"))
            update(controller, active: nil)
            #expect(label.stringValue == (active == .assistant ? "Помощник" : "Календарь"))
            controller.setCalendarToolbar(column: false, visible: false)
        }
    }

    @Test func aiChatSymbolIsTemplateAtOriginalToolbarScale() {
        let image = WorkspaceAIChatSymbol.image()
        #expect(image.isTemplate && image.size == NSSize(width: 20, height: 20))
        #expect(NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil) != nil)
        #expect(NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil) != nil)
        #expect(WorkspaceToolbarButtonSurface.diameter == 36)
    }
}
