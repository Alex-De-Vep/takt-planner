import SwiftUI

struct AssistantModelVisibilityEditor: View {
    @Environment(\.translations) private var strings
    @Environment(\.dismiss) private var dismiss
    let service: AssistantService
    @Bindable var preferences: AppPreferences
    @State private var search = ""
    @State private var manualID = ""

    private var filteredModels: [AssistantCatalogModel] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return service.modelCatalog(preferences: preferences).filter {
            query.isEmpty || $0.name.localizedStandardContains(query) || $0.modelID.localizedStandardContains(query)
                || $0.providerName.localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(strings["Добавить модели"]).font(.headline)
            TextField(strings["Поиск моделей"], text: $search).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("assistant-model-list-search")
            let models = filteredModels
            List {
                ForEach(Dictionary(grouping: models, by: \.providerName).keys.sorted(), id: \.self) { provider in
                    Section(provider) {
                        ForEach(models.filter { $0.providerName == provider }) { model in
                            Toggle(isOn: Binding(get: { preferences.assistantModelVisibility.includes(model) }, set: {
                                preferences.assistantModelVisibility.setIncluded($0, model: model)
                            })) {
                                AssistantCatalogModelLabel(model: model, showProvider: false)
                            }.toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .overlay {
                if models.isEmpty {
                    Text(strings[loading ? "Загружаем модели…" : "Нет доступных моделей"]).foregroundStyle(.secondary)
                }
            }
            if service.gateways.profiles[.liteLLM] != nil {
                DisclosureGroup(strings["Указать модель вручную"]) {
                    HStack {
                        TextField(strings["Идентификатор модели расшифровки в LiteLLM"], text: $manualID)
                        Button(strings["Добавить"]) { addManualModel() }.disabled(!validManualID)
                    }.padding(.top, 6)
                }
            }
            HStack {
                Button(strings["Обновить список моделей"], action: refresh).disabled(loading)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Button(strings["Готово"]) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let error = service.gateways.errors.values.sorted().first ?? service.cloud.error {
                Text(strings[error]).font(.caption).foregroundStyle(.secondary)
            } else if !service.gateways.speechFailed.isEmpty {
                Text(strings["Не удалось загрузить модели для расшифровки."]).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20).frame(width: 530, height: 510)
    }

    private var loading: Bool {
        service.cloud.busy || !service.gateways.busy.isEmpty || !service.gateways.speechLoading.isEmpty
    }

    private func refresh() {
        for gateway in service.gateways.profiles.keys where !gateway.configuredCatalog { service.gateways.refresh(gateway) }
        service.gateways.loadSpeechCatalogs(refresh: true)
        service.cloud.refreshModels()
    }

    private var cleanManualID: String { manualID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validManualID: Bool {
        !cleanManualID.isEmpty && cleanManualID.utf8.count <= 512
            && !cleanManualID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private func addManualModel() {
        guard validManualID, let profile = service.gateways.profiles[.liteLLM] else { return }
        let selection = AssistantTranscriptionSelection(gateway: .liteLLM, profileID: profile.id, modelID: cleanManualID, name: cleanManualID)
        if !preferences.manualSpeechModels.contains(where: { $0.id == selection.id }) {
            preferences.manualSpeechModels.append(selection)
        }
        let model = AssistantCatalogModel(gateway: .liteLLM, modelID: selection.modelID, name: selection.name, speech: selection)
        preferences.assistantModelVisibility.setIncluded(true, model: model)
        manualID = ""
    }
}

struct AssistantCatalogModelLabel: View {
    @Environment(\.translations) private var strings
    let model: AssistantCatalogModel
    var showProvider = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.name).lineLimit(1)
            Text((showProvider ? model.providerName + " · " : "") + strings[capability])
                .font(.caption).foregroundStyle(.secondary)
        }.help(model.modelID)
    }

    private var capability: String {
        if model.supportsSpeech { return model.supportsChat ? "Чат и расшифровка" : "Только расшифровка" }
        if model.speechCatalogPending { return "Поддержка расшифровки не проверена" }
        return "Не поддерживает расшифровку"
    }
}
