import SwiftUI

struct AssistantTranscriptionSelection: Codable, Hashable, Identifiable {
    let gateway: AssistantGateway
    let profileID: UUID
    let modelID: String
    let name: String

    var id: String { "\(profileID):\(modelID)" }

    @MainActor func profile(in connections: AssistantGatewayConnections) -> AssistantGatewayProfile? {
        guard gateway.supportsTranscription,
              let profile = connections.profiles[gateway], profile.id == profileID else { return nil }
        return profile
    }
}

struct AssistantTranscriptionModel {
    let id: String
    let name: String
}

struct AssistantTranscriptionSettings: View {
    @Environment(\.translations) private var strings
    let profile: AssistantGatewayProfile
    let http: AssistantGatewayHTTP
    @Bindable var preferences: AppPreferences
    @State private var choices: [AssistantTranscriptionSelection] = []
    @State private var loadFailed = false
    @State private var loading = true
    @State private var refreshID = 0
    @State private var proxyModel = ""

    private var selected: AssistantTranscriptionSelection? {
        guard let selection = preferences.transcriptionModel,
              selection.gateway == profile.gateway, selection.profileID == profile.id else { return nil }
        return selection
    }

    private var models: [AssistantTranscriptionSelection] {
        // Показываем сохранённую модель при загрузке каталога и при ручном вводе в LiteLLM.
        if let selected, !choices.contains(where: { $0.id == selected.id }) {
            return [selected] + choices
        }
        return choices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AssistantSettingsModelPicker(models: models.map { ($0.modelID, $0.name) }, selectedID: selected?.modelID,
                                         emptyLabel: pickerLabel, refresh: { refreshID += 1 }, refreshing: loading) { id in
                if let model = models.first(where: { $0.modelID == id }) {
                    preferences.transcriptionModel = model
                }
            }
            if loadFailed {
                Text(strings["Не удалось загрузить модели для расшифровки."]).font(.caption).foregroundStyle(.secondary)
            }
            if profile.gateway == .liteLLM {
                DisclosureGroup(strings["Указать модель вручную"]) {
                    HStack {
                        TextField(strings["Идентификатор модели расшифровки в LiteLLM"], text: $proxyModel)
                        Button(strings["Выбрать"]) {
                            let id = proxyModel.trimmingCharacters(in: .whitespacesAndNewlines)
                            preferences.transcriptionModel = .init(gateway: profile.gateway, profileID: profile.id,
                                                                   modelID: id, name: id)
                            proxyModel = ""
                        }
                        .disabled(proxyModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || proxyModel.utf8.count > 512
                                  || proxyModel.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
                        .help(strings["Укажите модель распознавания, настроенную на вашем сервере LiteLLM."])
                    }
                }
            }
        }
        .task(id: refreshID) {
            loading = true
            loadFailed = false
            defer { if !Task.isCancelled { loading = false } }
            do {
                let catalog = try await http.transcriptionModels(profile)
                try Task.checkCancellation()
                var ids = Set<String>()
                choices = catalog.filter { !$0.id.isEmpty && ids.insert($0.id).inserted }.map {
                    .init(gateway: profile.gateway, profileID: profile.id, modelID: $0.id, name: $0.name)
                }
            } catch {
                if !Task.isCancelled { loadFailed = true }
            }
        }
    }

    private var pickerLabel: String {
        if loading { return "Загружаем модели…" }
        if models.isEmpty { return "Нет доступных моделей" }
        return "Выбрать модель"
    }
}
