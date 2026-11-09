import SwiftUI
import PlannerLocalization

/// Нативное окно настроек macOS, доступное через меню приложения и ⌘,.
struct SettingsView: View {
    private enum Pane: String, CaseIterable {
        case general, notifications, calendar
        #if canImport(MLXLLM)
        case assistant
        #endif

        var label: (title: String, icon: String) {
            switch self {
            #if SHOWCASE
            case .general: ("Основные", "gearshape")
            #else
            case .general: ("Аккаунт", "person.crop.circle")
            #endif
            case .notifications: ("Уведомления", "bell")
            case .calendar: ("Календарь", "calendar")
            #if canImport(MLXLLM)
            case .assistant: ("Помощник", "sparkles")
            #endif
            }
        }
    }

    @Environment(\.translations) private var strings
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Pane? = .general
    @Bindable var preferences: AppPreferences
    let calendar: CalendarService
    @Bindable var notifications: PlannerNotifications
    var cloud: CloudWorkspace? = nil
    var service: TaskService? = nil
    #if canImport(MLXLLM)
    let assistant: AssistantService
    #endif

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(Pane.allCases, id: \.self) { pane in
                        Label(strings[pane.label.title], systemImage: pane.label.icon)
                            .accessibilityIdentifier("settings-pane-\(pane.rawValue)")
                            .tag(pane)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("settings-sidebar")

                Button { openWindow(id: PlannerHelpView.windowID) } label: {
                    Label(strings["Справка"], systemImage: "questionmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityIdentifier("settings-help")
            }
            .frame(width: 188)
            Divider()
            Form { detail }
                .formStyle(.grouped)
                .id(selection ?? .general)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, idealWidth: 748, minHeight: 490, idealHeight: 590)
        .navigationTitle(strings["Настройки"])
        .onAppear { calendar.refresh() }
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .general {
        case .general: general
        case .notifications:
            NotificationSettingsSection(preferences: preferences, notifications: notifications)
        case .calendar: calendarSettings
        #if canImport(MLXLLM)
        case .assistant:
            AssistantSettingsSection(assistant: assistant, preferences: preferences)
        #endif
        }
    }

    @ViewBuilder private var general: some View {
        #if !SHOWCASE
        if let cloud { CloudSettingsSection(cloud: cloud, service: service) }
        #endif
        Section {
            Picker(strings["Язык интерфейса"], selection: $preferences.language) {
                Text(strings["Как в системе"]).tag(AppLanguage.system)
                Text("Русский").tag(AppLanguage.russian)
                Text("English").tag(AppLanguage.english)
            }
            .accessibilityIdentifier("language-picker")
        } header: {
            Label(strings["Интерфейс"], systemImage: "globe")
        } footer: {
            Text(strings["Язык меняется сразу. Названия ваших папок и задач сохраняются без изменений."])
        }
    }

    private var calendarSettings: some View {
        Section {
            if calendar.access == .full {
                Picker(strings["Создавать события в"], selection: $preferences.creationCalendarID) {
                    Text(strings["Системный календарь по умолчанию"]).tag(nil as String?)
                    ForEach(calendar.calendars.filter(\.writable)) { item in Text(item.title).tag(Optional(item.id)) }
                }
                Text(strings["Отображаемые календари"]).font(.headline)
                Toggle(strings["Все календари"], isOn: Binding(get: { preferences.visibleCalendarIDs == nil }, set: {
                    preferences.visibleCalendarIDs = $0 ? nil : Set(calendar.calendars.map(\.id))
                }))
                ForEach(calendar.calendars) { item in
                    Toggle(item.title, isOn: Binding(get: { preferences.visibleCalendarIDs?.contains(item.id) ?? true }, set: { enabled in
                        var ids = preferences.visibleCalendarIDs ?? Set(calendar.calendars.map(\.id))
                        if enabled { ids.insert(item.id) } else { ids.remove(item.id) }
                        preferences.visibleCalendarIDs = ids
                    }))
                }
                if calendar.calendars.isEmpty { Text(strings["Нет доступных календарей."]).foregroundStyle(.secondary) }
                Button(strings["Открыть системные настройки"]) { calendar.openPrivacySettings() }
            } else { CalendarAccessView(service: calendar) }
        } header: { Label(strings["Календарь"], systemImage: "calendar") }
    }
}
