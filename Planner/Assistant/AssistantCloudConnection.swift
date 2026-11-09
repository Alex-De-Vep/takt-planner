import AppKit
import Foundation
import Observation
import Security

struct ChatGPTAccount: Codable, Identifiable, Sendable {
    let id: String // OAuth-регистрация для конкретного аккаунта и пространства.
    let subject: String
    let email: String?
    var tokens: ChatGPTTokens?
    var expiresAt: Date?
    var requiresConsent: Bool? = nil
    var label: String { email ?? "ChatGPT" }
}

struct ChatGPTVault: Codable, Sendable {
    var activeID: String?
    var accounts: [ChatGPTAccount] = []
}

struct ChatGPTKeychain {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "local.planner.Planner") + ".chatgpt",
         kSecAttrAccount as String: "profiles-v1"]
    }

    func load() throws -> ChatGPTVault {
        var query = query
        query[kSecReturnData as String] = true
        var data: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &data)
        if status == errSecItemNotFound { return ChatGPTVault() }
        guard status == errSecSuccess, let data = data as? Data else { throw Self.failure }
        return try JSONDecoder().decode(ChatGPTVault.self, from: data)
    }

    func save(_ vault: ChatGPTVault) throws {
        let data = try JSONEncoder().encode(vault)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Self.failure }
        let item = query.merging(attributes) { old, _ in old }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Self.failure }
    }

    private static let failure = AssistantFailure(message: "Не удалось открыть Связку ключей для подключения ChatGPT.")
}

@MainActor @Observable
final class AssistantCloudConnection {
    private(set) var vault = ChatGPTVault()
    private(set) var models: [ChatGPTModel] = []
    private(set) var busy = false
    private(set) var signingIn = false
    private(set) var sending = false
    var error: String?

    @ObservationIgnored private let http: ChatGPTHTTP
    @ObservationIgnored private let keychain = ChatGPTKeychain()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let preview: Bool
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var operation: Task<Void, Never>?

    init(http: ChatGPTHTTP = ChatGPTHTTP(), defaults: UserDefaults = .standard) {
        self.http = http
        self.defaults = defaults
        #if SHOWCASE
        preview = true
        #else
        preview = false
        #endif
    }

    var account: ChatGPTAccount? { vault.accounts.first { $0.id == vault.activeID } }
    var isConnected: Bool { account?.tokens != nil }

    func canSend(to accountID: String?) -> Bool {
        guard !busy, !sending, let account, account.tokens != nil, !models.isEmpty else { return false }
        return accountID == nil || account.id == accountID
    }

    func activate() {
        guard !loaded, !preview else { return }
        do {
            vault = try keychain.load()
            loaded = true
            if isConnected { refreshModels() }
        } catch { self.error = error.localizedDescription }
    }

    func signIn(clientID: String? = nil, russian: Bool) {
        guard !preview, !busy, !sending else { return }
        if !loaded {
            do { vault = try keychain.load(); loaded = true }
            catch { self.error = error.localizedDescription; return }
        }
        let previous = vault.accounts.first { $0.id == clientID }
        guard clientID == nil || previous != nil else { return }
        signingIn = true
        run { [self] in
            defer { signingIn = false }
            let account = try await authorize(previous: previous, russian: russian)
            try Task.checkCancellation()
            var updated = vault
            if let index = updated.accounts.firstIndex(where: { $0.id == account.id }) { updated.accounts[index] = account }
            else { updated.accounts.append(account) }
            updated.activeID = account.id
            try save(updated)
            models = []
            if account.tokens != nil { try await loadModels() }
            else { error = "Разрешите использовать подписку ChatGPT при входе." }
        }
    }

    func cancelSignIn() { if signingIn { operation?.cancel() } }

    func selectAccount(_ id: String, russian: Bool) {
        guard !busy, !sending, let selected = vault.accounts.first(where: { $0.id == id }) else { return }
        if selected.tokens == nil { signIn(clientID: id, russian: russian); return }
        run { [self] in
            var updated = vault
            updated.activeID = id
            try save(updated)
            models = []
            try await loadModels()
        }
    }

    func refreshModels() {
        guard !preview, !busy, !sending, isConnected else { return }
        run { [self] in try await loadModels() }
    }

    func signOut() {
        guard !busy, !sending, let account, let tokens = account.tokens else { return }
        run { [self] in
            var revocationFailed = false
            if let refresh = tokens.refreshToken {
                do { try await http.revoke(refreshToken: refresh, clientID: account.id) }
                catch { revocationFailed = true }
            }
            try removeCredentials(for: account.id)
            if revocationFailed { error = "Вы вышли на этом Mac. Отзыв доступа проверьте в настройках ChatGPT." }
        }
    }

    func respond(body: Data, accountID: String, onText: @escaping @MainActor (String) -> Void) async throws -> AssistantCloudCompletion {
        guard canSend(to: accountID) else { throw AssistantFailure(message: "Подключите аккаунт ChatGPT для этого диалога.") }
        sending = true
        defer { sending = false }
        do {
            let token = try await accessToken()
            try Task.checkCancellation()
            return try await http.respond(body: body, accessToken: token, onText: onText)
        } catch let failure as ChatGPTHTTPError where failure.status == 401 {
            try removeCredentials(for: accountID)
            throw failure
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.operation = nil }
            do { try await work() }
            catch is CancellationError {}
            catch let error as URLError where error.code == .cancelled {}
            catch let failure { self.error = failure.localizedDescription }
        }
    }

    private func loadModels() async throws {
        let token = try await accessToken()
        do { models = try await http.models(accessToken: token) }
        catch let failure as ChatGPTHTTPError where failure.status == 401 {
            if let id = account?.id { try removeCredentials(for: id) }
            throw failure
        }
        if models.isEmpty { throw AssistantFailure(message: "Для аккаунта ChatGPT нет доступных моделей.") }
    }

    private func accessToken() async throws -> String {
        guard var account, let tokens = account.tokens else {
            throw AssistantFailure(message: "Подключите аккаунт ChatGPT для этого диалога.")
        }
        if let expiresAt = account.expiresAt, expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        guard let refresh = tokens.refreshToken else {
            try removeCredentials(for: account.id)
            throw AssistantFailure(message: "Сессия ChatGPT закончилась. Войдите снова.")
        }
        do {
            // Обновление с ротацией завершается даже при отмене ответа пользователем.
            let http = http
            let fields = ["grant_type": "refresh_token", "client_id": account.id,
                          "refresh_token": refresh, "resource": ChatGPTIdentity.resource]
            let renewed = try await Task.detached { try await http.tokens(fields) }.value
            guard renewed.allowsPlan != false, let replacement = renewed.refreshToken, !replacement.isEmpty else {
                try removeCredentials(for: account.id)
                throw AssistantFailure(message: "Разрешите использовать подписку ChatGPT при входе.")
            }
            account.tokens = ChatGPTTokens(accessToken: renewed.accessToken, refreshToken: replacement,
                                           idToken: tokens.idToken, tokenType: renewed.tokenType,
                                           expiresIn: renewed.expiresIn, scope: renewed.scope ?? tokens.scope)
            account.expiresAt = Date.now.addingTimeInterval(renewed.expiresIn)
            var updated = vault
            guard let index = updated.accounts.firstIndex(where: { $0.id == account.id }) else { throw CancellationError() }
            updated.accounts[index] = account
            try save(updated)
            return renewed.accessToken
        } catch let failure as ChatGPTHTTPError where failure.refreshRejected {
            try removeCredentials(for: account.id)
            throw failure
        }
    }

    private func removeCredentials(for id: String) throws {
        var updated = vault
        guard let index = updated.accounts.firstIndex(where: { $0.id == id }) else { return }
        updated.accounts[index].tokens = nil
        updated.accounts[index].expiresAt = nil
        if updated.activeID == id { models = [] }
        try save(updated)
    }

    private func save(_ updated: ChatGPTVault) throws {
        try keychain.save(updated)
        vault = updated
    }

    private func authorize(previous: ChatGPTAccount?, russian: Bool) async throws -> ChatGPTAccount {
        let state = try ChatGPTIdentity.random()
        let nonce = try ChatGPTIdentity.random()
        let verifier = try ChatGPTIdentity.random()
        let hostID = defaults.string(forKey: "chatGPTHostID") ?? "urn:uuid:" + UUID().uuidString.lowercased()
        defaults.set(hostID, forKey: "chatGPTHostID")
        let listener = ChatGPTLoopback(state: state, registeredClientID: previous?.id, russian: russian)
        var redirect: String?
        let grant = try await listener.receive { callback in
            redirect = callback.absoluteString
            var url = URLComponents(string: ChatGPTIdentity.issuer + "/api/accounts/authorize")!
            var query = [
                URLQueryItem(name: "client_id", value: previous?.id ?? "dynamic_agent_client"),
                URLQueryItem(name: "ext_agent_host_id", value: hostID),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: callback.absoluteString),
                URLQueryItem(name: "scope", value: ChatGPTIdentity.scopes),
                URLQueryItem(name: "resource", value: ChatGPTIdentity.resource),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "nonce", value: nonce),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "code_challenge", value: ChatGPTIdentity.challenge(verifier))
            ]
            if let previous {
                if previous.requiresConsent == true { query.append(.init(name: "prompt", value: "consent")) }
                if let hint = previous.tokens?.idToken { query.append(.init(name: "id_token_hint", value: hint)) }
                else if let email = previous.email { query.append(.init(name: "login_hint", value: email)) }
            } else {
                query.append(.init(name: "agent_name_hint", value: "Tasks"))
            }
            url.queryItems = query
            return url.url.map { NSWorkspace.shared.open($0) } ?? false
        }
        try Task.checkCancellation()
        guard let redirect else { throw AssistantFailure(message: "Не удалось проверить ответ входа в ChatGPT.") }
        let tokens = try await http.tokens(["grant_type": "authorization_code", "client_id": grant.clientID,
                                            "code": grant.code, "code_verifier": verifier, "redirect_uri": redirect,
                                            "resource": ChatGPTIdentity.resource])
        guard let idToken = tokens.idToken else { throw AssistantFailure(message: "Не удалось проверить ответ входа в ChatGPT.") }
        let identity = try ChatGPTIdentity.verify(token: idToken, keys: await http.keys(), clientID: grant.clientID, nonce: nonce)
        guard previous == nil || previous?.subject == identity.sub,
              vault.accounts.first(where: { $0.id == grant.clientID }).map({ $0.subject == identity.sub }) != false else {
            throw AssistantFailure(message: "Вход выполнен в другой аккаунт ChatGPT.")
        }
        // Сохраняем регистрацию даже при отказе в использовании плана, чтобы запросить согласие повторно.
        let allowed = tokens.allowsPlan == true && tokens.refreshToken?.isEmpty == false
        return .init(id: grant.clientID, subject: identity.sub, email: identity.email,
                     tokens: allowed ? tokens : nil, expiresAt: allowed ? .now.addingTimeInterval(tokens.expiresIn) : nil,
                     requiresConsent: !allowed)
    }
}
