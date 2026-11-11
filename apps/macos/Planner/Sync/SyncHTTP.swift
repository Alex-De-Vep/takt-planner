import Foundation
import Security

struct SyncTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
}

struct SyncLogin: Decodable, Sendable {
    struct User: Decodable, Sendable { let id: String; let email: String }
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let sessionId: String
    let user: User

    var tokens: SyncTokens {
        SyncTokens(accessToken: accessToken, refreshToken: refreshToken, expiresIn: expiresIn)
    }
}

struct SyncProfile: Codable, Equatable, Sendable {
    let account: SyncAccount
    let sessionID: String
}

struct SyncHTTPFailure: LocalizedError, Sendable {
    let status: Int
    let problem: SyncAPIError
    var errorDescription: String? { problem.message }
}

struct SyncRefreshCredential: Codable, Sendable {
    let token: String
    var inFlight = false
}

protocol SyncCredentialStore: Sendable {
    func load() throws -> SyncRefreshCredential?
    func save(_ value: SyncRefreshCredential) throws
    func remove() throws
}

struct SyncKeychain: SyncCredentialStore {
    let account: String
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.planner.Planner.sync",
         kSecAttrAccount as String: account]
    }

    func load() throws -> SyncRefreshCredential? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = value as? Data else { throw SyncProblem.invalidResponse }
        return try JSONDecoder().decode(SyncRefreshCredential.self, from: data)
    }

    func save(_ value: SyncRefreshCredential) throws {
        let data = try JSONEncoder().encode(value)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query.merging(update) { _, new in new } as CFDictionary, nil))
        } else { try check(status) }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

private final class SyncRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor SyncHTTP {
    static let production = URL(string: "https://planner-server.tail037e91.ts.net")!
    private let origin: URL
    private let session: URLSession
    private let store: any SyncCredentialStore
    private var accessToken: String?
    private var expiry = Date.distantPast
    private var refreshTask: Task<SyncTokens, Error>?
    private var closed = false

    init(origin: URL = SyncHTTP.production, store: any SyncCredentialStore, session: URLSession? = nil) {
        self.origin = origin
        self.store = store
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.urlCache = nil
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 90
            self.session = URLSession(configuration: config, delegate: SyncRedirectPolicy(), delegateQueue: nil)
        }
    }

    static func payload<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }

    func install(_ tokens: SyncTokens) throws {
        guard !closed else { throw CancellationError() }
        try store.save(SyncRefreshCredential(token: tokens.refreshToken))
        accessToken = tokens.accessToken
        expiry = Date().addingTimeInterval(Double(max(0, tokens.expiresIn - 30)))
    }

    func close(removeCredential: Bool) throws {
        closed = true
        refreshTask?.cancel()
        accessToken = nil
        if removeCredential { try store.remove() }
    }

    func endSession() throws -> String? {
        let token = accessToken
        try close(removeCredential: true)
        return token
    }

    func publicRequest<T: Decodable & Sendable>(_ path: String, method: String = "GET",
                                               body: Data? = nil, bearer: String? = nil) async throws -> T {
        try await request(path, method: method, body: body, bearer: bearer)
    }

    func authorized<T: Decodable & Sendable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let token = try await validAccess()
        do {
            return try await request(path, method: method, body: body, bearer: token)
        } catch let failure as SyncHTTPFailure where failure.status == 401 {
            if accessToken == token { expiry = .distantPast }
            let refreshed = try await validAccess()
            do {
                return try await request(path, method: method, body: body, bearer: refreshed)
            } catch let retry as SyncHTTPFailure where retry.status == 401 {
                throw SyncProblem.signInRequired
            }
        }
    }

    private func validAccess() async throws -> String {
        guard !closed else { throw CancellationError() }
        if let accessToken, expiry > .now { return accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let task = Task { try await self.rotate() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.accessToken
    }

    private func rotate() async throws -> SyncTokens {
        guard !closed, let credential = try store.load(), !credential.inFlight else {
            throw SyncProblem.signInRequired
        }
        // При потере ответа старый refresh может быть уже использован сервером.
        // Маркер переживает аварийный выход и предотвращает повтор такого токена.
        try store.save(SyncRefreshCredential(token: credential.token, inFlight: true))
        do {
            let tokens: SyncTokens = try await request("/v1/auth/refresh", method: "POST",
                body: Self.payload(["refreshToken": credential.token]), bearer: nil)
            try install(tokens)
            return tokens
        } catch let error as SyncHTTPFailure where error.status == 429 {
            if !closed { try store.save(credential) }
            throw error
        } catch let error as URLError where [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code) {
            if !closed { try store.save(credential) }
            throw error
        } catch {
            if closed || Task.isCancelled { throw CancellationError() }
            throw SyncProblem.signInRequired
        }
    }

    private func request<T: Decodable & Sendable>(_ path: String, method: String, body: Data?, bearer: String?) async throws -> T {
        guard !closed, path.hasPrefix("/"), !path.hasPrefix("//"),
              let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port else {
            throw SyncProblem.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw SyncProblem.invalidResponse }
        let decoder = JSONDecoder()
        if !(200..<300).contains(http.statusCode) {
            let problem = (try? decoder.decode(SyncErrorEnvelope.self, from: data).error)
            let delay = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? problem?.retryAfterSeconds
            throw SyncHTTPFailure(status: http.statusCode, problem: SyncAPIError(
                code: problem?.code ?? "http_\(http.statusCode)",
                message: problem?.message ?? "Сервер вернул ошибку \(http.statusCode).",
                requestId: problem?.requestId, retryAfterSeconds: delay))
        }
        return try decoder.decode(T.self, from: data)
    }
}

private struct SyncErrorEnvelope: Decodable { let error: SyncAPIError }
struct SyncOK: Decodable, Sendable { let ok: Bool }
struct SyncChallenge: Decodable, Sendable { let challengeId: String }
struct SyncImportResponse: Decodable, Sendable { let importId: String; let committed: Bool }
struct SyncImportBatch: Decodable, Sendable { let accepted: Int }
struct SyncBatch: Encodable { let mutations: [SyncMutation] }
