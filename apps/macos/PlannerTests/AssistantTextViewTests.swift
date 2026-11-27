import AppKit
import SwiftUI
import PlannerLocalization
import Testing
@testable import Planner

/// Снимки создаются нативным рендером вымышленной карточки; окна и данные пользователя не захватываются.
@MainActor struct AssistantTextViewTests {
    @Test func messageSelectionSurvivesChangingThePanelWidth() async throws {
        let message = "Meeting notes and a longer sentence that wraps over several lines.\nAnother paragraph."
        let host = NSHostingView(rootView: AssistantSelectableText(text: message).frame(width: 130))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let native = try #require(textView(in: host))
        #expect(native.string == message)
        #expect(native.isSelectable)
        #expect(!native.isEditable)
        let narrowHeight = host.fittingSize.height
        let selection = NSRange(location: 0, length: 7)
        native.setSelectedRange(selection)

        host.rootView = AssistantSelectableText(text: message).frame(width: 320)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(textView(in: host) === native)
        #expect(native.selectedRange() == selection)
        #expect(host.fittingSize.height < narrowHeight)
    }

    @Test func clickingChatBackgroundClearsTheMessageSelection() throws {
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 200)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: bounds)
        window.contentView = content
        let host = NSHostingView(rootView: AssistantSelectableText(text: "First chat message").frame(width: 200))
        host.frame = NSRect(x: 0, y: 150, width: 200, height: 40)
        content.addSubview(host)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()

        let native = try #require(textView(in: host))
        #expect(window.makeFirstResponder(native))
        let selection = NSRange(location: 0, length: 5)
        native.setSelectedRange(selection)
        #expect(native.selectedRange() == selection)

        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 260, y: 80),
                                                  modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        NSApplication.shared.sendEvent(click)

        #expect(native.selectedRange().length == 0)
    }

    @Test func changingMessageTextInvalidatesTheMeasuredHeight() async throws {
        let short = "Short"
        let long = String(repeating: "Длинное сообщение 👩🏽‍💻 e\u{301} ", count: 180) + "\n"
        let host = NSHostingView(rootView: AssistantSelectableText(text: short).frame(width: 180))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        let shortHeight = host.fittingSize.height

        host.rootView = AssistantSelectableText(text: long).frame(width: 180)
        host.layoutSubtreeIfNeeded()
        let native = try #require(textView(in: host))
        #expect(native.string == long)
        #expect(host.fittingSize.height > shortHeight * 10)

        host.rootView = AssistantSelectableText(text: short).frame(width: 180)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height == shortHeight)
    }

    @Test func appendingStreamedTextPreservesSelectionAndWrapsTheNewTail() throws {
        let beginning = "Résumé 👨🏽‍💻\nPlan"
        let host = NSHostingView(rootView: AssistantSelectableText(text: beginning).frame(width: 150))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 150, height: 250),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        let initialHeight = host.fittingSize.height
        let native = try #require(textView(in: host))
        let selected = (beginning as NSString).range(of: "👨🏽‍💻")
        native.setSelectedRange(selected)
        let streamed = beginning + String(repeating: " — следующий пункт", count: 80)
        host.rootView = AssistantSelectableText(text: streamed).frame(width: 150)
        host.layoutSubtreeIfNeeded()
        #expect(native.string == streamed)
        #expect(native.selectedRange() == selected)
        #expect(host.fittingSize.height > initialHeight)
    }

    @Test func streamingPreviewBatchesDeltasAndCancelsPendingUpdatesOnReset() async throws {
        let preview = AssistantReplyPreview()
        preview.append("First")
        #expect(preview.text == "First")
        preview.append(" 👨🏽‍💻")
        preview.append("\nSecond")
        #expect(preview.text == "First")
        try await Task.sleep(for: .milliseconds(160))
        #expect(preview.text == "First 👨🏽‍💻\nSecond")

        preview.reset()
        preview.append("Old")
        preview.append(" pending")
        preview.reset()
        preview.append("New")
        try await Task.sleep(for: .milliseconds(160))
        #expect(preview.text == "New")
    }

    private func textView(in view: NSView) -> NSTextView? {
        (view as? NSTextView) ?? view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    @Test(arguments: [false, true])
    func reviewFitsNarrowPanelInBothThemes(dark: Bool) async throws {
        let before = AssistantTextSnapshot(id: UUID(), title: "Подготовить презентацию", description: "Рассказать о проекте.",
            checklist: [.init(id: UUID(), title: "Собрать материалы", isCompleted: true)])
        var edit = AssistantTextEdit(target: .savedTask, before: before)
        try edit.propose(.init(title: "Подготовить презентацию проекта", description: "Цель: понятно представить проект.\n\nПлан: выстроить структуру, подготовить слайды и проверить формулировки.\n\nРезультат: готовая презентация.", checklist: ["Составить структуру", "Проверить слайды"]))
        let root = AssistantTextEditCard(edit: edit, busy: false, apply: {}, refresh: {})
            .environment(\.translations, Translations(language: dark ? .english : .russian))
            .tint(PlannerStyle.accent).padding(16).frame(width: 360).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 1100)
        defer { window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 361)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appending(path: dark ? "planner-text-review-dark.png" : "planner-text-review-light.png")
        try png.write(to: url)
        print("TEXT VIEW " + url.path)
    }
}
