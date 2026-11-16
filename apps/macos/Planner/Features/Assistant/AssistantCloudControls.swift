import SwiftUI

/// Один список моделей в чате, с настройками подключения отдельно от отправки сообщения.
struct AssistantModelPicker: View {
    @Environment(\.translations) private var strings
    let service: AssistantService
    let openConnections: () -> Void

    private var isCloud: Bool { service.current?.usesCloudModel == true }
    private var cloudReady: Bool { service.cloud.canSend(to: service.chatGPTAccountID) }
    private var locked: Bool { service.generating || service.applying || service.storageFailed }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                if cloudReady {
                    ForEach(service.cloud.models) { model in
                        Button { service.selectCloudModel(model.id) } label: {
                            Label(model.name, systemImage: service.cloudModel?.id == model.id ? "checkmark" : "cloud")
                        }
                    }
                    Divider()
                }
                ForEach(AssistantGateway.allCases) { gateway in
                    if let models = service.gateways.catalogs[gateway], !models.isEmpty {
                        Menu(gateway.name) {
                            if gateway == .openRouter, models.count > 40 {
                                let groups = Dictionary(grouping: models) { $0.id.split(separator: "/").first.map(String.init) ?? gateway.name }
                                ForEach(groups.keys.sorted(), id: \.self) { group in
                                    Menu(group) { gatewayRows(groups[group] ?? [], gateway: gateway) }
                                }
                            } else {
                                gatewayRows(models, gateway: gateway)
                            }
                        }.disabled(service.gateways.busy.contains(gateway))
                    }
                }
                Divider()
                Button(action: openConnections) {
                    Label(strings["Подключения моделей…"], systemImage: "person.crop.circle")
                }
            } label: {
                Label(isCloud ? service.cloudModelName : strings["Выбрать модель чата"], systemImage: "cloud")
                    .lineLimit(1).frame(maxWidth: 154, alignment: .leading)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(strings["Выбрать модель"])
            .accessibilityLabel(strings["Выбрать модель"])
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

    private func gatewayRows(_ models: [AssistantGatewayModel], gateway: AssistantGateway) -> some View {
        ForEach(models) { model in
            Button {
                service.selectGatewayModel(model.id, gateway: gateway)
            } label: {
                if service.gatewayProfile?.gateway == gateway && service.gatewayModel?.id == model.id {
                    Label(model.name, systemImage: "checkmark")
                } else {
                    Text(model.name)
                }
            }
        }
    }

    private func effortLabel(_ effort: String) -> String {
        let labels = ["none": "Без рассуждения", "minimal": "Минимальная", "low": "Низкая", "medium": "Средняя",
                      "high": "Высокая", "xhigh": "Очень высокая", "max": "Максимальная"]
        return strings[labels[effort] ?? effort]
    }
}

struct AssistantSettingsModelPicker: View {
    @Environment(\.translations) private var strings
    let models: [(id: String, name: String)]
    let selectedID: String?
    var emptyLabel = "Выбрать модель"
    var refresh: (() -> Void)?
    var refreshing = false
    let select: (String) -> Void

    var body: some View {
        let title = models.first { $0.id == selectedID }?.name ?? strings[emptyLabel]
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(strings["Модель"]) {
                Menu {
                    ForEach(models, id: \.id) { model in
                        Button {
                            select(model.id)
                        } label: {
                            if model.id == selectedID { Label(model.name, systemImage: "checkmark") }
                            else { Text(model.name) }
                        }
                    }
                } label: {
                    Text(title).lineLimit(1)
                }
                .menuStyle(.borderedButton)
                .frame(width: 240, alignment: .leading)
                .help(title)
                .accessibilityLabel(strings["Модель"])
                .accessibilityValue(title)
                .accessibilityIdentifier("assistant-settings-model-picker")
                .disabled(models.isEmpty || refreshing)
            }
            if let refresh {
                HStack(spacing: 8) {
                    Button(strings["Обновить список моделей"], action: refresh)
                        .accessibilityIdentifier("assistant-refresh-models")
                    if refreshing { ProgressView().controlSize(.small) }
                }
                .disabled(refreshing)
            }
        }
    }
}

enum AssistantModelPurpose: String, Identifiable {
    case chat, transcription
    var id: Self { self }
}

/// Это окно открывается одинаково из чата и настроек.
struct AssistantModelConnections: View {
    @Environment(\.translations) private var strings
    @Environment(\.dismiss) private var dismiss
    @AppStorage("assistantChatGPTWelcomeSeen") private var welcomeSeen = false
    let service: AssistantService
    let russian: Bool
    var boundAccountID: String? = nil
    let preferences: AppPreferences
    var purpose: AssistantModelPurpose = .chat
    var dismissOnChatSelection = false

    @State private var gateway: AssistantGateway?
    private var cloud: AssistantCloudConnection { service.cloud }
    private var accountMismatch: Bool { boundAccountID.map { $0 != cloud.account?.id } ?? false }
    private var locked: Bool { cloud.busy || service.generating || service.applying || service.storageFailed }
    private var isTranscription: Bool { purpose == .transcription }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(strings[isTranscription ? "Выберите модель для расшифровки" : "Модели для чата"]).font(.headline)
            LabeledContent(strings["Подключение"]) {
                Picker(strings["Подключение"], selection: $gateway) {
                    if !isTranscription { Text("ChatGPT").tag(nil as AssistantGateway?) }
                    ForEach(isTranscription ? AssistantGateway.transcriptionProviders
                            : AssistantGateway.allCases.filter { $0 != .openAI }) { gateway in
                        Text(gateway.name).tag(Optional(gateway))
                    }
                }
                .labelsHidden().pickerStyle(.menu)
                .frame(width: 240, alignment: .leading)
                .accessibilityIdentifier("assistant-settings-provider-picker")
            }

            if let gateway {
                if let profile = service.gateways.profiles[gateway] {
                    if isTranscription {
                        AssistantTranscriptionSettings(profile: profile, http: service.gateways.http, preferences: preferences)
                            .id(profile.id)
                    } else {
                        let models = service.gateways.catalogs[gateway] ?? []
                        let busy = service.gateways.busy.contains(gateway)
                        modelPicker(models.map { ($0.id, $0.name) }, gateway: gateway,
                                    selectedID: service.gatewayProfile?.gateway == gateway ? service.gatewayModel?.id : nil,
                                    refresh: gateway.configuredCatalog ? nil : { service.gateways.refresh(gateway) },
                                    refreshing: busy)
                            .disabled(locked)
                    }
                    Divider()
                }
                gatewaySettings(gateway)
            } else if !isTranscription {
                if cloud.isConnected, !accountMismatch {
                    modelPicker(cloud.models.map { ($0.id, $0.name) }, gateway: nil,
                                selectedID: service.gatewayProfile == nil ? service.cloudModel?.id : nil,
                                refresh: cloud.refreshModels, refreshing: cloud.busy)
                        .disabled(locked)
                    Divider()
                }
                chatGPTSettings
            }
            HStack {
                Spacer()
                Button(strings["Готово"]) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            service.gateways.activate()
            if isTranscription {
                gateway = preferences.transcriptionModel?.profile(in: service.gateways)?.gateway
                    ?? AssistantGateway.transcriptionProviders.first { service.gateways.profiles[$0] != nil }
                    ?? .gigaChat
            } else {
                gateway = service.current?.usesCloudModel == true ? service.current?.cloud?.gateway : nil
                cloud.activate()
            }
        }
    }

    private func gatewaySettings(_ gateway: AssistantGateway) -> some View {
        AssistantGatewaySettings(service: service, gateway: gateway, russian: russian, isTranscription: isTranscription)
            .id(gateway)
    }

    private var chatGPTSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                let connected = cloud.isConnected && !accountMismatch
                Label(cloud.account?.label ?? "ChatGPT", systemImage: connected ? "checkmark.circle" : "cloud")
                    .foregroundStyle(connected ? Color.green : Color.primary)
                    .lineLimit(1)
                Spacer()
                if cloud.isConnected { Link(strings["Лимиты"], destination: ChatGPTHTTP.usageURL) }
                accountMenu
            }
            if cloud.signingIn {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(strings["Завершите вход в браузере"])
                    Spacer()
                    Button(strings["Отмена"], action: cloud.cancelSignIn)
                }
            } else if accountMismatch {
                Text(strings["Этот диалог привязан к другому аккаунту ChatGPT."]).foregroundStyle(.secondary)
                if let boundAccountID {
                    Button(strings["Подключить аккаунт диалога"]) { cloud.selectAccount(boundAccountID, russian: russian) }
                        .disabled(locked)
                }
            } else if !cloud.isConnected {
                Text(strings["Войдите, чтобы использовать план ChatGPT"]).foregroundStyle(.secondary)
                Button {
                    cloud.signIn(clientID: cloud.account?.id, russian: russian)
                } label: {
                    Label {
                        Text(strings["Продолжить с ChatGPT"])
                    } icon: {
                        Image("ChatGPTLogo").resizable().scaledToFit().frame(width: 15, height: 15)
                    }.foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent).tint(.black).disabled(locked)
                .accessibilityIdentifier("assistant-connect-chatgpt")
            } else {
                Text(strings["Используется план ChatGPT"]).foregroundStyle(.secondary)
            }
            if cloud.isConnected, !welcomeSeen, !accountMismatch {
                HStack(alignment: .top, spacing: 10) {
                    Text(strings["Облачные ответы используют ваш план ChatGPT. Использование можно посмотреть в настройках ChatGPT."])
                        .fixedSize(horizontal: false, vertical: true)
                    Button(strings["Понятно"]) { welcomeSeen = true }
                }.padding(8).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
            if let error = cloud.error {
                Text(strings[error]).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    private func modelPicker(_ models: [(id: String, name: String)], gateway: AssistantGateway?, selectedID: String?,
                             refresh: (() -> Void)?, refreshing: Bool) -> some View {
        AssistantSettingsModelPicker(models: models, selectedID: selectedID,
                                     emptyLabel: models.isEmpty ? "Нет доступных моделей" : "Выбрать модель",
                                     refresh: refresh, refreshing: refreshing) { id in
            if let gateway { service.selectGatewayModel(id, gateway: gateway) }
            else { service.selectCloudModel(id) }
            if dismissOnChatSelection { dismiss() }
        }
    }

    private var accountMenu: some View {
        Menu {
            ForEach(cloud.vault.accounts) { account in
                Button {
                    cloud.selectAccount(account.id, russian: russian)
                } label: {
                    if account.id == cloud.account?.id { Label(account.label, systemImage: "checkmark") }
                    else { Text(account.label) }
                }
            }
            if !cloud.vault.accounts.isEmpty { Divider() }
            Button(strings["Добавить аккаунт ChatGPT"]) { cloud.signIn(russian: russian) }
            if cloud.isConnected {
                Button(strings["Выйти из ChatGPT"], role: .destructive, action: cloud.signOut)
            }
        } label: { Image(systemName: "person.crop.circle") }
        .menuStyle(.borderlessButton).fixedSize().disabled(locked)
        .accessibilityLabel(strings["Аккаунт ChatGPT"])
        .help(cloud.account?.label ?? strings["Аккаунт ChatGPT"])
    }
}
