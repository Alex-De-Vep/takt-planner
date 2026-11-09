import SwiftUI
import SwiftData
import Observation

/// Инициализация хранилища. При ошибке не подменяем данные пустой временной библиотекой.
@MainActor @Observable
final class AppRuntime {
    var container: ModelContainer?
    var service: TaskService?
    var startupError: String?

    let cloud = CloudWorkspace(defaults: PlannerPersistence.defaults())

    init() {
        cloud.didOpen = { [weak self] library in
            self?.container = library.container
            self?.service = library.service
            self?.startupError = nil
        }
        load()
    }

    func load() {
        do {
            #if SHOWCASE
            // Демонстрационная сборка не открывает и не изменяет библиотеку пользователя.
            let container = try PlannerPersistence.makeContainer(inMemory: true)
            try ShowcaseData.populate(container.mainContext)
            #else
            if let library = try cloud.resume() {
                container = library.container
                service = library.service
                startupError = nil
                return
            }
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
    @State private var taskDrag = TaskDragState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup(preferences.translations["Задачи"], id: "workspace") {
            launchContent
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { runtime.cloud.engine?.wake() }
                }
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
        .commands { PlannerCommands(strings: preferences.translations, canShowWelcome: runtime.service != nil) }

        Window(preferences.translations["Справка по приложению"], id: PlannerHelpView.windowID) {
            PlannerHelpView(guide: preferences.translations.helpGuide)
                .environment(\.translations, preferences.translations)
                .tint(PlannerStyle.accent)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultSize(width: 830, height: 570)
        .windowResizability(.contentMinSize)

        #if !SHOWCASE
        Window(preferences.translations["Добро пожаловать в «Задачи»"], id: "welcome") {
            WelcomeView(cloud: runtime.cloud, service: runtime.service, openedFromHelp: true)
                .environment(\.translations, preferences.translations)
                .environment(\.locale, preferences.language.locale)
                .tint(PlannerStyle.accent)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultSize(width: 950, height: 600)
        .windowResizability(.contentMinSize)
        #endif

        Settings {
            SettingsView(preferences: preferences, calendar: calendar, notifications: notifications,
                         cloud: runtime.cloud, service: runtime.service)
                .modifier(NotificationLifecycle(service: runtime.service, preferences: preferences, notifications: notifications))
                .environment(\.translations, preferences.translations)
                .environment(\.locale, preferences.language.locale)
                .tint(PlannerStyle.accent)
        }
    }

    @ViewBuilder private var launchContent: some View {
        #if SHOWCASE
        workspace
        #else
        let forceWelcome = ProcessInfo.processInfo.environment["PLANNER_SHOW_WELCOME"] == "1"
        if runtime.service != nil && !runtime.cloud.welcomeCompleted &&
           (PlannerPersistence.testID == nil || forceWelcome) {
            WelcomeView(cloud: runtime.cloud, service: runtime.service)
        } else {
            workspace
        }
        #endif
    }

    @ViewBuilder private var workspace: some View {
            if let container = runtime.container, let service = runtime.service {
                WorkspaceView(service: service, calendar: calendar, preferences: preferences, notifications: notifications, taskDrag: taskDrag)
                    .modifier(NotificationLifecycle(service: service, preferences: preferences, notifications: notifications))
                    .modelContainer(container)
                    .id(ObjectIdentifier(container))
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
