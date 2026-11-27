import Foundation

struct AssistantCatalogModel: Identifiable {
    struct ID: Hashable {
        let gateway: AssistantGateway?
        let modelID: String
    }

    let gateway: AssistantGateway?
    let modelID: String
    var name: String
    var supportsChat = false
    var speech: AssistantTranscriptionSelection?
    var speechCatalogPending = false

    var id: ID { ID(gateway: gateway, modelID: modelID) }
    var supportsSpeech: Bool { speech != nil }
    var providerName: String { gateway?.name ?? "ChatGPT" }
}

extension AssistantService {
    func modelCatalog(preferences: AppPreferences) -> [AssistantCatalogModel] {
        var catalog: [AssistantCatalogModel.ID: AssistantCatalogModel] = [:]
        if cloud.isConnected {
            for model in cloud.models {
                let entry = AssistantCatalogModel(gateway: nil, modelID: model.id, name: model.name, supportsChat: true)
                catalog[entry.id] = entry
            }
        }
        for gateway in AssistantGateway.allCases {
            guard let profile = gateways.profiles[gateway] else { continue }
            let speechModels = gateways.speechCatalogs[profile.id]
            for model in gateways.catalogs[gateway] ?? [] {
                let entry = AssistantCatalogModel(gateway: gateway, modelID: model.id, name: model.name,
                    supportsChat: true, speechCatalogPending: gateway.supportsTranscription && speechModels == nil)
                catalog[entry.id] = entry
            }
            var selections = (speechModels ?? []).map {
                AssistantTranscriptionSelection(gateway: gateway, profileID: profile.id, modelID: $0.id, name: $0.name)
            }
            selections += preferences.manualSpeechModels.filter { $0.profileID == profile.id }
            // Ручной выбор LiteLLM из прежней версии не был отдельной записью в каталоге.
            if let active = preferences.transcriptionModel, active.profileID == profile.id,
               gateway == .liteLLM || speechModels == nil { selections.append(active) }
            for selection in selections {
                let id = AssistantCatalogModel.ID(gateway: gateway, modelID: selection.modelID)
                var entry = catalog[id] ?? AssistantCatalogModel(gateway: gateway, modelID: selection.modelID, name: selection.name)
                entry.speech = entry.speech ?? selection
                entry.speechCatalogPending = false
                catalog[id] = entry
            }
        }
        return catalog.values.sorted {
            if $0.providerName != $1.providerName { return $0.providerName < $1.providerName }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.modelID < $1.modelID : order == .orderedAscending
        }
    }

    func chatMenuModels(preferences: AppPreferences) -> [AssistantCatalogModel] {
        modelCatalog(preferences: preferences).filter { $0.supportsChat && preferences.assistantModelVisibility.includes($0) }
    }

    var configuredChatModelID: AssistantCatalogModel.ID? {
        guard let settings = current?.cloud, let modelID = settings.modelID else { return nil }
        return .init(gateway: settings.gateway, modelID: modelID)
    }

    func selectedChatModelID(in visibility: AssistantModelVisibility) -> AssistantCatalogModel.ID? {
        guard let id = configuredChatModelID, visibility.includes(id) else { return nil }
        let available = id.gateway == nil ? cloudModel != nil : gatewayModel != nil
        return available ? id : nil
    }

    func canSelectChatModel(_ model: AssistantCatalogModel) -> Bool {
        guard !generating, !applying, !storageFailed else { return false }
        if let gateway = model.gateway { return !gateways.busy.contains(gateway) }
        return cloud.canSend(to: chatGPTAccountID)
    }

    func selectChatModel(_ model: AssistantCatalogModel, visibility: AssistantModelVisibility) {
        guard visibility.includes(model), model.supportsChat, canSelectChatModel(model) else { return }
        if let gateway = model.gateway { selectGatewayModel(model.modelID, gateway: gateway) }
        else { selectCloudModel(model.modelID) }
    }
}
