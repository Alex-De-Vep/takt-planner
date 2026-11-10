import AppKit
import SwiftUI

struct AssistantGatewaySettings: View {
    @Environment(\.translations) private var strings
    @State private var address = ""
    @State private var base: URL?
    @State private var key = ""
    @State private var modelIDs = ""
    @State private var folderID = ""
    @State private var gigaScope: GigaChatScope = .personal
    @State private var copied = false
    @State private var editedModelID: String?
    @State private var editingConnection = false
    let service: AssistantService
    let gateway: AssistantGateway
    let russian: Bool

    private var connections: AssistantGatewayConnections { service.gateways }
    private var profile: AssistantGatewayProfile? { connections.profiles[gateway] }
    private var models: [AssistantGatewayModel] { connections.catalogs[gateway] ?? [] }
    private var busy: Bool { connections.busy.contains(gateway) }
    private var locked: Bool { busy || service.generating || service.applying }
    private var manualModels: [AssistantGatewayModel] { models.filter { $0.reportedTools == nil } }
    private var selectedBase: URL? {
        gateway == .liteLLM ? AssistantGatewayProfile.liteLLMBase(address) : base ?? gateway.bases.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let profile {
                Label(profile.account?.split(separator: "|").last.map(String.init) ?? strings["Подключено"],
                      systemImage: "checkmark.circle").foregroundStyle(.secondary)
                if gateway == .liteLLM || gateway.bases.count > 1 {
                    Text(profile.base.absoluteString).font(.caption).textSelection(.enabled)
                }
                if connections.catalogs[gateway] != nil {
                    Text(models.isEmpty ? strings["В каталоге нет текстовых моделей."]
                         : strings.format("Доступные модели: %d", models.count))
                        .foregroundStyle(.secondary)
                }
                if !editingConnection {
                    HStack {
                        if !gateway.configuredCatalog {
                            Button(strings["Обновить список моделей"]) { connections.refresh(gateway) }.disabled(locked)
                        }
                        if gateway != .openRouter {
                            Button(strings["Изменить…"]) {
                                resetForm(profile)
                                editingConnection = true
                            }.disabled(locked)
                        }
                        Spacer()
                        Button(strings["Отключить"], role: .destructive) {
                            connections.disconnect(gateway)
                            resetForm(nil)
                        }.disabled(locked)
                    }
                }
            }

            if gateway == .openRouter, profile == nil {
                Text(strings["Войдите в OpenRouter в браузере. Приложение сохранит ключ в Связке ключей."])
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(strings["Войти через OpenRouter"]) {
                    connections.signInOpenRouter(russian: russian)
                }.buttonStyle(.borderedProminent).disabled(locked)
            } else if gateway != .openRouter, profile == nil || editingConnection {
                keyForm
            } else if let profile, !manualModels.isEmpty {
                capabilities(profile)
            }
            if busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(strings[gateway == .openRouter && profile == nil
                        ? "Завершите вход в браузере" : "Проверяем подключение и каталог моделей…"])
                    Spacer()
                    Button(strings["Отмена"]) { connections.cancel(gateway) }
                }
            }
            if let error = connections.errors[gateway] {
                Text(strings[error]).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { resetForm(profile) }
        .onChange(of: busy) {
            if !busy, profile != nil, connections.errors[gateway] == nil {
                editingConnection = false
                key = ""
            }
        }
    }

    private var keyForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            if gateway == .liteLLM {
                TextField(strings["Адрес LiteLLM"], text: $address, prompt: Text("https://gateway.example.com/v1"))
                    .textContentType(.URL)
                if !address.isEmpty, selectedBase == nil {
                    Text(strings["Укажите HTTPS-адрес LiteLLM или HTTP-адрес на этом Mac."]).font(.caption).foregroundStyle(.secondary)
                }
            } else if gateway.bases.count > 1 {
                Picker(strings["Регион API"], selection: $base) {
                    ForEach(gateway.bases, id: \.self) { url in
                        Text(url.host() ?? url.absoluteString).tag(Optional(url))
                    }
                }
            }
            if gateway == .copilot { copilotSetup }
            if gateway == .gigaChat {
                Picker(strings["Версия GigaChat API"], selection: $gigaScope) {
                    ForEach(GigaChatScope.allCases) { scope in Text(strings[scope.label]).tag(scope) }
                }
            }
            SecureField(strings[keyLabel], text: $key)
            if gateway == .yandex {
                TextField(strings["ID каталога Yandex Cloud"], text: $folderID)
                Text(strings["Используйте ключ сервисного аккаунта с доступом к Yandex AI Studio."])
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if gateway.configuredCatalog {
                TextField(strings["Идентификаторы моделей"], text: $modelIDs)
            }
            if gateway.configuredCatalog {
                Text(strings[gateway == .yandex ? "Короткий запрос для проверки подключения может быть платным."
                            : "Через запятую. Проверка отправит каждой модели короткий запрос, который может быть платным."])
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(strings["Проверить и подключить"]) {
                    if let selectedBase {
                        connections.connect(gateway, base: selectedBase, key: key, modelIDs: modelIDs,
                                            folder: folderID, gigaScope: gigaScope)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(locked || selectedBase == nil || key.isEmpty || (gateway == .yandex ? folderID.isEmpty : gateway.configuredCatalog && modelIDs.isEmpty))
                if editingConnection {
                    Button(strings["Отмена"]) { editingConnection = false; key = "" }.disabled(busy)
                }
                Spacer()
                if let page = gateway.keyPage { Link(strings["Получить ключ"], destination: page) }
                if gateway == .gigaChat, let guide = URL(string: "https://developers.sber.ru/docs/ru/gigachat/api/reference/rest/gigachat-api") {
                    Link(strings["Инструкция"], destination: guide)
                }
            }
        }
        .disabled(busy)
    }

    private func resetForm(_ profile: AssistantGatewayProfile?) {
        address = profile?.base.absoluteString ?? ""
        base = profile?.base ?? gateway.bases.first
        key = ""
        folderID = profile?.folderID ?? ""
        gigaScope = profile?.gigaScope ?? .personal
        copied = false
        modelIDs = (profile?.configuredModelIDs ?? Array(gateway.suggestedIDs.prefix(1))).joined(separator: ", ")
    }

    private var keyLabel: String {
        switch gateway {
        case .liteLLM: "Виртуальный ключ LiteLLM"
        case .miniMaxPlan: "Ключ подписки M Plan"
        case .gigaChat: "Ключ авторизации GigaChat"
        case .copilot: "Код локального подключения"
        default: "Ключ API"
        }
    }

    private var copilotSetup: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(strings["Нужен Node.js 22.12 или новее. Выполните команду в Терминале, войдите в GitHub в браузере и вставьте полученный код. Оставьте Терминал открытым."])
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let url = Bundle.main.resourceURL?.appending(path: "CopilotBridge.bundle/start.sh"),
                   FileManager.default.fileExists(atPath: url.path) {
                    Button(strings[copied ? "Команда скопирована" : "Скопировать команду запуска"]) {
                        let path = url.path.replacingOccurrences(of: "'", with: "'\\''")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("/bin/bash '" + path + "'", forType: .string)
                        copied = true
                    }
                }
                Link("Node.js", destination: URL(string: "https://nodejs.org/")!)
            }
        }
    }

    private func capabilities(_ profile: AssistantGatewayProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            let currentID = manualModels.first(where: { $0.id == editedModelID })?.id ?? manualModels.first?.id
            Picker(strings["Модель"], selection: Binding(get: { currentID }, set: { editedModelID = $0 })) {
                ForEach(manualModels) { model in Text(model.name).tag(Optional(model.id)) }
            }
            if let currentID {
                Toggle(strings["Разрешить работу с задачами"], isOn: Binding(
                    get: { profile.toolModelIDs.contains(currentID) },
                    set: { connections.setTools($0, gateway: gateway, modelID: currentID) }
                ))
            }
            Text(strings["Включите для модели, которая поддерживает вызов функций. Остальные модели доступны для диалога."])
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.disabled(locked)
    }
}
