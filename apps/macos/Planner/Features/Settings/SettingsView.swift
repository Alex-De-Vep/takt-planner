import SwiftUI
import PlannerLocalization

/// Нативное окно настроек macOS, доступное через меню приложения и ⌘,.
struct SettingsView: View {
    private enum Pane: String, CaseIterable {
        case general, backup, notifications, calendar, assistant

        var label: (title: String, icon: String) {
            switch self {
            #if SHOWCASE
            case .general: ("Основные", "gearshape")
            #else
            case .general: ("Аккаунт", "person.crop.circle")
            #endif
            case .backup: ("Резервная копия", "externaldrive")
            case .notifications: ("Уведомления", "bell")
            case .calendar: ("Календарь", "calendar")
            case .assistant: ("Помощник", "sparkles")
            }
        }
    }

    @Environment(\.translations) private var strings
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Pane? = .general
    @State private var showingSupport = false
    @Bindable var preferences: AppPreferences
    let calendar: CalendarService
    @Bindable var notifications: PlannerNotifications
    var cloud: CloudWorkspace? = nil
    var service: TaskService? = nil
    let assistant: AssistantService
    let restoreBackup: (PlannerBackup) throws -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(Pane.allCases, id: \.self) { pane in
                        Label {
                            Text(strings[pane.label.title])
                                .foregroundStyle(selection == pane ? PlannerStyle.settingsAccent : .primary)
                        } icon: {
                            Image(systemName: pane.label.icon).foregroundStyle(PlannerStyle.settingsAccent)
                        }
                        .accessibilityIdentifier("settings-pane-\(pane.rawValue)")
                        .tag(pane)
                        .listItemTint(.fixed(.clear))
                        .listRowBackground(selection == pane
                            ? RoundedRectangle(cornerRadius: 8).fill(PlannerStyle.settingsSelection).padding(.horizontal, 8)
                            : nil)
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
                #if !SHOWCASE
                if cloud != nil {
                    Button { showingSupport = true } label: {
                        Label(strings["Написать нам"], systemImage: "envelope")
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("settings-support")
                }
                #endif
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
        .sheet(isPresented: $showingSupport) {
            if let cloud { SupportRequestSheet(cloud: cloud, service: service) }
        }
        .onAppear { calendar.refresh() }
        .onChange(of: preferences.assistantSettingsRequest, initial: true) { _, request in
            if request != nil {
                selection = .assistant
                preferences.assistantSettingsRequest = nil
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .general {
        case .general: general
        case .backup:
            BackupSettingsSection(preferences: preferences, service: service, assistant: assistant, restore: restoreBackup)
        case .notifications:
            NotificationSettingsSection(preferences: preferences, notifications: notifications)
        case .calendar: calendarSettings
        case .assistant:
            AssistantSettingsSection(assistant: assistant, preferences: preferences)
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
                .tint(PlannerStyle.settingsControlTint)
                ForEach(calendar.calendars) { item in
                    Toggle(item.title, isOn: Binding(get: { preferences.visibleCalendarIDs?.contains(item.id) ?? true }, set: { enabled in
                        var ids = preferences.visibleCalendarIDs ?? Set(calendar.calendars.map(\.id))
                        if enabled { ids.insert(item.id) } else { ids.remove(item.id) }
                        preferences.visibleCalendarIDs = ids
                    }))
                    .tint(PlannerStyle.settingsControlTint)
                }
                if calendar.calendars.isEmpty { Text(strings["Нет доступных календарей."]).foregroundStyle(.secondary) }
                Button(strings["Открыть системные настройки"]) { calendar.openPrivacySettings() }
            } else { CalendarAccessView(service: calendar, primaryTint: PlannerStyle.settingsControlTint) }
        } header: { Label(strings["Календарь"], systemImage: "calendar") }
    }
}
