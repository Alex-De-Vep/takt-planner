import AppKit
import Foundation
import Observation
import SwiftData

@MainActor
struct CloudLibrary {
    let container: ModelContainer
    let service: TaskService
}

@MainActor @Observable
final class CloudWorkspace {
    enum AccountAction: Hashable { case signIn, requestCode, confirmCode }

    private struct RetryKey: Hashable {
        let action: AccountAction
        let email: String

        init(_ action: AccountAction, email: String) {
            self.action = action
            self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    struct Setup {
        let profile: SyncProfile
        fileprivate let library: SyncLibrary
        fileprivate let config: SyncConfig
        fileprivate let tokens: SyncTokens
    }

    private let defaults: UserDefaults
    private let origin: URL
    private let storeURL: URL?
    private let credentialStore: (String) -> any SyncCredentialStore
    private let deviceID: String
    private(set) var profile: SyncProfile?
    private var lastAccount: SyncAccount?
    private var accountRetries: [RetryKey: Date] = [:]
    private(set) var setup: Setup?
    private(set) var engine: SyncEngine?
    private var activeAPI: SyncHTTP?
    var signInEmail: String? { profile?.account.email ?? lastAccount?.email }
    var willOpen: (() throws -> Void)?
    var didOpen: ((CloudLibrary) -> Void)?
    private(set) var busy = false
    var error: String?
    private static let welcomeKey = "planner.welcome.v3"
    var welcomeCompleted: Bool {
        didSet { defaults.set(welcomeCompleted, forKey: Self.welcomeKey) }
    }

    init(defaults: UserDefaults, origin: URL = SyncHTTP.production, storeURL: URL? = nil,
         credentialStore: @escaping (String) -> any SyncCredentialStore = { SyncKeychain(account: $0) }) {
        self.defaults = defaults
        self.origin = origin
        self.storeURL = storeURL
        self.credentialStore = credentialStore
        welcomeCompleted = defaults.bool(forKey: Self.welcomeKey)
        let key = "planner.cloud.deviceID"
        let id = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        deviceID = id.syncID
        defaults.set(deviceID, forKey: key)
        if let data = defaults.data(forKey: "planner.cloud.profile") {
            profile = try? JSONDecoder().decode(SyncProfile.self, from: data)
        }
        if let data = defaults.data(forKey: "planner.cloud.lastAccount") {
            lastAccount = try? JSONDecoder().decode(SyncAccount.self, from: data)
        }
    }

    private var namespace: String { origin.absoluteString + "|" + (PlannerPersistence.testID ?? "installed") }

    private func api(for profile: SyncProfile) -> SyncHTTP {
        SyncHTTP(origin: origin, store: credentialStore(namespace + "|" + profile.account.id + "|" + profile.account.libraryId))
    }

    private func publicAPI() -> SyncHTTP {
        SyncHTTP(origin: origin, store: credentialStore(namespace + "|public"))
    }

    private func root(for account: SyncAccount) throws -> URL {
        guard let accountID = UUID(uuidString: account.id), let libraryID = UUID(uuidString: account.libraryId) else {
            throw SyncProblem.invalidResponse
        }
        return try (storeURL ?? PlannerPersistence.liveStoreURL()).deletingLastPathComponent()
            .appending(path: "Cloud/\(accountID.syncID)/\(libraryID.syncID)", directoryHint: .isDirectory)
    }

    private func cacheKey(for account: SyncAccount) -> String { "planner.cloud.cache.\(account.libraryId)" }

    private func library(for account: SyncAccount, cacheID: UUID? = nil) throws -> (CloudLibrary, SyncRepository) {
        var directory = try root(for: account)
        if let id = cacheID ?? defaults.string(forKey: cacheKey(for: account)).flatMap(UUID.init(uuidString:)) {
            directory = directory.appending(path: "Recovered/\(id.uuidString)", directoryHint: .isDirectory)
        }
        let database = directory.appending(path: "Planner.store")
        if cacheID == nil, defaults.string(forKey: cacheKey(for: account)) != nil,
           !FileManager.default.fileExists(atPath: database.path) { throw BackupError.invalid }
        let container = try PlannerPersistence.makeContainer(at: database)
        let service = TaskService(context: container.mainContext)
        service.notes = NoteStore(url: directory.appending(path: "Notes.json"))
        let repo = try SyncRepository(context: container.mainContext, libraryID: account.libraryId, deviceID: deviceID)
        service.syncRepository = repo
        repo.didApplyTasks = { [weak service] ids in
            for id in ids { service?.notificationChanged?(id, false) }
            service?.didSaveTasks?()
        }
        return (CloudLibrary(container: container, service: service), repo)
    }

    func resume() throws -> CloudLibrary? {
        guard let account = profile?.account ?? lastAccount else { return nil }
        let (library, repo) = try library(for: account)
        if let profile { attach(repo: repo, service: library.service, api: api(for: profile)) }
        return library
    }

    func useRestoredLocalLibrary() {
        engine?.stop()
        engine = nil
        let api = activeAPI
        activeAPI = nil
        setup = nil
        error = nil
        // Keep the old account identity so a sign-in to a different account still
        // asks whether to transfer tasks. The restored library opens before resume().
        saveProfile(nil)
        welcomeCompleted = true
        if let api { Task { try? await api.close(removeCredential: false) } }
    }

    private func attach(repo: SyncRepository, service: TaskService, api: SyncHTTP) {
        engine?.stop()
        let engine = SyncEngine(repository: repo, api: api, notes: service.notes)
        self.engine = engine
        activeAPI = api
        service.syncQueued = { [weak engine] in engine?.wake(after: .seconds(2)) }
        service.notes.syncQueued = { [weak engine] in engine?.wake(after: .seconds(2)) }
        engine.start()
    }

    func retryDeadline(for action: AccountAction, email: String) -> Date {
        accountRetries[RetryKey(action, email: email)] ?? .distantPast
    }

    func postpone(_ action: AccountAction, email: String, seconds: Int) {
        let now = Date.now
        accountRetries = accountRetries.filter { $0.value > now }
        let key = RetryKey(action, email: email)
        accountRetries[key] = max(accountRetries[key] ?? now, now.addingTimeInterval(Double(seconds)))
    }

    func challenge(email: String, password: String?, path: String) async throws -> String {
        var fields = ["email": email]
        if let password { fields["password"] = password }
        let value: SyncChallenge = try await publicAPI().publicRequest(path, method: "POST", body: SyncHTTP.payload(fields))
        return value.challengeId
    }

    func confirm(challengeID: String, code: String, password: String, reset: Bool) async throws {
        let path = reset ? "/v1/auth/password-reset/confirm" : "/v1/auth/verify-email"
        let fields = ["challengeId": challengeID, "code": code, reset ? "newPassword" : "password": password]
        let value: SyncOK = try await publicAPI().publicRequest(path, method: "POST", body: SyncHTTP.payload(fields))
        guard value.ok else { throw SyncProblem.invalidResponse }
    }

    func signIn(email: String, password: String, activeService: TaskService?) async throws {
        guard !busy else { throw CancellationError() }
        guard let activeService else { throw SyncProblem.invalidResponse }
        busy = true
        error = nil
        defer { busy = false }

        let publicAPI = publicAPI()
        let config: SyncConfig = try await publicAPI.publicRequest("/v1/config")
        guard config.protocolVersion == 1 else { throw SyncProblem.incompatibleProtocol }
        let fields = [
            "email": email, "password": password, "deviceId": deviceID,
            "deviceName": String((Host.current().localizedName ?? "Mac").unicodeScalars.prefix(80))
        ]
        let login: SyncLogin = try await publicAPI.publicRequest("/v1/auth/login", method: "POST",
                                                                body: SyncHTTP.payload(fields))
        let account: SyncAccount = try await publicAPI.publicRequest("/v1/me", bearer: login.accessToken)
        guard account.id == login.user.id else { throw SyncProblem.accountMismatch }
        let library: SyncLibrary = try await publicAPI.publicRequest("/v1/library", bearer: login.accessToken)
        guard library.id == account.libraryId else { throw SyncProblem.accountMismatch }
        let next = SyncProfile(account: account, sessionID: login.sessionId)
        let current = profile?.account ?? lastAccount
        if let current, current.id == account.id, current.libraryId == account.libraryId,
           let repo = activeService.syncRepository, repo.libraryID == account.libraryId {
            let authenticated = api(for: next)
            engine?.stop()
            try await activeAPI?.close(removeCredential: false)
            try await authenticated.install(login.tokens)
            saveProfile(next)
            attach(repo: repo, service: activeService, api: authenticated)
            return
        }
        guard profile == nil else { throw SyncProblem.accountMismatch }

        let nextSetup = Setup(profile: next, library: library, config: config, tokens: login.tokens)
        if defaults.string(forKey: PlannerPersistence.restoredLibraryKey) != nil || (current.map { $0.id != account.id } ?? false) {
            setup = nextSetup
        } else {
            try await activate(nextSetup, source: activeService)
        }
    }

    func cancelSetup() { setup = nil }

    func connect(importLocal: Bool, activeService: TaskService?) async {
        guard !busy, let setup, let activeService else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await activate(setup, source: importLocal ? activeService : nil)
            cancelSetup()
        } catch { self.error = error.localizedDescription }
    }

    private func activate(_ setup: Setup, source: TaskService?) async throws {
        let restored = defaults.string(forKey: PlannerPersistence.restoredLibraryKey) != nil
        // A reused server account can have the same UUID and a different database.
        // A restored local library connects through a clean cache and keeps the previous one on disk.
        let cacheID = restored ? UUID() : nil
        let (prepared, repo) = try library(for: setup.profile.account, cacheID: cacheID)
        let directory = prepared.container.configurations.first?.url.deletingLastPathComponent()
        var activated = false
        defer {
            if !activated, cacheID != nil, let directory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let publicAPI = publicAPI()
        let bearer = setup.tokens.accessToken
        if !setup.library.initialized {
            try await initializeLibrary(api: publicAPI, bearer: bearer)
        }
        let snapshot: SyncSnapshot = try await publicAPI.publicRequest("/v1/sync/snapshot", bearer: bearer)
        try repo.applySnapshot(snapshot)
        if let server = SyncWire.date(setup.config.serverTime) {
            repo.serverClockOffset = server.timeIntervalSinceNow
        }
        try Task.checkCancellation()
        let authenticated = api(for: setup.profile)
        try await authenticated.install(setup.tokens)
        do {
            try Task.checkCancellation()
            try willOpen?()
            if let source {
                guard source.notes.flush() else { throw BackupError.unsavedChanges }
                try repo.mergeLocal(from: source.context)
                try prepared.service.notes.mergeLocal(source.notes.notes)
            }
            if restored, source != nil,
               let id = defaults.string(forKey: PlannerPersistence.restoredLibraryKey).flatMap(UUID.init(uuidString:)),
               let directory {
                let restoredDirectory = try PlannerPersistence.restoredLibraryDirectory(id)
                let sourceStore = AssistantStore(url: restoredDirectory.appending(path: "Assistant/conversations.json"))
                let targetStore = AssistantStore(url: directory.appending(path: "Assistant/conversations.json"))
                try targetStore.save(sourceStore.load())
            }
        } catch {
            try? await authenticated.close(removeCredential: true)
            throw error
        }
        if let cacheID { defaults.set(cacheID.uuidString, forKey: cacheKey(for: setup.profile.account)) }
        saveProfile(setup.profile)
        activated = true
        didOpen?(prepared)
        attach(repo: repo, service: prepared.service, api: authenticated)
        welcomeCompleted = true
    }

    private func initializeLibrary(api: SyncHTTP, bearer: String) async throws {
        let id = UUID().syncID
        do {
            let response: SyncImportResponse = try await api.publicRequest("/v1/library/imports", method: "POST",
                body: SyncHTTP.payload(["importId": id]), bearer: bearer)
            guard response.importId == id else { throw SyncProblem.invalidResponse }
            if response.committed { return }
            let value: SyncOK = try await api.publicRequest("/v1/library/imports/" + id + "/commit", method: "POST",
                body: Data("{}".utf8), bearer: bearer)
            guard value.ok else { throw SyncProblem.invalidResponse }
        } catch let failure as SyncHTTPFailure where failure.problem.code == "library_exists" {
            // Другое устройство успело инициализировать тот же аккаунт.
        }
    }

    func signOut() async {
        guard !busy, profile != nil else { return }
        busy = true
        error = nil
        defer { busy = false }

        // Та же база остаётся открытой. TaskService продолжает записывать изменения в очередь.
        engine?.stop()
        engine = nil
        let api = activeAPI
        activeAPI = nil
        saveProfile(nil)
        do {
            if let token = try await api?.endSession() {
                let client = publicAPI()
                Task {
                    let _: SyncOK? = try? await client.publicRequest("/v1/auth/logout", method: "POST",
                        body: Data("{}".utf8), bearer: token)
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func saveProfile(_ profile: SyncProfile?) {
        if let account = profile?.account ?? self.profile?.account {
            lastAccount = account
            defaults.set(try? JSONEncoder().encode(account), forKey: "planner.cloud.lastAccount")
        }
        self.profile = profile
        defaults.set(profile.flatMap { try? JSONEncoder().encode($0) }, forKey: "planner.cloud.profile")
    }
}
