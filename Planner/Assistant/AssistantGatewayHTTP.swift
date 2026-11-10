import Foundation

struct AssistantGatewayProfile: Codable, Sendable {
    let id: UUID
    let gateway: AssistantGateway
    let base: URL
    let key: String
    var toolModelIDs: Set<String> = []
    var configuredModelIDs: [String]?
    var account: String?
    var folderID: String?
    var gigaScope: GigaChatScope?

    static let openRouterBase = URL(string: "https://openrouter.ai/api/v1")!

    /// Виртуальный ключ может идти по HTTP только на этот Mac.
    static func liteLLMBase(_ address: String) -> URL? {
        guard var url = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme?.lowercased() == "https" ||
                (url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)),
              url.port.map({ (1...65535).contains($0) }) != false else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        url.path = path.isEmpty ? "/v1" : "/" + path + (path.split(separator: "/").last == "v1" ? "" : "/v1")
        return url.url
    }
}

struct AssistantGatewayModel: Identifiable, Sendable {
    let id: String
    let name: String
    // nil означает, что каталог не сообщил о поддержке инструментов.
    let reportedTools: Bool?
    var efforts: [String] = []

    func supportsTools(in profile: AssistantGatewayProfile) -> Bool {
        reportedTools ?? profile.toolModelIDs.contains(id)
    }
}

struct AssistantGatewayHTTP: Sendable {
    private let session: URLSession
    private let gigaTokens = GigaChatTokenCache()

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 180
        session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
    }

    func openRouterKey(code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: AssistantGatewayProfile.openRouterBase.appending(path: "auth/keys"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code, "code_verifier": verifier, "code_challenge_method": "S256"
        ])
        let response = try await get(Key.self, request: request)
        guard Self.validKey(response.key) else { throw Self.invalid }
        return response.key
    }

    func remainingKeyBudget(_ profile: AssistantGatewayProfile) async throws -> Double? {
        let remaining: Double?
        switch profile.gateway {
        case .openRouter:
            remaining = try await get(OpenRouterKeyInfo.self, request: request(profile, "key")).data.limit_remaining
        case .liteLLM:
            // LiteLLM ищет текущий ключ по заголовку Authorization. Секрет в URL не передаём.
            let url = profile.base.deletingLastPathComponent().appending(path: "key/info")
            let info = try await get(LiteLLMKeyInfo.self, request: request(profile, url: url)).info
            if let limit = info.max_budget, let spend = info.spend { remaining = limit - spend }
            else { remaining = nil }
        default: return nil
        }
        return remaining.flatMap { $0.isFinite ? max(0, $0) : nil }
    }

    func models(_ profile: AssistantGatewayProfile) async throws -> [AssistantGatewayModel] {
        let gateway = profile.gateway
        if gateway.configuredCatalog {
            return (profile.configuredModelIDs ?? []).map {
                .init(id: $0, name: gateway == .yandex ? gateway.name : $0, reportedTools: gateway.documentedTools($0),
                      efforts: gateway.isMiniMax && $0 == "MiniMax-M3.1-Flash" ? ["low", "medium", "high", "xhigh", "max"] : [])
            }
        }
        if gateway == .gemini {
            let base = profile.base.deletingLastPathComponent()
            var components = URLComponents(url: base.appending(path: "models"), resolvingAgainstBaseURL: false)!
            var result: [AssistantGatewayModel] = []
            var next: String?
            var pages = Set<String>()
            repeat {
                components.queryItems = [.init(name: "pageSize", value: "1000")]
                if let next { components.queryItems?.append(.init(name: "pageToken", value: next)) }
                guard let url = components.url else { throw Self.invalid }
                var request = URLRequest(url: url)
                request.setValue(profile.key, forHTTPHeaderField: "x-goog-api-key")
                let page = try await get(GeminiCatalog.self, request: request)
                result += page.chatModels
                next = page.nextPageToken
            } while next.map({ pages.count < 15 && pages.insert($0).inserted }) == true
            var seen = Set<String>()
            return result.filter { seen.insert($0.id).inserted }
        }
        let endpoint = gateway == .grok ? "language-models" : "models"
        var catalogRequest = try await authorizedRequest(profile, endpoint)
        if gateway == .claude, var url = URLComponents(url: catalogRequest.url!, resolvingAgainstBaseURL: false) {
            url.queryItems = [.init(name: "limit", value: "1000")]
            catalogRequest.url = url.url
        }
        return try await get(Catalog.self, request: catalogRequest).models(for: gateway)
    }

    func copilotAccount(_ profile: AssistantGatewayProfile) async throws -> String {
        let catalog = try await get(Catalog.self, request: request(profile, "models"))
        guard let account = catalog.account, Self.validKey(account), account.contains("|"),
              profile.account == nil || profile.account == account else { throw Self.invalid }
        return account
    }

    func remainingCopilotPercent(_ profile: AssistantGatewayProfile) async throws -> Double? {
        guard profile.account != nil else { return nil }
        let quota = try await get(CopilotQuota.self, request: request(profile, "quota")).remaining
        return quota.flatMap { (0...100).contains($0) ? $0 : nil }
    }

    func remainingMiniMaxPercent(_ profile: AssistantGatewayProfile, modelID: String) async throws -> Double? {
        let url = URL(string: "https://www.minimax.io/v1/token_plan/remains")!
        var request = URLRequest(url: url)
        request.setValue("Bearer " + profile.key, forHTTPHeaderField: "Authorization")
        let quota = try await get(MiniMaxQuota.self, request: request)
        guard quota.base_resp?.status_code ?? 0 == 0 else { return nil }
        let percent = quota.model_remains?.first { $0.model_name == modelID }?.current_interval_remaining_percent
        return percent.flatMap { (0...100).contains($0) ? $0 : nil }
    }

    /// Синтетическая короткая проверка только после явного нажатия пользователем.
    func verifyConfiguredModels(_ profile: AssistantGatewayProfile) async throws {
        guard profile.gateway.configuredCatalog, let ids = profile.configuredModelIDs, !ids.isEmpty else { return }
        for id in ids {
            var request = request(profile, profile.gateway.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var payload: [String: Any] = [
                "model": id, "messages": [["role": "user", "content": "Reply OK."]],
                "stream": false, "max_tokens": 64
            ]
            if profile.gateway == .qwen { payload["enable_thinking"] = false }
            if profile.gateway.isMiniMax, id == "MiniMax-M3.1-Flash" {
                payload["thinking"] = ["type": "adaptive"]
                payload["output_config"] = ["effort": "low"]
            }
            if profile.gateway == .glm { payload["thinking"] = ["type": "disabled"] }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let response = try await get(Probe.self, request: request)
            guard profile.gateway.wire == .messages ? response.content?.isEmpty == false : response.choices?.isEmpty == false else {
                throw Self.invalid
            }
        }
    }

    func reply(_ body: Data, profile: AssistantGatewayProfile, tools: Bool,
               preview: @escaping @MainActor @Sendable (String) -> Void) async throws -> AssistantCloudCompletion {
        var request = try await authorizedRequest(profile, profile.gateway.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let (bytes, response) = try await session.bytes(for: request)
        try Self.check(response)
        guard response.mimeType == "text/event-stream" else { throw Self.invalid }
        var stream = AssistantGatewayStream(tools: tools, legacyFunctions: profile.gateway == .gigaChat,
                                            objectArguments: profile.gateway == .glm)
        var responses = AssistantCloudStream(supportsTools: tools)
        var messages = AssistantMessagesStream(tools: tools)
        var line: [UInt8] = []
        for try await byte in bytes {
            if byte == 10 {
                let value = String(decoding: line, as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                let part: (delta: String?, reply: AssistantCloudCompletion?)
                switch profile.gateway.wire {
                case .responses: part = try responses.consume(value)
                case .messages: part = try messages.consume(value)
                case .chat:
                    let chat = try stream.consume(value)
                    part = (chat.delta, chat.reply.map { .init(response: $0, usage: .init(tokens: stream.tokens)) })
                }
                if let delta = part.delta { await preview(delta) }
                if let result = part.reply {
                    return .init(response: result.response, usage: .init(tokens: result.usage.tokens, gatewayProfileID: profile.id))
                }
            } else {
                guard line.count < 512_000 else { throw Self.invalid }
                line.append(byte)
            }
        }
        throw AssistantCloudStream.incomplete
    }

    private func authorizedRequest(_ profile: AssistantGatewayProfile, _ endpoint: String) async throws -> URLRequest {
        var request = request(profile, endpoint)
        if profile.gateway == .gigaChat {
            let token = try await gigaTokens.token(for: profile, transport: self)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    fileprivate func exchangeGigaKey(_ profile: AssistantGatewayProfile) async throws -> GigaChatAccess {
        var request = URLRequest(url: URL(string: "https://ngw.devices.sberbank.ru:9443/api/v2/oauth")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "RqUID")
        request.setValue("Basic " + profile.key, forHTTPHeaderField: "Authorization")
        request.httpBody = Data(("scope=" + (profile.gigaScope ?? .personal).rawValue).utf8)
        do {
            return try await get(GigaChatAccess.self, request: request)
        } catch let error as URLError where [
            .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .secureConnectionFailed
        ].contains(error.code) {
            throw AssistantFailure(message: "macOS не доверяет сертификату GigaChat. Проверьте сертификаты по инструкции Сбера.")
        }
    }

    private func request(_ profile: AssistantGatewayProfile, _ endpoint: String) -> URLRequest {
        request(profile, url: profile.base.appending(path: endpoint))
    }

    private func request(_ profile: AssistantGatewayProfile, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if profile.gateway.wire == .messages {
            request.setValue(profile.key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if profile.gateway != .gigaChat {
            request.setValue("Bearer " + profile.key, forHTTPHeaderField: "Authorization")
        }
        if profile.gateway == .copilot { request.setValue(profile.account, forHTTPHeaderField: "X-Tasks-Account") }
        if profile.gateway == .yandex { request.setValue(profile.folderID, forHTTPHeaderField: "OpenAI-Project") }
        return request
    }

    private func get<Value: Decodable>(_ type: Value.Type, request: URLRequest) async throws -> Value {
        let (bytes, response) = try await session.bytes(for: request)
        try Self.check(response)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 12_000_000 else { throw Self.invalid }
            data.append(byte)
        }
        guard let value = try? JSONDecoder().decode(type, from: data) else { throw Self.invalid }
        return value
    }

    static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 8192 && key.utf8.allSatisfy { (33...126).contains($0) }
    }

    private static func check(_ response: URLResponse) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw invalid }
        switch status {
        case 200...299: return
        case 401: throw AssistantFailure(message: "Сервис отклонил ключ. Подключите его заново.")
        case 403: throw AssistantFailure(message: "У ключа нет доступа к этому ресурсу.")
        case 402: throw AssistantFailure(message: "Недостаточно средств или исчерпан бюджет подключения.")
        case 429: throw AssistantFailure(message: "Сервис ограничил число запросов. Повторите позже.")
        default: throw invalid
        }
    }

    static let invalid = AssistantFailure(message: "Не удалось получить ответ от подключения моделей.")

    private struct Probe: Decodable {
        struct Item: Decodable {}
        let choices: [Item]?
        let content: [Item]?
    }

    private struct MiniMaxQuota: Decodable {
        struct Status: Decodable { let status_code: Int? }
        struct Entry: Decodable {
            let model_name: String?
            let current_interval_remaining_percent: Double?
        }
        let base_resp: Status?
        let model_remains: [Entry]?
    }
    private struct CopilotQuota: Decodable { let remaining: Double? }
    private struct Key: Decodable { let key: String }
    private struct OpenRouterKeyInfo: Decodable {
        struct Info: Decodable { let limit_remaining: Double? }
        let data: Info
    }
    private struct LiteLLMKeyInfo: Decodable {
        struct Info: Decodable {
            let max_budget: Double?
            let spend: Double?
        }
        let info: Info
    }

    struct GeminiCatalog: Decodable {
        struct Item: Decodable {
            let name: String
            let displayName: String?
            let supportedGenerationMethods: [String]
        }
        let models: [Item]?
        let nextPageToken: String?

        var chatModels: [AssistantGatewayModel] {
            (models ?? []).compactMap { item in
                guard item.name.hasPrefix("models/"), item.supportedGenerationMethods.contains("generateContent") else { return nil }
                let id = String(item.name.dropFirst(7))
                let excluded = ["image", "tts", "live", "audio", "robotics", "computer-use", "deep-research"]
                guard id.hasPrefix("gemini-"), !excluded.contains(where: { id.contains($0) }) else { return nil }
                return .init(id: id, name: item.displayName ?? id, reportedTools: AssistantGateway.gemini.documentedTools(id))
            }
        }
    }

    struct Catalog: Decodable {
        struct Item: Decodable {
            struct Architecture: Decodable {
                let input_modalities: [String]?
                let output_modalities: [String]?
            }
            struct Capabilities: Decodable {
                let completion_chat: Bool?
                let function_calling: Bool?
            }
            struct Effort: Decodable { let supported_levels: [String]? }
            let id: String
            let name: String?
            let display_name: String?
            let supported_parameters: [String]?
            let architecture: Architecture?
            let capabilities: Capabilities?
            let input_modalities: [String]?
            let output_modalities: [String]?
            let effort: Effort?
            let aliases: [String]?
        }
        let data: [Item]
        let account: String?

        private enum CodingKeys: String, CodingKey { case data, models, account }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // xAI публикует языковые модели в models; остальные совместимые каталоги используют data.
            data = try values.decodeIfPresent([Item].self, forKey: .data) ?? values.decode([Item].self, forKey: .models)
            account = try values.decodeIfPresent(String.self, forKey: .account)
        }

        func models(for gateway: AssistantGateway) -> [AssistantGatewayModel] {
            var seen = Set<String>()
            return data.compactMap { item -> AssistantGatewayModel? in
                guard !item.id.isEmpty, item.id.utf8.count <= 512,
                      (item.architecture?.input_modalities ?? item.input_modalities)?.contains("text") != false,
                      (item.architecture?.output_modalities ?? item.output_modalities)?.contains("text") != false,
                      item.capabilities?.completion_chat != false, seen.insert(item.id).inserted else { return nil }
                let tools = item.capabilities?.function_calling ?? item.supported_parameters?.contains("tools")
                    ?? (gateway == .openRouter ? false : gateway.documentedTools(item.id))
                let effort = [.deepSeek, .copilot].contains(gateway) ? item.effort?.supported_levels ?? [] : []
                return .init(id: item.id, name: (item.display_name ?? item.name ?? item.aliases?.first).flatMap { $0.isEmpty ? nil : String($0.prefix(160)) } ?? item.id,
                             reportedTools: tools, efforts: effort.filter { ["low", "medium", "high", "xhigh", "max"].contains($0) })
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}


fileprivate struct GigaChatAccess: Decodable, Sendable {
    let access_token: String
    let expires_at: Double

    var expires: Date {
        Date(timeIntervalSince1970: expires_at >= 100_000_000_000 ? expires_at / 1000 : expires_at)
    }
}

/// Временный токен держим только в памяти и обновляем заранее.
private actor GigaChatTokenCache {
    private var cached: (id: UUID, access: GigaChatAccess)?
    private var pending: (id: UUID, task: Task<GigaChatAccess, Error>)?

    func token(for profile: AssistantGatewayProfile, transport: AssistantGatewayHTTP) async throws -> String {
        if let cached, cached.id == profile.id, cached.access.expires.timeIntervalSinceNow > 60 {
            return cached.access.access_token
        }
        if let pending, pending.id == profile.id { return try await pending.task.value.access_token }
        let task = Task {
            let access = try await transport.exchangeGigaKey(profile)
            guard AssistantGatewayHTTP.validKey(access.access_token), access.expires.timeIntervalSinceNow > 0 else {
                throw AssistantGatewayHTTP.invalid
            }
            return access
        }
        pending = (profile.id, task)
        do {
            let access = try await task.value
            if pending?.id == profile.id {
                cached = (profile.id, access)
                pending = nil
            }
            return access.access_token
        } catch {
            if pending?.id == profile.id { pending = nil }
            throw error
        }
    }
}
