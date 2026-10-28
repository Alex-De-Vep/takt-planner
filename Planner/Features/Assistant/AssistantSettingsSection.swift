import SwiftUI
import SwiftData

struct AssistantSettingsSection: View {
    @Environment(\.translations) private var strings
    @Bindable var assistant: AssistantService
    @Bindable var preferences: AppPreferences
    @Query(sort: \TaskFolder.sortOrder) private var folders: [TaskFolder]
    @State private var removeModel = false
    @State private var clearHistory = false
    var body: some View {
        Section {
            Text(strings["Требуется Mac с чипом Apple M1 или новее."]).foregroundStyle(.secondary)
            Text(assistant.model.displayName + " · " + ByteCountFormatter.string(fromByteCount: assistant.model.total, countStyle: .file))
            HStack {
                Button(strings[assistant.model.state == .ready ? "Выключить помощника" : "Открыть помощника"]) {
                    if assistant.model.state == .ready { assistant.stop(); Task { await assistant.model.disable() } }
                    else { preferences.rightPanel = .assistant; NSApp.activate() }
                }.disabled(assistant.applying)
                Button(strings["Удалить модель…"], role: .destructive) { removeModel = true }
                    .disabled(assistant.generating || assistant.applying || assistant.model.busy)
            }
            Toggle(strings["Добавлять в текущую папку"], isOn: $preferences.assistantUseCurrentFolder)
            Picker(strings["Папка по умолчанию"], selection: $preferences.assistantDefaultFolder) {
                ForEach(AssistantService.folders(folders, preferences: preferences)) { Text($0.name).tag($0.id) }
            }
            Picker(strings["Длительность события"], selection: $preferences.assistantDuration) {
                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text(strings.format("%d мин", $0)).tag($0) }
            }
            Picker(strings["Напоминание события"], selection: $preferences.assistantReminder) {
                Text(strings["Без напоминания"]).tag(-1)
                ForEach([0, 5, 10, 15, 30, 60, 1440], id: \.self) { Text(strings.format("За %d мин", $0)).tag($0) }
            }
            Text(strings["Для событий используется календарь, выбранный в разделе «Календарь»."]).font(.caption).foregroundStyle(.secondary)
            Button(strings["Очистить историю…"], role: .destructive) { clearHistory = true }.disabled(assistant.generating || assistant.applying)
        } header: { Label(strings["Помощник"], systemImage: "sparkles") }
        .alert(strings["Удалить модель?"], isPresented: $removeModel) {
            Button(strings["Удалить"], role: .destructive) { Task { await assistant.model.remove() } }
            Button(strings["Отмена"], role: .cancel) {}
        } message: { Text(strings["Задачи, события и история чата сохранятся."]) }
        .alert(strings["Очистить историю помощника?"], isPresented: $clearHistory) {
            Button(strings["Очистить"], role: .destructive) { assistant.clearHistory() }
            Button(strings["Отмена"], role: .cancel) {}
        } message: { Text(strings["Созданные задачи и события сохранятся."]) }
    }
}
