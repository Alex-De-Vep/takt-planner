import SwiftUI
import SwiftData

struct AssistantSettingsSection: View {
    @Environment(\.translations) private var strings
    @Bindable var assistant: AssistantService
    @Bindable var preferences: AppPreferences
    @Query(sort: \TaskFolder.sortOrder) private var folders: [TaskFolder]
    @State private var providerSheet: AssistantProviderSheetRoute?
    @State private var showingCatalog = false
    @State private var showingAllModels = false
    @State private var clearHistory = false

    private var connected: [AssistantProviderOption] {
        AssistantProviderOption.all.filter { $0.isConnected(to: assistant) }
    }

    var body: some View {
        let catalog = assistant.modelCatalog(preferences: preferences)
        let visibility = preferences.assistantModelVisibility
        Section(strings["ИИ-провайдеры"]) {
            Button {
                providerSheet = .choose
            } label: {
                Label(strings["Подключить ИИ-провайдер"], systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(PlannerStyle.settingsControlTint)
            .accessibilityIdentifier("assistant-connect-provider")
            ForEach(connected) { provider in
                Button {
                    providerSheet = .manage(provider)
                } label: {
                    HStack {
                        Label(provider.name, systemImage: "checkmark.circle")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityIdentifier("assistant-provider-\(provider.id)")
            }
        }
        .sheet(item: $providerSheet) { route in
            AssistantProvidersSheet(service: assistant, preferences: preferences, route: route)
        }
        .onAppear {
            assistant.cloud.activate()
            assistant.gateways.activate()
            rememberConnections()
        }
        .onChange(of: assistant.gateways.profiles.values.map { $0.id.uuidString }.sorted()) {
            assistant.gateways.loadSpeechCatalogs()
        }
        .onChange(of: connected.map(\.id)) {
            if providerSheet == nil { rememberConnections() }
        }
        .onChange(of: providerSheet?.id) {
            if providerSheet == nil { rememberConnections() }
        }

        Section(strings["Выбранные модели"]) {
            Button {
                showingCatalog = true
            } label: {
                Label(strings["Добавить модели"], systemImage: "plus")
            }.disabled(connected.isEmpty)
            let selected = catalog.filter { visibility.includes($0) }
            if selected.isEmpty {
                Text(strings[connected.isEmpty ? "Сначала подключите провайдера." : "Модели ещё не выбраны."]).foregroundStyle(.secondary)
            }
            ForEach(showingAllModels ? selected : Array(selected.prefix(6))) { model in
                HStack {
                    AssistantCatalogModelLabel(model: model)
                    Spacer()
                    Button(strings["Убрать из списка"], systemImage: "minus.circle") {
                        preferences.assistantModelVisibility.setIncluded(false, model: model)
                    }.labelStyle(.iconOnly).buttonStyle(.borderless).help(strings["Убрать из списка"])
                }
            }
            if selected.count > 6 {
                Button(showingAllModels ? strings["Свернуть список"] : strings.format("Показать все модели (%d)", selected.count)) {
                    showingAllModels.toggle()
                }
            }
        }
        .sheet(isPresented: $showingCatalog) {
            AssistantModelVisibilityEditor(service: assistant, preferences: preferences)
        }

        Section(strings["Активные модели"]) {
            LabeledContent(strings["Модель чата"]) {
                AssistantChatModelMenu(service: assistant, preferences: preferences)
                    .accessibilityIdentifier("assistant-settings-chat-model")
            }
            LabeledContent(strings["Модель для расшифровки"]) {
                AssistantSpeechModelMenu(service: assistant, preferences: preferences)
            }
        }

        Section(strings["Помощник"]) {
            Toggle(strings["Добавлять в текущую папку"], isOn: $preferences.assistantUseCurrentFolder)
                .tint(PlannerStyle.settingsControlTint)
            Picker(strings["Папка по умолчанию"], selection: $preferences.assistantDefaultFolder) {
                ForEach(AssistantService.folders(folders, preferences: preferences)) { Text($0.name).tag($0.id) }
            }
            Button(strings["Очистить историю…"], role: .destructive) { clearHistory = true }
                .disabled(assistant.generating || assistant.applying)
        }
        .alert(strings["Очистить историю помощника?"], isPresented: $clearHistory) {
            Button(strings["Очистить"], role: .destructive) { assistant.clearHistory() }
            Button(strings["Отмена"], role: .cancel) {}
        } message: { Text(strings["Созданные задачи и события сохранятся."]) }
    }

    private func rememberConnections() {
        var visibility = preferences.assistantModelVisibility
        for provider in connected { visibility.rememberConnection(gateway: provider.gateway) }
        if visibility != preferences.assistantModelVisibility { preferences.assistantModelVisibility = visibility }
        assistant.gateways.loadSpeechCatalogs()
    }
}
