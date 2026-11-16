import SwiftUI
import SwiftData

struct AssistantSettingsSection: View {
    @Environment(\.translations) private var strings
    @Bindable var assistant: AssistantService
    @Bindable var preferences: AppPreferences
    @Query(sort: \TaskFolder.sortOrder) private var folders: [TaskFolder]
    @State private var modelPurpose: AssistantModelPurpose?
    @State private var clearHistory = false
    var body: some View {
        Section {
            LabeledContent(strings["Модель чата"]) {
                Button {
                    modelPurpose = .chat
                } label: {
                    Label(assistant.current?.usesCloudModel == true ? assistant.cloudModelName : strings["Выберите модель чата"],
                          systemImage: "chevron.up.chevron.down")
                }
                .accessibilityIdentifier("assistant-settings-model-connections")
            }
            LabeledContent(strings["Модель для расшифровки"]) {
                Button {
                    modelPurpose = .transcription
                } label: {
                    Label(preferences.transcriptionModel?.name ?? strings["Выберите модель для расшифровки"],
                          systemImage: "chevron.up.chevron.down")
                }
            }
            Toggle(strings["Добавлять в текущую папку"], isOn: $preferences.assistantUseCurrentFolder)
            Picker(strings["Папка по умолчанию"], selection: $preferences.assistantDefaultFolder) {
                ForEach(AssistantService.folders(folders, preferences: preferences)) { Text($0.name).tag($0.id) }
            }
            Button(strings["Очистить историю…"], role: .destructive) { clearHistory = true }.disabled(assistant.generating || assistant.applying)
        } header: { Label(strings["Помощник"], systemImage: "sparkles") }
        .sheet(item: $modelPurpose) { purpose in
            AssistantModelConnections(service: assistant, russian: preferences.language.resolvedCode == "ru",
                                      preferences: preferences, purpose: purpose)
        }
        .alert(strings["Очистить историю помощника?"], isPresented: $clearHistory) {
            Button(strings["Очистить"], role: .destructive) { assistant.clearHistory() }
            Button(strings["Отмена"], role: .cancel) {}
        } message: { Text(strings["Созданные задачи и события сохранятся."]) }
    }
}
