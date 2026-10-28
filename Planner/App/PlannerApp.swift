import SwiftUI
import SwiftData
import Observation

/// Инициализация хранилища. При ошибке не подменяем данные пустой временной библиотекой.
@MainActor @Observable
final class AppRuntime {
    var container: ModelContainer?
    var service: TaskService?
    var startupError: String?

    init() { load() }

    func load() {
        do {
            #if SHOWCASE
            // Демонстрационная сборка не открывает и не изменяет библиотеку пользователя.
            let container = try PlannerPersistence.makeContainer(inMemory: true)
            try ShowcaseData.populate(container.mainContext)
            #else
            let container = try PlannerPersistence.makeContainer(at: PlannerPersistence.liveStoreURL())
            try PlannerPersistence.bootstrap(container.mainContext)
            #endif
            self.container = container
            service = TaskService(context: container.mainContext)
            startupError = nil
        } catch {
            startupError = error.localizedDescription
        }
    }
}

@main
struct PlannerApp: App {
    @State private var runtime = AppRuntime()
    @State private var preferences = AppPreferences()
    @State private var calendar = CalendarService()
    @State private var notifications = PlannerNotifications()
    @State private var assistant = AssistantService()
    @State private var taskDrag = TaskDragState()

    var body: some Scene {
        WindowGroup(preferences.translations["Задачи"], id: "workspace") {
            workspace
                .environment(\.translations, preferences.translations)
                .environment(\.locale, preferences.language.locale)
                .tint(PlannerStyle.accent)
        }
        // SwiftUI тоже скрывает заголовок: смена фона шапки не должна возвращать название окна и сдвигать кнопки.
        .windowToolbarStyle(.unified(showsTitle: false))
        #if SHOWCASE
        .defaultSize(width: 1440, height: 840)
        #else
        .defaultSize(width: 1100, height: 700)
        #endif
        .windowResizability(.contentMinSize)
        .commands { PlannerCommands(strings: preferences.translations) }

        Settings {
            if let container = runtime.container {
            SettingsView(preferences: preferences, calendar: calendar, notifications: notifications, assistant: assistant)
                .modelContainer(container)
                .modifier(NotificationLifecycle(service: runtime.service, preferences: preferences, notifications: notifications))
                .environment(\.translations, preferences.translations)
                .environment(\.locale, preferences.language.locale)
                .tint(PlannerStyle.accent)
            } else { Text(runtime.startupError ?? "") }
        }
    }

    @ViewBuilder private var workspace: some View {
            if let container = runtime.container, let service = runtime.service {
                WorkspaceView(service: service, calendar: calendar, preferences: preferences, notifications: notifications, taskDrag: taskDrag, assistant: assistant)
                    .modifier(NotificationLifecycle(service: service, preferences: preferences, notifications: notifications))
                    .modelContainer(container)
            } else {
                ContentUnavailableView {
                    Label(preferences.translations["Не удалось открыть библиотеку"], systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(runtime.startupError ?? preferences.translations["Попробуйте открыть библиотеку ещё раз."])
                        .textSelection(.enabled)
                } actions: {
                    Button(preferences.translations["Повторить"]) { runtime.load() }
                }
                .padding(36)
                .frame(minWidth: 600, minHeight: 400)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
    }
}
