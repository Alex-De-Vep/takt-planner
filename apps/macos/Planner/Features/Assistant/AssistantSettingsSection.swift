import SwiftUI
import SwiftData

struct AssistantSettingsSection: View {
    @Environment(\.translations) private var strings
    @Bindable var assistant: AssistantService
    @Bindable var preferences: AppPreferences
    @Query(sort: \TaskFolder.sortOrder) private var folders: [TaskFolder]
    @State private var showModelConnections = false
    @State private var clearHistory = false
    var body: some View {
        Section {
            Button { showModelConnections = true } label: {
                Label(strings["Подключения моделей…"], systemImage: "cpu")
            }
            .accessibilityIdentifier("assistant-settings-model-connections")
            Toggle(strings["Добавлять в текущую папку"], isOn: $preferences.assistantUseCurrentFolder)
            Picker(strings["Папка по умолчанию"], selection: $preferences.assistantDefaultFolder) {
                ForEach(AssistantService.folders(folders, preferences: preferences)) { Text($0.name).tag($0.id) }
            }
            Button(strings["Очистить историю…"], role: .destructive) { clearHistory = true }.disabled(assistant.generating || assistant.applying)
        } header: { Label(strings["Помощник"], systemImage: "sparkles") }
        .sheet(isPresented: $showModelConnections) {
            AssistantModelConnections(service: assistant, russian: preferences.language.resolvedCode == "ru")
        }
        .alert(strings["Очистить историю помощника?"], isPresented: $clearHistory) {
            Button(strings["Очистить"], role: .destructive) { assistant.clearHistory() }
            Button(strings["Отмена"], role: .cancel) {}
        } message: { Text(strings["Созданные задачи и события сохранятся."]) }
    }
}
