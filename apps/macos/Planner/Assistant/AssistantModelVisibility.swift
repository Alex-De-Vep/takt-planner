import Foundation

enum AssistantModelPurpose: String, Identifiable, Codable {
    case chat, transcription
    var id: Self { self }
}

/// Идентификатор сервиса стабилен при обновлении ключа или повторном подключении.
struct AssistantModelVisibility: Codable, Equatable {
    private var chat: [String: Set<String>] = [:]
    private var transcription: [String: Set<String>] = [:]

    private var choices: [String: [String: Bool]]? = nil
    private var curatedSources: Set<String>? = nil

    private var knownSources: Set<String>? = nil

    mutating func rememberConnection(gateway: AssistantGateway?) {
        var known = knownSources ?? []
        if known.insert(Self.source(gateway)).inserted { knownSources = known }
    }

    mutating func startWithEmptyList(gateway: AssistantGateway?) {
        guard knownSources?.contains(Self.source(gateway)) != true else { return }
        rememberConnection(gateway: gateway)
        var curated = curatedSources ?? []
        curated.insert(Self.source(gateway))
        curatedSources = curated
    }

    static func source(_ gateway: AssistantGateway?) -> String { gateway?.rawValue ?? "chatGPT" }

    func includes(_ model: AssistantCatalogModel) -> Bool {
        let source = Self.source(model.gateway)
        if let choice = choices?[source]?[model.modelID] { return choice }
        if curatedSources?.contains(source) == true { return false }
        // В общий список попадают модели, которые были видны хотя бы в одном из прежних списков.
        return (model.supportsChat && isVisible(model.modelID, gateway: model.gateway, purpose: .chat))
            || (model.supportsSpeech && isVisible(model.modelID, gateway: model.gateway, purpose: .transcription))
    }

    mutating func setIncluded(_ included: Bool, model: AssistantCatalogModel) {
        var choices = choices ?? [:]
        choices[Self.source(model.gateway), default: [:]][model.modelID] = included
        self.choices = choices
    }

    func isVisible(_ modelID: String, gateway: AssistantGateway?, purpose: AssistantModelPurpose) -> Bool {
        let hidden = purpose == .chat ? chat : transcription
        return hidden[Self.source(gateway)]?.contains(modelID) != true
    }

    mutating func setVisible(_ visible: Bool, modelID: String, gateway: AssistantGateway?, purpose: AssistantModelPurpose) {
        let source = Self.source(gateway)
        var hidden = purpose == .chat ? chat : transcription
        var ids = hidden[source] ?? []
        if visible { ids.remove(modelID) } else { ids.insert(modelID) }
        hidden[source] = ids.isEmpty ? nil : ids
        if purpose == .chat { chat = hidden } else { transcription = hidden }
    }
}
