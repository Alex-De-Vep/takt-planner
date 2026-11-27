import SwiftUI

/// Только аккаунты, ключи и адреса провайдеров. Выбор моделей находится в настройках помощника.
struct AssistantProviderSettings: View {
    @Environment(\.translations) private var strings
    @AppStorage("assistantChatGPTWelcomeSeen") private var welcomeSeen = false
    let service: AssistantService
    let russian: Bool
    var boundAccountID: String? = nil
    let provider: AssistantProviderOption
    private var cloud: AssistantCloudConnection { service.cloud }
    private var accountMismatch: Bool { boundAccountID.map { $0 != cloud.account?.id } ?? false }
    private var locked: Bool { cloud.busy || service.generating || service.applying || service.storageFailed }

    var body: some View {
        Section {
            if let gateway = provider.gateway {
                AssistantGatewaySettings(service: service, gateway: gateway, russian: russian)
                    .id(gateway)
                AssistantGatewayModelCapabilities(service: service, gateway: gateway)
            } else { chatGPTSettings }
        } header: {
            Text(provider.name)
        }
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


struct AssistantProviderOption: Identifiable, Equatable {
    let gateway: AssistantGateway?
    var id: String { AssistantModelVisibility.source(gateway) }
    var name: String { gateway?.name ?? "ChatGPT" }
    static let all = [Self(gateway: nil)] + AssistantGateway.allCases.map { Self(gateway: $0) }

    @MainActor func isConnected(to service: AssistantService) -> Bool {
        if let gateway { return service.gateways.profiles[gateway] != nil }
        return service.cloud.isConnected
    }
}

enum AssistantProviderSheetRoute: Identifiable {
    case choose
    case manage(AssistantProviderOption)
    var id: String {
        switch self {
        case .choose: "choose"
        case .manage(let provider): provider.id
        }
    }
}

struct AssistantProvidersSheet: View {
    @Environment(\.translations) private var strings
    @Environment(\.dismiss) private var dismiss
    let service: AssistantService
    let preferences: AppPreferences
    let route: AssistantProviderSheetRoute
    @State private var chosen: AssistantProviderOption?

    private var available: [AssistantProviderOption] {
        AssistantProviderOption.all.filter { !$0.isConnected(to: service) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let chosen {
                Form {
                    AssistantProviderSettings(service: service, russian: preferences.language.resolvedCode == "ru",
                        boundAccountID: service.chatGPTAccountID, provider: chosen)
                }.formStyle(.grouped)
            } else {
                Text(strings["Подключить ИИ-провайдер"]).font(.headline).padding(.top, 20).padding(.horizontal, 20)
                List(available) { provider in
                    Button {
                        chosen = provider
                    } label: {
                        HStack {
                            Text(provider.name)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .overlay {
                    if available.isEmpty { Text(strings["Все провайдеры подключены"]).foregroundStyle(.secondary) }
                }
            }
            HStack {
                if case .choose = route, chosen != nil {
                    Button(strings["Назад"]) { chosen = nil }
                }
                Spacer()
                Button(strings["Готово"]) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: 510, height: 490)
        .onAppear {
            if case .manage(let provider) = route { chosen = provider }
        }
        .onChange(of: chosen?.isConnected(to: service) == true) { _, connected in
            if connected, case .choose = route {
                dismiss()
            }
        }
    }
}
