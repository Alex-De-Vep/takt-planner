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
    var operationID: UUID?
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
    static let production = URL(string: "https://takt-server.tail037e91.ts.net")!
    private let origin: URL
    private let session: URLSession
    private let eventSession: URLSession
    private let store: any SyncCredentialStore
    private var accessToken: String?
    private var expiry = Date.distantPast
    private var refreshTask: Task<SyncTokens, Error>?
    private var closed = false
    private var refreshRecoveryEnabled = false

    func setRefreshRecoveryEnabled(_ enabled: Bool) { refreshRecoveryEnabled = enabled }

    init(origin: URL = SyncHTTP.production, store: any SyncCredentialStore, session: URLSession? = nil) {
        self.origin = origin
        self.store = store
        if let session {
            self.session = session
            eventSession = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.urlCache = nil
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 90
            self.session = URLSession(configuration: config, delegate: SyncRedirectPolicy(), delegateQueue: nil)
            config.timeoutIntervalForResource = 16 * 60
            eventSession = URLSession(configuration: config, delegate: SyncRedirectPolicy(), delegateQueue: nil)
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
        if eventSession !== session { eventSession.invalidateAndCancel() }
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

    func sendSupport(_ submission: SupportSubmission) async throws -> String {
        let receipt: SupportReceipt = try await authorized("/v1/support/requests", method: "POST",
            body: Self.payload(submission))
        guard receipt.isValid else { throw SyncProblem.invalidResponse }
        return receipt.code
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
        guard !closed, let credential = try store.load(), !credential.inFlight || credential.operationID != nil else {
            throw SyncProblem.signInRequired
        }
        if let operationID = credential.operationID ?? (refreshRecoveryEnabled ? UUID() : nil) {
            if credential.operationID == nil {
                try store.save(SyncRefreshCredential(token: credential.token, inFlight: true, operationID: operationID))
            }
            do {
                let tokens: SyncTokens = try await request("/v1/auth/refresh", method: "POST",
                    body: Self.payload(["refreshToken": credential.token, "operationId": operationID.syncID]), bearer: nil)
                try install(tokens)
                return tokens
            } catch let failure as SyncHTTPFailure where failure.status == 401 {
                throw SyncProblem.signInRequired
            }
        }
        // Older servers cannot safely replay a refresh after losing its response.
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

    func watchSyncEvents(_ receive: @Sendable (SyncStreamEvent) async -> Void) async throws {
        let token = try await validAccess()
        do {
            try await readSyncEvents(bearer: token, receive: receive)
        } catch let failure as SyncHTTPFailure where failure.status == 401 {
            if accessToken == token { expiry = .distantPast }
            let refreshed = try await validAccess()
            do {
                try await readSyncEvents(bearer: refreshed, receive: receive)
            } catch let retry as SyncHTTPFailure where retry.status == 401 {
                throw SyncProblem.signInRequired
            }
        }
    }

    private func readSyncEvents(bearer: String, receive: @Sendable (SyncStreamEvent) async -> Void) async throws {
        var request = try makeRequest("/v1/notes/events", method: "GET", bearer: bearer)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await eventSession.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw SyncProblem.invalidResponse }
        guard http.statusCode == 200 else { throw Self.httpFailure(http) }
        guard http.mimeType == "text/event-stream" else { throw SyncProblem.invalidResponse }

        var parser = SyncStreamParser()
        for try await byte in bytes {
            if let event = try parser.append(byte) {
                try Task.checkCancellation()
                await receive(event)
            }
        }
    }

    private func makeRequest(_ path: String, method: String, bearer: String?) throws -> URLRequest {
        guard !closed, path.hasPrefix("/"), !path.hasPrefix("//"),
              let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port else {
            throw SyncProblem.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        return request
    }

    private func request<T: Decodable & Sendable>(_ path: String, method: String, body: Data?, bearer: String?) async throws -> T {
        var request = try makeRequest(path, method: method, bearer: bearer)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw SyncProblem.invalidResponse }
        let decoder = JSONDecoder()
        if !(200..<300).contains(http.statusCode) {
            throw Self.httpFailure(http, problem: try? decoder.decode(SyncErrorEnvelope.self, from: data).error)
        }
        return try decoder.decode(T.self, from: data)
    }

    private static func httpFailure(_ http: HTTPURLResponse, problem: SyncAPIError? = nil) -> SyncHTTPFailure {
        let delay = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? problem?.retryAfterSeconds
        return SyncHTTPFailure(status: http.statusCode, problem: SyncAPIError(
            code: problem?.code ?? "http_\(http.statusCode)",
            message: problem?.message ?? "Сервер вернул ошибку \(http.statusCode).",
            requestId: problem?.requestId, retryAfterSeconds: delay, attemptsRemaining: problem?.attemptsRemaining))
    }
}

private struct SyncErrorEnvelope: Decodable { let error: SyncAPIError }
struct SyncOK: Decodable, Sendable { let ok: Bool }
struct SyncChallenge: Decodable, Sendable { let challengeId: String }
struct SyncImportResponse: Decodable, Sendable { let importId: String; let committed: Bool }
struct SyncImportBatch: Decodable, Sendable { let accepted: Int }
struct SyncBatch: Encodable { let mutations: [SyncMutation] }
