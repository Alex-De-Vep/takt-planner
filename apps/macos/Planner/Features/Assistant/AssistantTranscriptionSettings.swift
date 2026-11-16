import SwiftUI

struct AssistantTranscriptionSelection: Codable, Hashable, Identifiable {
    let gateway: AssistantGateway
    let profileID: UUID
    let modelID: String
    let name: String

    var id: String { "\(profileID):\(modelID)" }

    @MainActor func profile(in connections: AssistantGatewayConnections) -> AssistantGatewayProfile? {
        guard gateway == .openRouter || gateway == .liteLLM,
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
    let connections: AssistantGatewayConnections
    @Bindable var preferences: AppPreferences
    @State private var choices: [AssistantTranscriptionSelection] = []
    @State private var errors: [AssistantGateway: String] = [:]
    @State private var loading = false
    @State private var proxyModel = ""

    private var profiles: [AssistantGatewayProfile] {
        [.openRouter, .liteLLM].compactMap { connections.profiles[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(strings["Модель для расшифровки"]).font(.headline)
            if profiles.isEmpty {
                Text(strings["Подключите OpenRouter или LiteLLM для расшифровки записей."]).foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(choices) { option in
                        Button("\(option.gateway.name) · \(option.name)") { preferences.transcriptionModel = option }
                    }
                } label: {
                    if let selected = preferences.transcriptionModel, selected.profile(in: connections) != nil {
                        Text("\(selected.gateway.name) · \(selected.name)").lineLimit(1)
                    } else {
                        Text(strings["Выбрать модель для расшифровки"])
                    }
                }
                .disabled(choices.isEmpty)
                if loading { ProgressView().controlSize(.small) }
                ForEach(profiles, id: \.id) { profile in
                    if let error = errors[profile.gateway] { Text(strings[error]).font(.caption).foregroundStyle(.secondary) }
                }
                if let proxy = connections.profiles[.liteLLM] {
                    HStack {
                        TextField(strings["Идентификатор модели расшифровки в LiteLLM"], text: $proxyModel)
                        Button(strings["Выбрать"]) {
                            let id = proxyModel.trimmingCharacters(in: .whitespacesAndNewlines)
                            preferences.transcriptionModel = .init(gateway: .liteLLM, profileID: proxy.id, modelID: id, name: id)
                            proxyModel = ""
                        }
                        .disabled(proxyModel.isEmpty || proxyModel.utf8.count > 512 ||
                                  proxyModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  proxyModel.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
                        .help(strings["Укажите модель распознавания, настроенную на вашем сервере LiteLLM."])
                    }
                }
            }
        }
        .task(id: profiles.map(\.id)) {
            let current = profiles
            choices = []
            errors = [:]
            loading = true
            defer { if !Task.isCancelled { loading = false } }
            for profile in current {
                do {
                    let catalog = try await connections.http.transcriptionModels(profile)
                    try Task.checkCancellation()
                    var ids = Set<String>()
                    choices += catalog.filter { !$0.id.isEmpty && ids.insert($0.id).inserted }.map {
                        .init(gateway: profile.gateway, profileID: profile.id, modelID: $0.id, name: $0.name)
                    }
                } catch {
                    if Task.isCancelled { return }
                    errors[profile.gateway] = "Не удалось загрузить модели для расшифровки."
                }
            }
        }
    }
}
