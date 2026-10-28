import SwiftUI
import PlannerLocalization

/// Нативное окно настроек macOS, доступное через меню приложения и ⌘,.
struct SettingsView: View {
    @Environment(\.translations) private var strings
    @Bindable var preferences: AppPreferences
    let calendar: CalendarService
    @Bindable var notifications: PlannerNotifications
    let assistant: AssistantService

    var body: some View {
        Form {
            Section {
                Picker(strings["Язык интерфейса"], selection: $preferences.language) {
                    Text(strings["Как в системе"]).tag(AppLanguage.system)
                    Text("Русский").tag(AppLanguage.russian)
                    Text("English").tag(AppLanguage.english)
                }
                .accessibilityIdentifier("language-picker")
            } header: {
                Label(strings["Основные"], systemImage: "gearshape")
            } footer: {
                Text(strings["Язык меняется сразу. Названия ваших папок и задач сохраняются без изменений."])
            }
            AssistantSettingsSection(assistant: assistant, preferences: preferences)
            NotificationSettingsSection(preferences: preferences, notifications: notifications)
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
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
        .navigationTitle(strings["Настройки"])
        .onAppear { calendar.refresh() }
    }
}
