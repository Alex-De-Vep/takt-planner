import Foundation

struct AssistantModelVisibility: Codable, Equatable {
    // Older versions also stored lists of hidden models. Only affirmative choices
    // identify models the user actually added, including after a provider reconnects.
    private var choices: [String: [String: Bool]]?

    static func source(_ gateway: AssistantGateway?) -> String { gateway?.rawValue ?? "chatGPT" }

    func includes(_ id: AssistantCatalogModel.ID) -> Bool {
        choices?[Self.source(id.gateway)]?[id.modelID] == true
    }

    func includes(_ model: AssistantCatalogModel) -> Bool { includes(model.id) }

    mutating func setIncluded(_ included: Bool, model: AssistantCatalogModel) {
        var updated = choices ?? [:]
        updated[Self.source(model.gateway), default: [:]][model.modelID] = included
        choices = updated
    }
}
