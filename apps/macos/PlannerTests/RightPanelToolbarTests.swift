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
        try #require((item.view as? WorkspaceRightPanelSlot)?.surface)
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
        let assistantButton = try button(outer), calendarButton = try button(trailing)
        let assistantImage = assistantButton.image, calendarImage = calendarButton.image
        let assistantAction = assistantButton.action, calendarAction = calendarButton.action
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
                #expect(outerButton === (active == .assistant ? calendarButton : assistantButton))
                #expect(trailingButton === (active == .assistant ? assistantButton : calendarButton))
                #expect(assistantButton.image === assistantImage && calendarButton.image === calendarImage)
                #expect(assistantButton.action == assistantAction && calendarButton.action == calendarAction)
                #expect(assistantButton.accessibilityIdentifier() == "toggle-assistant-button")
                #expect(calendarButton.accessibilityIdentifier() == "toggle-calendar-button")
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

    @Test func capturedChatButtonKeepsItsActionAfterMovingToTrailingSlot() throws {
        let controller = WorkspaceSplitController()
        var chats = 0, calendars = 0
        update(controller, active: nil, calendar: { calendars += 1 }, assistant: { chats += 1 })
        let chat = try button(item(controller, "RightPanelSwitch")), originalImage = chat.image
        update(controller, active: .assistant, calendar: { calendars += 1 }, assistant: { chats += 1 })
        controller.setCalendarToolbar(column: true, visible: true)
        #expect(try button(item(controller, "RightPanelToggle")) === chat)
        chat.performClick(nil)
        #expect(chats == 1 && calendars == 0 && chat.image === originalImage)
        update(controller, active: .calendar, calendar: { calendars += 1 }, assistant: { chats += 1 })
        #expect(try button(item(controller, "RightPanelSwitch")) === chat)
        chat.performClick(nil)
        #expect(chats == 2 && calendars == 0 && chat.image === originalImage)
    }

    @Test func closingChatPreservesItsButtonAndIconInsteadOfTurningItIntoCalendar() throws {
        let controller = WorkspaceSplitController()
        let trailing = try item(controller, "RightPanelToggle"), outer = try item(controller, "RightPanelSwitch")
        update(controller, active: .assistant)
        controller.setCalendarToolbar(column: true, visible: true)
        let chatButton = try button(trailing), image = chatButton.image, action = chatButton.action
        controller.beginCalendarHeaderTransition()
        update(controller, active: nil)
        // В тесте нет окна: носитель сразу занимает конечное место, без таймера и анимации.
        #expect(try button(outer) === chatButton)
        #expect(chatButton.image === image && chatButton.action == action)
        #expect(chatButton.accessibilityIdentifier() == "toggle-assistant-button")
        let heading = try #require(item(controller, "CalendarHeading").view)
        #expect(heading.alphaValue == 0)
        controller.setCalendarToolbar(column: false, visible: false)
        controller.finishCalendarHeaderTransition(afterLayout: false)
        #expect(try surface(outer).presentation == .circle && surface(trailing).presentation == .circle)
        #expect(heading.alphaValue == 0)
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

    @Test func buttonPathKeepsEndpointsAndUsesPanelTimingWithoutOvershoot() {
        let from = CGRect(x: 950, y: 8, width: 36, height: 36)
        let to = CGRect(x: 600, y: 8, width: 36, height: 36)
        let path = RightPanelButtonPath(start: from, end: to)
        #expect(path.frame(at: -1) == from && path.frame(at: 0) == from)
        #expect(path.frame(at: 1) == to && path.frame(at: 2) == to)
        #expect(abs(path.frame(at: 0.5).minX - 775) < 0.001)
        var previous = from.minX
        for step in 0...100 {
            let frame = path.frame(at: Double(step) / 100)
            #expect(frame.minX <= previous + 0.001 && frame.minX >= to.minX)
            #expect(frame.minY == 8 && frame.size == from.size)
            previous = frame.minX
        }
        // Прерывание берёт текущую координату и сохраняет непрерывность обратного движения.
        let middle = path.frame(at: 0.4)
        let reversed = RightPanelButtonPath(start: middle, end: from)
        #expect(reversed.frame(at: 0) == middle && reversed.frame(at: 1) == from)
    }

    @Test func motionWithoutWindowParksSameSemanticControlsAndLeavesNoRunningTransition() {
        let chat = NSButton(), calendar = NSButton()
        let chatSurface = WorkspaceToolbarButtonSurface(content: chat)
        let calendarSurface = WorkspaceToolbarButtonSurface(content: calendar)
        let outer = WorkspaceRightPanelSlot(), trailing = WorkspaceRightPanelSlot()
        let motion = WorkspaceRightPanelButtonMotion(outer: outer, trailing: trailing,
            assistant: chatSurface, calendar: calendarSurface)
        for active in ([nil, .assistant, .calendar, nil, .assistant] as [RightPanel?]) {
            motion.update(active: active, animate: true)
            #expect(!motion.moving)
            #expect(outer.surface === (active == .assistant ? calendarSurface : chatSurface))
            #expect(trailing.surface === (active == .assistant ? chatSurface : calendarSurface))
            #expect(outer.carrier?.superview === outer && trailing.carrier?.superview === trailing)
            #expect(outer.surface?.presentation == .circle)
            #expect(trailing.surface?.presentation == (active == nil ? .circle : .sidebar))
            motion.cancel()
            #expect(!motion.moving && chatSurface.contentView === chat && calendarSurface.contentView === calendar)
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
