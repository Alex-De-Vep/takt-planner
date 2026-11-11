import SwiftUI
import SwiftData

struct AssistantSettingsSection: View {
    @Environment(\.translations) private var strings
    @Bindable var assistant: AssistantService
    @Bindable var preferences: AppPreferences
    @Query(sort: \TaskFolder.sortOrder) private var folders: [TaskFolder]
    @State private var removeModel = false
    @State private var showModelConnections = false
    @State private var clearHistory = false
    @State private var customIdle = false
    private let idleOptions: [Double] = [0, 60, 120, 300, 600, -1]
    private var idleSelection: Binding<Double> {
        Binding(get: { customIdle || !idleOptions.contains(assistant.model.idleSeconds) ? -2 : assistant.model.idleSeconds }, set: { value in
            customIdle = value == -2
            assistant.model.idleSeconds = customIdle ? 180 : value
        })
    }
    var body: some View {
        Section {
            Button { showModelConnections = true } label: {
                Label(strings["Подключения моделей…"], systemImage: "cpu")
            }
            .accessibilityIdentifier("assistant-settings-model-connections")
            Text(strings["Требуется Mac с чипом Apple M1 или новее."]).foregroundStyle(.secondary)
            Text(assistant.model.displayName + " · " + ByteCountFormatter.string(fromByteCount: assistant.model.total, countStyle: .file))
            HStack {
                Button(strings[assistant.model.enabled ? "Выключить помощника" : "Открыть помощника"]) {
                    if assistant.model.enabled { Task { await assistant.disableModel() } }
                    else { preferences.rightPanel = .assistant; NSApp.activate() }
                }.disabled(assistant.applying)
                Button(strings["Удалить модель…"], role: .destructive) { removeModel = true }
                    .disabled(assistant.generating || assistant.applying || assistant.model.busy)
            }
            Text(strings["Модель загружается в память только при отправке сообщения. Открытие чата не загружает модель."])
                .font(.caption).foregroundStyle(.secondary)
            Picker(strings["Выгружать после простоя"], selection: idleSelection) {
                Text(strings["Сразу после ответа"]).tag(Double(0))
                ForEach([1, 2, 5, 10], id: \.self) { Text(strings.format("%d мин", $0)).tag(Double($0 * 60)) }
                Text(strings["До выхода из приложения"]).tag(Double(-1))
                Text(strings["Своё время"]).tag(Double(-2))
            }
            if customIdle || !idleOptions.contains(assistant.model.idleSeconds) {
                Stepper(value: Binding(get: { max(1, Int(assistant.model.idleSeconds / 60)) }, set: { assistant.model.idleSeconds = Double($0 * 60) }), in: 1...60) {
                    Text(strings.format("%d мин", max(1, Int(assistant.model.idleSeconds / 60))))
                }
            }
            Text(strings["Простой отсчитывается от последнего ответа. При нехватке памяти модель выгружается независимо от настройки."])
                .font(.caption).foregroundStyle(.secondary)
            Button(strings["Освободить память сейчас"]) { Task { await assistant.model.unloadNow() } }
                .disabled(assistant.generating || assistant.model.state != .ready)
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
        .sheet(isPresented: $showModelConnections) {
            AssistantModelConnections(service: assistant, russian: preferences.language.resolvedCode == "ru")
        }
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
