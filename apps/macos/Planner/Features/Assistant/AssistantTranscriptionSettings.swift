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
