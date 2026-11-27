import SwiftUI
import Testing
@testable import Planner

@MainActor struct AssistantSettingsViewTests {
    @Test func requestOpensAssistantSettings() async throws {
        let suite = "AssistantSettings-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = AppPreferences(defaults: defaults)
        let assistant = AssistantService(store: .init(url: directory.appending(path: "chat.json")))
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let settings = SettingsView(preferences: preferences, calendar: CalendarService(store: FakeCalendarStore()),
            notifications: PlannerNotifications(), assistant: assistant, restoreBackup: { _ in })
            .modelContainer(container)
        let host = NSHostingView(rootView: settings)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 830),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }

        preferences.assistantSettingsRequest = UUID()
        for _ in 0..<30 where preferences.assistantSettingsRequest != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(preferences.assistantSettingsRequest == nil)
    }
}
