import Foundation

struct ChatGPTHTTPError: LocalizedError {
    let status: Int
    let code: String?
    let parameter: String?

    var refreshRejected: Bool {
        status == 401 || ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                          "refresh_token_invalidated", "refresh_token_reused"].contains(code ?? "")
    }

    var errorDescription: String? {
        if status == 429 { return "Достигнут лимит ChatGPT. Проверьте использование в настройках ChatGPT." }
        if refreshRejected { return "Сессия ChatGPT закончилась. Войдите снова." }
        if code == "subscription_sharing_user_not_eligible" || status == 403 {
            return "Этот аккаунт не может использовать подписку ChatGPT в приложении."
        }
        if parameter == "reasoning" || parameter == "reasoning.effort" {
            return "Модель не приняла уровень рассуждения. Выберите «По умолчанию»."
        }
        if parameter == "model" || code == "model_not_found" {
            return "Модель недоступна. Обновите список моделей ChatGPT."
        }
        if status >= 500 { return "ChatGPT временно недоступен. Повторите запрос позже." }
        return "ChatGPT отклонил запрос. Проверьте подключение и повторите."
    }
}

struct ChatGPTTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenType: String
    let expiresIn: Double
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token"
        case tokenType = "token_type", expiresIn = "expires_in", scope
    }

    var allowsPlan: Bool? {
        scope.map { $0.split(whereSeparator: \.isWhitespace).contains(Substring(ChatGPTIdentity.planScope)) }
    }
}

struct ChatGPTModel: Decodable, Identifiable, Sendable {
    let slug: String
    let name: String
    let visibility: String?
    let efforts: [String]
    var id: String { slug }

    init(from decoder: Decoder) throws {
        enum Key: String, CodingKey {
            case slug, visibility, displayName = "display_name"
            case supportedEfforts = "supported_reasoning_efforts", camelEfforts = "supportedReasoningEfforts"
        }
        struct Effort: Decodable {
            let value: String
            init(from decoder: Decoder) throws {
                if let value = try? decoder.singleValueContainer().decode(String.self) {
                    self.value = value
                    return
                }
                enum Key: String, CodingKey { case camel = "reasoningEffort", snake = "reasoning_effort", effort }
                let values = try decoder.container(keyedBy: Key.self)
                value = try values.decodeIfPresent(String.self, forKey: .camel)
                    ?? values.decodeIfPresent(String.self, forKey: .snake)
                    ?? values.decode(String.self, forKey: .effort)
            }
        }
        let values = try decoder.container(keyedBy: Key.self)
        let slug = try values.decode(String.self, forKey: .slug)
        self.slug = slug
        name = try values.decodeIfPresent(String.self, forKey: .displayName) ?? slug
        visibility = try values.decodeIfPresent(String.self, forKey: .visibility)
        let advertised = (try? values.decode([Effort].self, forKey: .supportedEfforts))
            ?? (try? values.decode([Effort].self, forKey: .camelEfforts))
        let known = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        efforts = advertised.map { entries in known.filter(Set(entries.map(\.value)).contains) }
            ?? Self.standardEfforts(slug)
    }

    private static func standardEfforts(_ slug: String) -> [String] {
        // Каталог аккаунта может не содержать усилий. Не угадываем их у неизвестных моделей.
        let family = slug.replacingOccurrences(of: #"-[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, with: "", options: .regularExpression)
        let standard = ["low", "medium", "high"]
        switch family {
        case "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6.1-luna", "gpt-6-sol", "gpt-6-luna",
             "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini",
             "gpt-5.3-codex", "gpt-5.2", "gpt-5.2-codex", "o3", "o4-mini":
            return standard
        default:
            return []
        }
    }
}

/// Запросы используют только публичные конечные точки OpenAI и никогда не следуют перенаправлениям с учётными данными.
struct ChatGPTHTTP: Sendable {
    static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 240
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }

    func tokens(_ fields: [String: String]) async throws -> ChatGPTTokens {
        let data = try await form(URL(string: ChatGPTIdentity.issuer + "/api/accounts/oauth/token")!, fields: fields)
        let response = try JSONDecoder().decode(ChatGPTTokens.self, from: data)
        guard !response.accessToken.isEmpty, response.tokenType.lowercased() == "bearer",
              response.expiresIn.isFinite, response.expiresIn > 0 else {
            throw AssistantFailure(message: "Не удалось проверить ответ входа в ChatGPT.")
        }
        return response
    }

    func keys() async throws -> Data {
        try await load(URLRequest(url: URL(string: ChatGPTIdentity.issuer + "/.well-known/jwks.json")!))
    }

    func revoke(refreshToken: String, clientID: String) async throws {
        struct Discovery: Decodable { let revocation_endpoint: URL }
        let document = try await load(URLRequest(url: URL(string: ChatGPTIdentity.issuer + "/.well-known/openid-configuration")!))
        let url = try JSONDecoder().decode(Discovery.self, from: document).revocation_endpoint
        guard url.scheme == "https", url.host() == "auth.openai.com", url.user() == nil, url.password() == nil,
              url.port == nil || url.port == 443 else { throw AssistantFailure(message: "Не удалось подтвердить выход из ChatGPT.") }
        _ = try await form(url, fields: ["token": refreshToken, "token_type_hint": "refresh_token", "client_id": clientID])
    }

    func models(accessToken: String) async throws -> [ChatGPTModel] {
        struct Catalog: Decodable { let models: [ChatGPTModel] }
        let request = authenticatedRequest(path: "models", accessToken: accessToken)
        let data = try await load(request)
        var seen = Set<String>()
        return try JSONDecoder().decode(Catalog.self, from: data).models.filter {
            $0.visibility == "list" && !$0.slug.isEmpty && seen.insert($0.slug).inserted
        }
    }

    func respond(body: Data, accessToken: String, onText: @MainActor (String) -> Void) async throws -> AssistantCloudCompletion {
        var request = authenticatedRequest(path: "responses", accessToken: accessToken)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
                if errorBody.count == 32_768 { break }
            }
            throw Self.failure(status, data: errorBody)
        }

        var stream = AssistantCloudStream()
        var line = Data()
        for try await byte in bytes {
            if byte == 10 {
                try Task.checkCancellation()
                let event = try stream.consume(String(decoding: line, as: UTF8.self))
                if let delta = event.delta { await onText(delta) }
                if let reply = event.reply { return reply }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
                if line.count > 512_000 { throw AssistantCloudStream.invalid }
            }
        }
        throw AssistantCloudStream.incomplete
    }

    private func authenticatedRequest(path: String, accessToken: String) -> URLRequest {
        var request = URLRequest(url: URL(string: ChatGPTIdentity.resource + "/" + path)!)
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("Tasks", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func form(_ url: URL, fields: [String: String]) async throws -> Data {
        // application/x-www-form-urlencoded требует кодировать в том числе +, & и =.
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = fields.sorted(by: { $0.key < $1.key }).map { field in
            field.key + "=" + (field.value.addingPercentEncoding(withAllowedCharacters: safe) ?? "")
        }.joined(separator: "&")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return try await load(request)
    }

    private func load(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.failure(status, data: data) }
        return data
    }

    private static func failure(_ status: Int, data: Data) -> ChatGPTHTTPError {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = root?["error"] as? [String: Any]
        return .init(status: status, code: error?["code"] as? String ?? root?["error"] as? String,
                     parameter: error?["param"] as? String)
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
