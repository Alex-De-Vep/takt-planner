import SwiftUI

/// Ручное разрешение инструментов относится к модели, а не к подключению провайдера.
struct AssistantGatewayModelCapabilities: View {
    @Environment(\.translations) private var strings
    let service: AssistantService
    let gateway: AssistantGateway
    @State private var editedModelID: String?
    private var models: [AssistantGatewayModel] {
        (service.gateways.catalogs[gateway] ?? []).filter { $0.reportedTools == nil }
    }
    var body: some View {
        if let profile = service.gateways.profiles[gateway], !models.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                let currentID = models.first(where: { $0.id == editedModelID })?.id ?? models.first?.id
                Picker(strings["Модель"], selection: Binding(get: { currentID }, set: { editedModelID = $0 })) {
                    ForEach(models) { model in Text(model.name).tag(Optional(model.id)) }
                }
                if let currentID {
                    Toggle(strings["Разрешить работу с задачами"], isOn: Binding(
                        get: { profile.toolModelIDs.contains(currentID) },
                        set: { service.gateways.setTools($0, gateway: gateway, modelID: currentID) }))
                    .tint(PlannerStyle.settingsControlTint)
                }
                Text(strings["Включите для модели, которая поддерживает вызов функций. Остальные модели доступны для диалога."])
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(service.generating || service.applying || service.gateways.busy.contains(gateway))
        }
    }
}
