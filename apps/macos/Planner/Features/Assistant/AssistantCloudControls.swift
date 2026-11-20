import SwiftUI

/// Один список моделей в чате, с настройками подключения отдельно от отправки сообщения.
struct AssistantModelPicker: View {
    @Environment(\.translations) private var strings
    let service: AssistantService
    let preferences: AppPreferences
    let configureModels: () -> Void

    private var isCloud: Bool { service.current?.usesCloudModel == true }
    private var locked: Bool { service.generating || service.applying || service.storageFailed }

    var body: some View {
        HStack(spacing: 10) {
            AssistantChatModelMenu(service: service, preferences: preferences, configureModels: configureModels)
                .accessibilityIdentifier("assistant-model-picker")

            if isCloud, !service.cloudEfforts.isEmpty {
                Menu {
                    Button { service.selectCloudEffort(nil) } label: {
                        if service.cloudEffort == nil { Label(strings["По умолчанию"], systemImage: "checkmark") }
                        else { Text(strings["По умолчанию"]) }
                    }
                    ForEach(service.cloudEfforts, id: \.self) { effort in
                        Button { service.selectCloudEffort(effort) } label: {
                            if effort == service.cloudEffort { Label(effortLabel(effort), systemImage: "checkmark") }
                            else { Text(effortLabel(effort)) }
                        }
                    }
                } label: { Image(systemName: "slider.horizontal.3") }
                .menuStyle(.borderlessButton).fixedSize()
                .help(strings["Глубина рассуждения"] + " · " + (service.cloudEffort.map(effortLabel) ?? strings["По умолчанию"]))
                .accessibilityLabel(strings["Глубина рассуждения"])
                .accessibilityValue(service.cloudEffort.map(effortLabel) ?? strings["По умолчанию"])
            }
        }
        .font(.caption).disabled(locked)
    }

    private func effortLabel(_ effort: String) -> String {
        let labels = ["none": "Без рассуждения", "minimal": "Минимальная", "low": "Низкая", "medium": "Средняя",
                      "high": "Высокая", "xhigh": "Очень высокая", "max": "Максимальная"]
        return strings[labels[effort] ?? effort]
    }
}

struct AssistantChatModelMenu: View {
    @Environment(\.translations) private var strings
    let service: AssistantService
    let preferences: AppPreferences
    var configureModels: (() -> Void)? = nil

    private var currentID: AssistantCatalogModel.ID? {
        if let gateway = service.gatewayProfile?.gateway, let model = service.gatewayModel {
            return .init(gateway: gateway, modelID: model.id)
        }
        if let model = service.cloudModel { return .init(gateway: nil, modelID: model.id) }
        return nil
    }

    var body: some View {
        let models = service.modelCatalog(preferences: preferences).filter {
            $0.supportsChat && preferences.assistantModelVisibility.includes($0)
        }
        let title = service.current?.usesCloudModel == true ? service.cloudModelName : strings["Выбрать модель"]
        Group {
            if configureModels != nil {
                modelMenu(models, title: title).menuStyle(.borderlessButton).frame(maxWidth: 164)
            } else {
                modelMenu(models, title: title).menuStyle(.borderedButton).frame(maxWidth: 245)
            }
        }
        .help(title)
        .accessibilityLabel(strings["Модель чата"])
        .accessibilityValue(title)
        .disabled((models.isEmpty && configureModels == nil) || service.generating || service.applying || service.storageFailed)
    }

    private func modelMenu(_ models: [AssistantCatalogModel], title: String) -> some View {
        Menu {
            let groups = Dictionary(grouping: models, by: \.providerName)
            if models.count <= 15 {
                choices(models, showProvider: groups.count > 1)
            } else {
                ForEach(groups.keys.sorted(), id: \.self) { provider in
                    if let entries = groups[provider] {
                        Menu(provider) {
                            if entries.count > 40 && entries.first?.gateway == .openRouter {
                                let vendors = Dictionary(grouping: entries) {
                                    $0.modelID.split(separator: "/").first.map(String.init) ?? provider
                                }
                                ForEach(vendors.keys.sorted(), id: \.self) { vendor in
                                    Menu(vendor) { choices(vendors[vendor] ?? []) }
                                }
                            } else { choices(entries) }
                        }
                    }
                }
            }
            if let configureModels {
                if !models.isEmpty { Divider() }
                Button(strings["Настроить список моделей…"], action: configureModels)
            }
        } label: {
            if configureModels != nil { Label(title, systemImage: "cloud").lineLimit(1) }
            else { Text(title).lineLimit(1) }
        }
    }

    private func choices(_ models: [AssistantCatalogModel], showProvider: Bool = false) -> some View {
        ForEach(models) { model in
            Button { service.selectChatModel(model) } label: {
                let title = showProvider ? model.providerName + " · " + model.name : model.name
                if currentID == model.id { Label(title, systemImage: "checkmark") }
                else { Text(title) }
            }.disabled(!service.canSelectChatModel(model))
        }
    }
}

struct AssistantSpeechModelMenu: View {
    @Environment(\.translations) private var strings
    let service: AssistantService
    let preferences: AppPreferences

    var body: some View {
        let models = service.modelCatalog(preferences: preferences).filter {
            $0.supportsSpeech && preferences.assistantModelVisibility.includes($0)
        }
        let selection = preferences.transcriptionModel
        let title = selection?.name ?? strings["Выбрать модель"]
        Menu {
            let groups = Dictionary(grouping: models, by: \.providerName)
            if models.count <= 15 {
                speechChoices(models, showProvider: groups.count > 1)
            } else {
                ForEach(groups.keys.sorted(), id: \.self) { provider in
                    Menu(provider) { speechChoices(groups[provider] ?? []) }
                }
            }
        } label: {
            Text(title).lineLimit(1)
        }
        .menuStyle(.borderedButton).frame(maxWidth: 245)
        .disabled(models.isEmpty)
        .help(title)
        .accessibilityLabel(strings["Модель для расшифровки"])
        .accessibilityValue(title)
        .accessibilityIdentifier("assistant-speech-model-picker")
    }

    private func speechChoices(_ models: [AssistantCatalogModel], showProvider: Bool = false) -> some View {
        ForEach(models) { model in
            if let speech = model.speech {
                Button { preferences.transcriptionModel = speech } label: {
                    let title = showProvider ? model.providerName + " · " + model.name : model.name
                    if preferences.transcriptionModel?.id == speech.id { Label(title, systemImage: "checkmark") }
                    else { Text(title) }
                }
            }
        }
    }
}
