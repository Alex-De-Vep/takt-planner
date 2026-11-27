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
    private let gigaChatSession: URLSession
    private let gigaChatDelegate: AssistantGatewaySessionDelegate
    private let gigaTokens = GigaChatTokenCache()

    init(configuration config: URLSessionConfiguration = .ephemeral) {
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 180
        session = URLSession(configuration: config, delegate: AssistantGatewaySessionDelegate(), delegateQueue: nil)
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        let delegate = AssistantGatewaySessionDelegate(gigaChatAnchor: GigaChatTrust.bundledAnchor)
        gigaChatDelegate = delegate
        gigaChatSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
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
        if gateway == .openAI {
            _ = try await transcriptionModels(profile)
            return []
        }
        if gateway.configuredCatalog {
            return (profile.configuredModelIDs ?? []).map {
                .init(id: $0, name: gateway == .yandex ? gateway.name : $0, reportedTools: gateway.documentedTools($0),
                      efforts: gateway.isMiniMax && $0 == "MiniMax-M3.1-Flash" ? ["low", "medium", "high", "xhigh", "max"] : [])
            }
        }
        if gateway == .gemini { return try await geminiModels(profile) }
        let endpoint = gateway == .grok ? "language-models" : "models"
        var catalogRequest = try await authorizedRequest(profile, endpoint)
        if gateway == .claude, var url = URLComponents(url: catalogRequest.url!, resolvingAgainstBaseURL: false) {
            url.queryItems = [.init(name: "limit", value: "1000")]
            catalogRequest.url = url.url
        }
        return try await get(Catalog.self, request: catalogRequest, gigaChat: gateway == .gigaChat).models(for: gateway)
    }

    private func geminiModels(_ profile: AssistantGatewayProfile) async throws -> [AssistantGatewayModel] {
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

    func transcriptionModels(_ profile: AssistantGatewayProfile) async throws -> [AssistantTranscriptionModel] {
        guard profile.gateway.permits(profile.base) else { throw Self.invalid }
        switch profile.gateway {
        case .openRouter:
            var address = URLComponents(url: profile.base.appending(path: "models"), resolvingAgainstBaseURL: false)!
            address.queryItems = [.init(name: "output_modalities", value: "transcription")]
            let catalog = try await get(Catalog.self, request: request(profile, url: address.url!))
            return catalog.data.map { AssistantTranscriptionModel(id: $0.id, name: $0.name ?? $0.id) }
        case .liteLLM:
            let url = profile.base.deletingLastPathComponent().appending(path: "model/info")
            let catalog = try await get(TranscriptionProxyCatalog.self, request: request(profile, url: url))
            return catalog.data.compactMap { item in
                guard item.model_info?.mode == "audio_transcription" else { return nil }
                return AssistantTranscriptionModel(id: item.model_name, name: item.model_name)
            }
        case .gigaChat, .openAI:
            let request = try await authorizedRequest(profile, "models")
            let catalog = try await get(Catalog.self, request: request, gigaChat: profile.gateway == .gigaChat)
            return catalog.data.compactMap { item in
                let accepted = profile.gateway == .openAI
                    ? Self.openAISpeechModels.contains(item.id)
                    : (item.input_modalities ?? item.architecture?.input_modalities)?.contains("audio")
                        ?? Self.gigaAudioModels.contains(item.id.lowercased())
                guard accepted else { return nil }
                return .init(id: item.id, name: item.display_name ?? item.name ?? item.id)
            }
        case .gemini:
            return try await geminiModels(profile).filter { Self.geminiAudioModels.contains($0.id) }
                .map { .init(id: $0.id, name: $0.name) }
        case .mistral:
            return [.init(id: "voxtral-mini-transcribe-3", name: "Voxtral Mini Transcribe 3"),
                    .init(id: "voxtral-small-transcribe-3", name: "Voxtral Small Transcribe 3")]
        case .grok:
            return [.init(id: "grok-voice-transcribe-2.0", name: "Grok Voice Transcribe 2.0")]
        default:
            return []
        }
    }

    private static let openAISpeechModels: Set<String> = [
        "gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "gpt-4o-mini-transcribe-2025-12-15",
        "gpt-4o-transcribe-diarize", "whisper-1"
    ]
    private static let gigaAudioModels: Set<String> = [
        "gigachat", "gigachat-pro", "gigachat-max", "gigachat-2", "gigachat-2-lite", "gigachat-2-pro",
        "gigachat-2-max", "gigachat-3-ultra"
    ]
    private static let geminiAudioModels: Set<String> = [
        "gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.5-pro", "gemini-3-flash-preview",
        "gemini-3.1-flash-lite", "gemini-3.5-flash", "gemini-3.5-flash-lite", "gemini-3.8-flash",
        "gemini-3.5-transcribe"
    ]
    private static let transcriptPrompt = """
        Transcribe the spoken words faithfully in their original languages. Return only the transcript.
        Preserve the order of speech. Do not summarize, translate, or invent unclear words.
        If there is no intelligible speech, return exactly [NO_SPEECH].
        """

    struct AudioFailure: Error, Sendable {
        enum Stage: String, Sendable {
            case upload = "Загрузка записи"
            case recognition = "Распознавание речи"
        }

        enum Cause: Sendable {
            case http(Int), network(URLError.Code), invalid, stopped(String), length
        }

        let stage: Stage
        let cause: Cause
        var retryAfter: TimeInterval?
        var remoteCleanupFailed = false

        var canRetry: Bool {
            switch cause {
            case .http(408), .http(429), .http(500), .http(502), .http(503), .http(504): true
            case .network(let code):
                [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .networkConnectionLost, .notConnectedToInternet].contains(code)
            default: false
            }
        }

        var canSplit: Bool {
            switch cause {
            case .length, .http(413): true
            default: false
            }
        }

        var canSkip: Bool {
            switch cause {
            case .invalid, .length, .stopped, .http(413), .http(422): true
            default: canRetry
            }
        }

        var message: String {
            switch cause {
            case .http(401): "Сервис отклонил ключ. Подключите его заново."
            case .http(402): "Недостаточно средств или исчерпан бюджет подключения."
            case .http(403): "У ключа нет доступа к этому ресурсу."
            case .http(429): "Сервис ограничил число запросов. Повторите позже."
            case .http: "Сервис отклонил запрос на расшифровку."
            case .network(.timedOut): "Сервис не ответил вовремя."
            case .network: "Не удалось подключиться к сервису расшифровки."
            case .invalid: "Сервис вернул ответ в неизвестном формате."
            case .stopped: "Сервис прервал распознавание."
            case .length: "Сервис достиг предельной длины ответа."
            }
        }

        var code: String {
            switch cause {
            case .http(let status): "HTTP \(status)"
            case .network(let code): "URL \(code.rawValue)"
            case .invalid: "invalid_response"
            case .stopped(let reason): reason
            case .length: "length"
            }
        }

        static func finishReason(_ reason: String?, success: String) throws {
            guard let reason, reason != success else { return }
            let code = reason.lowercased()
            let cause: Cause
            switch code {
            case "length", "max_tokens": cause = .length
            case "blacklist", "safety", "recitation", "content_filter", "error", "function_call", "tool_calls":
                cause = .stopped(code)
            default: cause = .stopped("unknown_finish_reason")
            }
            throw Self(stage: .recognition, cause: cause)
        }
    }

    struct AudioTranscript: Sendable {
        let text: String
        var remoteCleanupFailed = false
    }

    func transcribe(_ file: URL, profile: AssistantGatewayProfile, modelID: String, allowEmpty: Bool = false) async throws -> AudioTranscript {
        guard profile.gateway.supportsTranscription, profile.gateway.permits(profile.base),
              !modelID.isEmpty, modelID.utf8.count <= 512,
              !modelID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Self.invalid }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw AssistantFailure(message: "Запись пуста.") }
        guard size <= (profile.gateway == .gemini ? 14_000_000 : 24_000_000) else {
            throw AssistantFailure(message: "Запись слишком большая для расшифровки.")
        }
        try Task.checkCancellation()
        let result: AudioTranscript
        switch profile.gateway {
        case .gigaChat:
            result = try await transcribeWithGigaChat(file, profile: profile, modelID: modelID)
        case .gemini:
            result = .init(text: try await transcribeWithGemini(file, profile: profile, modelID: modelID))
        default:
            var request = try await authorizedRequest(profile, profile.gateway == .grok ? "stt" : "audio/transcriptions")
            var fields = [("model", modelID)]
            if profile.gateway == .openAI && modelID == "gpt-4o-transcribe-diarize" {
                fields.append(("chunking_strategy", "auto"))
            }
            if profile.gateway == .mistral {
                let wav = try await Task.detached(priority: .utility) { try NoteCallAudio.transcriptionWAV(file) }.value
                defer { try? FileManager.default.removeItem(at: wav) }
                request = try Self.audioUpload(request, file: wav, fields: fields)
            } else {
                request = try Self.audioUpload(request, file: file, fields: fields)
            }
            let response = try await get(TranscriptionResult.self, request: request, audioStage: .recognition)
            result = .init(text: response.text)
        }
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed == "[NO_SPEECH]" ? "" : trimmed
        if text.isEmpty && !allowEmpty {
            throw AssistantFailure(message: result.remoteCleanupFailed
                ? "Не удалось удалить загруженный файл из GigaChat."
                : "Сервис вернул пустую расшифровку.")
        }
        return .init(text: text, remoteCleanupFailed: result.remoteCleanupFailed)
    }

    private func transcribeWithGigaChat(_ file: URL, profile: AssistantGatewayProfile, modelID: String) async throws -> AudioTranscript {
        let upload = try await authorizedRequest(profile, "files")
        let request = try Self.audioUpload(upload, file: file, fields: [("purpose", "general")], mimeType: "audio/x-m4a")
        let uploaded = try await get(GigaUploadedFile.self, request: request, gigaChat: true, audioStage: .upload)
        guard uploaded.id.range(of: #"^[A-Za-z0-9_-]{1,160}$"#, options: .regularExpression) != nil else {
            throw AudioFailure(stage: .upload, cause: .invalid)
        }

        // Удаляем только файл, созданный этим запросом. Отмена расшифровки не отменяет очистку.
        let response: Result<String, Error>
        do {
            var request = try await authorizedRequest(profile, "chat/completions")
            try Self.setJSON(&request, [
                "model": modelID, "stream": false,
                "messages": [["role": "user", "content": Self.transcriptPrompt, "attachments": [uploaded.id]]]
            ])
            let reply = try await get(GigaTranscript.self, request: request, gigaChat: true, audioStage: .recognition)
            guard let choice = reply.choices.first else { throw AudioFailure(stage: .recognition, cause: .invalid) }
            try AudioFailure.finishReason(choice.finish_reason, success: "stop")
            guard let message = choice.message, message.hasContent else {
                throw AudioFailure(stage: .recognition, cause: .invalid)
            }
            response = .success(message.content ?? "")
        } catch { response = .failure(error) }

        let deleted = await Task.detached(priority: .utility) {
            do {
                var request = try await authorizedRequest(profile, "files/\(uploaded.id)/delete")
                request.httpMethod = "POST"
                request.timeoutInterval = 15
                let (_, response) = try await responseBytes(for: request, gigaChat: true)
                try Self.check(response)
                return true
            } catch { return false }
        }.value
        switch response {
        case .success(let text): return .init(text: text, remoteCleanupFailed: !deleted)
        case .failure(let error):
            if var failure = error as? AudioFailure {
                failure.remoteCleanupFailed = !deleted
                throw failure
            }
            throw error
        }
    }

    private func transcribeWithGemini(_ file: URL, profile: AssistantGatewayProfile, modelID: String) async throws -> String {
        guard Self.geminiAudioModels.contains(modelID) else { throw Self.invalid }
        let base = profile.base.deletingLastPathComponent()
        var request = URLRequest(url: base.appending(path: "models").appending(path: modelID + ":generateContent"))
        request.setValue(profile.key, forHTTPHeaderField: "x-goog-api-key")
        let audio = try Data(contentsOf: file).base64EncodedString()
        let audioPart = ["inlineData": ["mimeType": "audio/m4a", "data": audio]]
        let parts: [[String: Any]] = modelID == "gemini-3.5-transcribe"
            ? [audioPart] : [["text": Self.transcriptPrompt], audioPart]
        try Self.setJSON(&request, ["contents": [["parts": parts]]])
        let response = try await get(GeminiTranscript.self, request: request, audioStage: .recognition)
        guard let candidate = response.candidates?.first else { throw AudioFailure(stage: .recognition, cause: .invalid) }
        try AudioFailure.finishReason(candidate.finishReason, success: "STOP")
        guard let parts = candidate.content?.parts else { throw AudioFailure(stage: .recognition, cause: .invalid) }
        let text = parts.filter { $0.thought != true }.compactMap(\.text)
        guard !text.isEmpty || parts.isEmpty else { throw AudioFailure(stage: .recognition, cause: .invalid) }
        return text.joined(separator: "\n")
    }

    private static func audioUpload(_ request: URLRequest, file: URL, fields: [(String, String)],
                                    mimeType: String? = nil) throws -> URLRequest {
        var request = request
        let boundary = UUID().uuidString
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let contentType = mimeType ?? (file.pathExtension == "wav" ? "audio/wav" : "audio/mp4")
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.\(file.pathExtension)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    private static func setJSON(_ request: inout URLRequest, _ body: [String: Any]) throws {
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }

    private struct TranscriptionResult: Decodable { let text: String }
    private struct GigaUploadedFile: Decodable, Sendable { let id: String }
    private struct GigaTranscript: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
                let hasContent: Bool

                private enum CodingKeys: String, CodingKey { case content }
                init(from decoder: Decoder) throws {
                    let fields = try decoder.container(keyedBy: CodingKeys.self)
                    hasContent = fields.contains(.content)
                    content = try fields.decodeIfPresent(String.self, forKey: .content)
                }
            }
            let message: Message?
            let finish_reason: String?
        }
        let choices: [Choice]
    }

    private struct GeminiTranscript: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                    let thought: Bool?
                }
                let parts: [Part]
            }
            let content: Content?
            let finishReason: String?
        }
        let candidates: [Candidate]?
    }

    private struct TranscriptionProxyCatalog: Decodable {
        struct Item: Decodable {
            struct Info: Decodable { let mode: String? }
            let model_name: String
            let model_info: Info?
        }
        let data: [Item]
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
        let (bytes, response) = try await responseBytes(for: request, gigaChat: profile.gateway == .gigaChat)
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
        var request = URLRequest(url: GigaChatTrust.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "RqUID")
        request.setValue("Basic " + profile.key, forHTTPHeaderField: "Authorization")
        request.httpBody = Data(("scope=" + (profile.gigaScope ?? .personal).rawValue).utf8)
        return try await get(GigaChatAccess.self, request: request, gigaChat: true)
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

    private func responseBytes(for request: URLRequest, gigaChat: Bool) async throws -> (URLSession.AsyncBytes, URLResponse) {
        guard gigaChat else { return try await session.bytes(for: request) }
        guard let url = request.url, GigaChatTrust.allows(url) else { throw Self.invalid }
        do {
            return try await gigaChatSession.bytes(for: request, delegate: gigaChatDelegate)
        } catch let error as URLError where [
            .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
            .serverCertificateNotYetValid, .secureConnectionFailed
        ].contains(error.code) {
            throw AssistantFailure(message: "Не удалось проверить TLS-сертификат GigaChat.")
        }
    }

    private func get<Value: Decodable>(_ type: Value.Type, request: URLRequest, gigaChat: Bool = false,
                                       audioStage: AudioFailure.Stage? = nil) async throws -> Value {
        let invalid: Error = audioStage.map { AudioFailure(stage: $0, cause: .invalid) as Error } ?? Self.invalid
        do {
            let (bytes, response) = try await responseBytes(for: request, gigaChat: gigaChat)
            if let stage = audioStage {
                guard let response = response as? HTTPURLResponse else { throw invalid }
                if !(200...299).contains(response.statusCode) {
                    throw AudioFailure(stage: stage, cause: .http(response.statusCode),
                                       retryAfter: Self.retryAfter(response))
                }
            } else {
                try Self.check(response)
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 12_000_000 else { throw invalid }
                data.append(byte)
            }
            guard let value = try? JSONDecoder().decode(type, from: data) else { throw invalid }
            return value
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if let stage = audioStage { throw AudioFailure(stage: stage, cause: .network(error.code)) }
            throw error
        }
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
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
