import AppKit
import SwiftUI
import PlannerLocalization
import Testing
@testable import Planner

/// Снимки создаются нативным рендером вымышленной карточки; окна и данные пользователя не захватываются.
@MainActor struct AssistantTextViewTests {
    @Test(arguments: [false, true])
    func reviewFitsNarrowPanelInBothThemes(dark: Bool) async throws {
        let before = AssistantTextSnapshot(id: UUID(), title: "Подготовить презентацию", description: "Рассказать о проекте.",
            checklist: [.init(id: UUID(), title: "Собрать материалы", isCompleted: true)])
        var edit = AssistantTextEdit(target: .savedTask, before: before)
        try edit.propose(.init(title: "Подготовить презентацию проекта", description: "Цель: понятно представить проект.\n\nПлан: выстроить структуру, подготовить слайды и проверить формулировки.\n\nРезультат: готовая презентация.", checklist: ["Составить структуру", "Проверить слайды"]))
        let root = VStack(alignment: .leading, spacing: 12) {
            AssistantTextToolsButton(title: "Доработать текст", commands: ["Расписать задачу"], enabled: true, perform: { _ in })
                .fixedSize()
            AssistantTextEditCard(edit: edit, busy: false, active: true, update: { _ in }, refine: {}, apply: {}, cancel: {}, refresh: {}, open: {})
        }
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
