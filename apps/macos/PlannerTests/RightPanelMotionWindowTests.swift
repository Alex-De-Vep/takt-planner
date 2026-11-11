import AppKit
import SwiftUI
import Testing
@testable import Planner

/// Интеграция с настоящей NSWindow и её toolbar. Пустые представления не открывают SwiftData или EventKit.
@MainActor
struct RightPanelMotionWindowTests {
    @Test(arguments: [1400.0, 1050.0])
    func realToolbarMovesSemanticButtonsThroughIntermediateFramesAndParksThem(width: Double) async throws {
        let container = WorkspaceContainerController()
        container.view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        let workspace = container.workspace
        workspace.update(sidebar: AnyView(EmptyView()), tasks: AnyView(EmptyView()), detail: AnyView(EmptyView()),
            taskActions: AnyView(EmptyView()), isSidebarVisible: true, newFolderTitle: "Папка", toggleSidebarTitle: "Папки",
            folderTitle: "Проверка", taskCountTitle: "Задач: 0", newTaskTitle: "Создать", newChecklistItemTitle: "Подзадача",
            taskActionsTitle: "Действия", hasSelectedTask: false, newFolder: {}, newTask: {}, newChecklistItem: {}, sidebarVisibilityChanged: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: width, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = container
        window.orderFront(nil)
        defer { window.orderOut(nil); container.detachWindow(); window.close() }
        func apply(_ panel: RightPanel?) {
            workspace.updateRightPanelToolbar(active: panel, calendarTitle: "Календарь", assistantTitle: "ИИ-чат",
                headingTitle: panel == .assistant ? "Помощник" : "Календарь", toggleCalendar: {}, toggleAssistant: {})
            container.update(calendar: AnyView(EmptyView()), visible: panel != nil, width: panel == .assistant ? 420 : 340,
                sidebarVisible: true, panel: panel, minimumWidth: panel == .assistant ? 360 : 320,
                maximumWidth: panel == .assistant ? 520 : 1200, widthChanged: { _ in }, visibilityChanged: { _ in })
            container.view.layoutSubtreeIfNeeded()
        }
        func slot(_ name: String) throws -> WorkspaceRightPanelSlot {
            let item = try #require(workspace.toolbar(NSToolbar(), itemForItemIdentifier: .init("Planner.\(name)"), willBeInsertedIntoToolbar: true))
            return try #require(item.view as? WorkspaceRightPanelSlot)
        }
        func screenX(_ button: NSButton) throws -> CGFloat {
            let owner = try #require(button.window)
            return owner.convertToScreen(button.convert(button.bounds, to: nil)).midX
        }
        apply(nil)
        try await Task.sleep(for: .milliseconds(100))
        let outer = try slot("RightPanelSwitch"), trailing = try slot("RightPanelToggle")
        let chat = try #require(outer.surface?.contentView as? NSButton)
        let calendar = try #require(trailing.surface?.contentView as? NSButton)
        let chatImage = chat.image, calendarImage = calendar.image
        for panel in ([.assistant, .calendar, nil, .calendar, .assistant, nil] as [RightPanel?]) {
            let chatStart = try screenX(chat), calendarStart = try screenX(calendar)
            apply(panel)
            var chatSamples: [CGFloat] = [], calendarSamples: [CGFloat] = []
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(20))
                chatSamples.append(try screenX(chat)); calendarSamples.append(try screenX(calendar))
                #expect(chat.image === chatImage && calendar.image === calendarImage)
                #expect(chat.accessibilityIdentifier() == "toggle-assistant-button")
                #expect(calendar.accessibilityIdentifier() == "toggle-calendar-button")
            }
            try await Task.sleep(for: .milliseconds(150))
            let chatEnd = try screenX(chat), calendarEnd = try screenX(calendar)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                for (start, end, samples) in [(chatStart, chatEnd, chatSamples), (calendarStart, calendarEnd, calendarSamples)] where abs(end - start) > 10 {
                    let middle = samples.filter { $0 > min(start, end) + 1 && $0 < max(start, end) - 1 }
                    #expect(middle.count >= 2, "Перемещение должно проходить через промежуточные кадры")
                    #expect(samples.allSatisfy { $0 >= min(start, end) - 1 && $0 <= max(start, end) + 1 },
                            "Кнопка не должна сначала уезжать за конечное место и возвращаться скачком")
                    var previous = start
                    for x in samples {
                        #expect(end > start ? x >= previous - 1 : x <= previous + 1,
                                "Промежуточный layout не должен менять направление движения")
                        previous = x
                    }
                }
            }
            let desiredChatSlot = panel == .assistant ? trailing : outer
            let desiredCalendarSlot = panel == .assistant ? outer : trailing
            #expect(desiredChatSlot.surface?.contentView === chat)
            #expect(desiredCalendarSlot.surface?.contentView === calendar)
            #expect(desiredChatSlot.carrier?.superview === desiredChatSlot)
            #expect(desiredCalendarSlot.carrier?.superview === desiredCalendarSlot)
            print("PANEL_MOTION width=\(width) \(String(describing: panel)) chat=\(chatStart)->\(chatEnd) samples=\(chatSamples) calendar=\(calendarStart)->\(calendarEnd) samples=\(calendarSamples)")
        }
        // Разворот во время движения сохраняет текущие экранные координаты.
        apply(.assistant)
        try await Task.sleep(for: .milliseconds(60))
        let beforeChat = try screenX(chat), beforeCalendar = try screenX(calendar)
        apply(.calendar)
        #expect(abs((try screenX(chat)) - beforeChat) <= 1)
        #expect(abs((try screenX(calendar)) - beforeCalendar) <= 1)
        try await Task.sleep(for: .milliseconds(50))
        apply(nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(outer.surface?.contentView === chat && trailing.surface?.contentView === calendar)
        #expect(outer.carrier?.superview === outer && trailing.carrier?.superview === trailing)
    }
}
