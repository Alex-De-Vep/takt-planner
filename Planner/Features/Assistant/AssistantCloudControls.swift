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
                Button(action: service.chooseLocalModel) {
                    Label(service.model.displayName + " · " + strings["На этом Mac"], systemImage: isCloud ? "desktopcomputer" : "checkmark")
                }
                Divider()
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
                Label(isCloud ? service.cloudModelName : service.model.displayName,
                      systemImage: isCloud ? "cloud" : "desktopcomputer")
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

/// Это окно открывается одинаково из чата и настроек.
struct AssistantModelConnections: View {
    @Environment(\.translations) private var strings
    @Environment(\.dismiss) private var dismiss
    @AppStorage("assistantChatGPTWelcomeSeen") private var welcomeSeen = false
    let service: AssistantService
    let russian: Bool
    var boundAccountID: String? = nil
    var selectModel: ((String) -> Void)? = nil

    @State private var gateway: AssistantGateway?
    private var cloud: AssistantCloudConnection { service.cloud }
    private var accountMismatch: Bool { boundAccountID.map { $0 != cloud.account?.id } ?? false }
    private var locked: Bool { cloud.busy || service.generating || service.applying }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(strings["Подключения моделей"]).font(.headline)
            Picker(strings["Подключения моделей"], selection: $gateway) {
                Text("ChatGPT").tag(nil as AssistantGateway?)
                ForEach(AssistantGateway.allCases) { gateway in
                    Text(gateway.name).tag(Optional(gateway))
                }
            }.pickerStyle(.menu)

            if let gateway {
                AssistantGatewaySettings(service: service, gateway: gateway, russian: russian).id(gateway)
            } else {
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
            gateway = service.current?.usesCloudModel == true ? service.current?.cloud?.gateway : nil
            cloud.activate()
            service.gateways.activate()
        }
    }

    private var chatGPTSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(cloud.account?.label ?? "ChatGPT", systemImage: "cloud").lineLimit(1)
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
            } else if cloud.busy {
                ProgressView().controlSize(.small)
            } else {
                Text(strings["Используется план ChatGPT"]).foregroundStyle(.secondary)
                if !cloud.models.isEmpty {
                    modelList
                } else {
                    Button(strings["Обновить список моделей"], action: cloud.refreshModels).disabled(locked)
                }
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

    private var modelList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(cloud.models) { model in
                    if let selectModel {
                        Button(model.name) {
                            selectModel(model.id)
                            dismiss()
                        }.disabled(locked)
                    } else {
                        Text(model.name)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: min(145, CGFloat(cloud.models.count) * 27))
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
                Button(strings["Обновить список моделей"], action: cloud.refreshModels)
                Button(strings["Выйти из ChatGPT"], role: .destructive, action: cloud.signOut)
            }
        } label: { Image(systemName: "person.crop.circle") }
        .menuStyle(.borderlessButton).fixedSize().disabled(locked)
        .accessibilityLabel(strings["Аккаунт ChatGPT"])
        .help(cloud.account?.label ?? strings["Аккаунт ChatGPT"])
    }
}
