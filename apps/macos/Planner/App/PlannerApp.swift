import SwiftUI
import SwiftData
import Observation
import AppKit

/// Инициализация хранилища. При ошибке не подменяем данные пустой временной библиотекой.
@MainActor @Observable
final class AppRuntime {
    var container: ModelContainer?
    var service: TaskService?
    var startupError: String?

    private(set) var assistant: AssistantService?
    private let defaults: UserDefaults

    let cloud: CloudWorkspace

    init(defaults: UserDefaults = PlannerPersistence.defaults(), loadOnInit: Bool = true) {
        self.defaults = defaults
        cloud = CloudWorkspace(defaults: defaults)
        cloud.willOpen = { [weak self] in
            guard let self else { return }
            guard self.flushEditors() else { throw AssistantFailure(message: self.editorSaveError) }
            if self.defaults.string(forKey: PlannerPersistence.restoredLibraryKey) != nil,
               let assistant = self.assistant, assistant.generating || assistant.applying || assistant.storageFailed {
                throw BackupError.busy
            }
        }
        cloud.didOpen = { [weak self] library in
            guard let self else { return }
            self.defaults.removeObject(forKey: PlannerPersistence.restoredLibraryKey)
            self.open(library)
        }
        if loadOnInit { load() }
    }

    func load() {
        guard flushEditors() else { return }
        do {
            #if SHOWCASE
            // Демонстрационная сборка не открывает и не изменяет библиотеку пользователя.
            let container = try PlannerPersistence.makeContainer(inMemory: true)
            try ShowcaseData.populate(container.mainContext)
            #else
            if let restored = defaults.string(forKey: PlannerPersistence.restoredLibraryKey) {
                guard let id = UUID(uuidString: restored) else { throw BackupError.invalid }
                let directory = try PlannerPersistence.restoredLibraryDirectory(id)
                let database = directory.appending(path: "Planner.store")
                guard FileManager.default.fileExists(atPath: database.path) else { throw BackupError.invalid }
                let container = try PlannerPersistence.makeContainer(at: database)
                if cloud.profile != nil { cloud.useRestoredLocalLibrary() }
                open(CloudLibrary(container: container, service: TaskService(context: container.mainContext)),
                     assistantStore: restoredAssistantStore(in: directory))
                return
            }
            if let library = try cloud.resume() {
                open(library)
                return
            }
            let container = try PlannerPersistence.makeContainer(at: PlannerPersistence.liveStoreURL())
            try PlannerPersistence.bootstrap(container.mainContext)
            #endif
            open(CloudLibrary(container: container, service: TaskService(context: container.mainContext)))
        } catch {
            startupError = error.localizedDescription
        }
    }

    private func open(_ library: CloudLibrary, assistantStore: AssistantStore? = nil) {
        let store: AssistantStore
        if let assistantStore {
            store = assistantStore
        } else if library.service.syncRepository != nil || PlannerPersistence.testID != nil,
           let database = library.container.configurations.first?.url {
            let path = database.deletingLastPathComponent().appending(path: "Assistant/conversations.json")
            store = AssistantStore(url: path)
        } else {
            store = AssistantStore()
        }
        if library.service.syncRepository == nil,
           library.container.configurations.first?.isStoredInMemoryOnly == false,
           let database = library.container.configurations.first?.url {
            library.service.notes = NoteStore(url: database.deletingLastPathComponent().appending(path: "Notes.json"))
        }
        assistant?.stop()
        assistant = AssistantService(store: store)
        container = library.container
        service = library.service
        startupError = nil
    }

    private func restoredAssistantStore(in directory: URL) -> AssistantStore {
        AssistantStore(url: directory.appending(path: "Assistant/conversations.json"))
    }

    func restore(_ backup: PlannerBackup, preferences: AppPreferences) throws {
        guard !cloud.busy, assistant?.generating != true, assistant?.applying != true else { throw BackupError.busy }
        guard flushEditors() else { throw BackupError.unsavedChanges }
        let id = UUID()
        let directory = try PlannerPersistence.restoredLibraryDirectory(id)
        let assistantStore = restoredAssistantStore(in: directory)
        let container: ModelContainer
        do {
            container = try PlannerPersistence.makeContainer(at: directory.appending(path: "Planner.store"))
            try backup.restore(in: container.mainContext)
            if let history = try backup.assistantArchive() { try assistantStore.save(history) }
            try NoteStore(url: directory.appending(path: "Notes.json")).restore(backup.notes ?? [])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        #if SHOWCASE
        open(CloudLibrary(container: container, service: TaskService(context: container.mainContext)),
             assistantStore: assistantStore)
        #else
        // Commit the local selection before detaching sync so a restart opens the completed copy.
        defaults.set(id.uuidString, forKey: PlannerPersistence.restoredLibraryKey)
        cloud.useRestoredLocalLibrary()
        open(CloudLibrary(container: container, service: TaskService(context: container.mainContext)),
             assistantStore: assistantStore)
        #endif
        backup.preferences?.apply(to: preferences)
    }

    func flushEditors() -> Bool {
        let tasksSaved = service?.flushEditorText() ?? true
        let chatSaved = assistant?.flushDrafts() ?? true
        let notesSaved = service?.notes.flush() ?? true
        return tasksSaved && chatSaved && notesSaved
    }

    var editorSaveError: String {
        service?.error?.message ?? service?.notes.error ?? assistant?.error ?? "Не удалось сохранить текст."
    }
}

@MainActor
final class PlannerTerminationDelegate: NSObject, NSApplicationDelegate {
    weak var runtime: AppRuntime?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        if runtime.flushEditors() {
            runtime.service?.notes.voice.finishForTermination()
            return .terminateNow
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = runtime.editorSaveError
        alert.runModal()
        return .terminateCancel
    }
}

@main
struct PlannerApp: App {
    @NSApplicationDelegateAdaptor(PlannerTerminationDelegate.self) private var terminationDelegate
    @State private var runtime = AppRuntime()
    @State private var preferences = AppPreferences()
    @State private var calendar = CalendarService()
    @State private var notifications = PlannerNotifications()
    @State private var taskDrag = TaskDragState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("Takt", id: "workspace") {
            launchContent
                .onAppear { terminationDelegate.runtime = runtime }
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
        Window(preferences.translations["Добро пожаловать в Takt"], id: "welcome") {
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
            if let container = runtime.container, let assistant = runtime.assistant {
                SettingsView(preferences: preferences, calendar: calendar, notifications: notifications,
                             cloud: runtime.cloud, service: runtime.service, assistant: assistant,
                             restoreBackup: { try runtime.restore($0, preferences: preferences) })
                .modelContainer(container)
                .modifier(NotificationLifecycle(service: runtime.service, preferences: preferences, notifications: notifications))
                .environment(\.translations, preferences.translations)
                .environment(\.locale, preferences.language.locale)
                .tint(PlannerStyle.accent)
            } else {
                Form {
                    Text(runtime.startupError ?? "")
                    BackupSettingsSection(preferences: preferences, service: nil, assistant: nil,
                        restore: { try runtime.restore($0, preferences: preferences) })
                }
                .formStyle(.grouped)
                .frame(width: 560, height: 320)
                .environment(\.translations, preferences.translations)
            }
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
            if let container = runtime.container, let service = runtime.service, let assistant = runtime.assistant {
                WorkspaceView(service: service, calendar: calendar, preferences: preferences, notifications: notifications, taskDrag: taskDrag, assistant: assistant)
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
