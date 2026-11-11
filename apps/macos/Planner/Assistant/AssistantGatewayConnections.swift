import AppKit
import Observation
import Security

@MainActor @Observable
final class AssistantGatewayConnections {
    private(set) var profiles: [AssistantGateway: AssistantGatewayProfile] = [:]
    private(set) var catalogs: [AssistantGateway: [AssistantGatewayModel]] = [:]
    private(set) var errors: [AssistantGateway: String] = [:]
    private(set) var busy: Set<AssistantGateway> = []
    private(set) var remaining: [AssistantGateway: Double] = [:]
    private(set) var copilotQuota: Double?
    private(set) var miniMaxQuota: [String: Double] = [:]

    let http = AssistantGatewayHTTP()
    @ObservationIgnored private let keychain = AssistantGatewayKeychain()
    @ObservationIgnored private var loaded: Set<AssistantGateway> = []
    @ObservationIgnored private var operations: [AssistantGateway: Task<Void, Never>] = [:]

    func activate() {
        #if !SHOWCASE
        for gateway in AssistantGateway.allCases where load(gateway) {
            if profiles[gateway] != nil { refresh(gateway) }
        }
        #endif
    }

    private func load(_ gateway: AssistantGateway) -> Bool {
        guard !loaded.contains(gateway) else { return false }
        do {
            profiles[gateway] = try keychain.load(gateway)
            loaded.insert(gateway)
            return true
        } catch {
            errors[gateway] = AssistantGatewayKeychain.failure.message
            return false
        }
    }

    func signInOpenRouter(russian: Bool) {
        let gateway = AssistantGateway.openRouter
        run(gateway) {
            let verifier = try ChatGPTIdentity.random()
            let nonce = try ChatGPTIdentity.random()
            let callback = ChatGPTLoopback(state: nonce, registeredClientID: nil, russian: russian,
                                           openRouterPath: "/auth/openrouter/" + nonce)
            let grant = try await callback.receive { callbackURL in
                var url = URLComponents(string: "https://openrouter.ai/auth")
                url?.queryItems = [
                    .init(name: "callback_url", value: callbackURL.absoluteString),
                    .init(name: "code_challenge", value: ChatGPTIdentity.challenge(verifier)),
                    .init(name: "code_challenge_method", value: "S256"),
                    .init(name: "state", value: nonce),
                    .init(name: "key_label", value: "Tasks")
                ]
                return url?.url.map { NSWorkspace.shared.open($0) } ?? false
            }
            let key = try await self.http.openRouterKey(code: grant.code, verifier: verifier)
            try await self.verify(.init(id: UUID(), gateway: gateway, base: AssistantGatewayProfile.openRouterBase, key: key))
        }
    }

    func connect(_ gateway: AssistantGateway, base: URL, key input: String, modelIDs: String,
                 folder: String, gigaScope: GigaChatScope) {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard gateway != .openRouter, gateway.permits(base), AssistantGatewayHTTP.validKey(key) else {
            errors[gateway] = "Проверьте адрес и ключ подключения."
            return
        }
        let folderID = gateway == .yandex ? folder.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        if let folderID, folderID.range(of: #"^[A-Za-z0-9]{10,64}$"#, options: .regularExpression) == nil {
            errors[gateway] = "Укажите идентификатор каталога Yandex Cloud."
            return
        }
        let scope = gateway == .gigaChat ? gigaScope : nil
        let ids = folderID.map { ["gpt://\($0)/yandexgpt/latest"] }
            ?? (gateway.configuredCatalog ? Self.parseModelIDs(modelIDs) : [])
        guard !gateway.configuredCatalog || !ids.isEmpty else {
            errors[gateway] = "Введите от одного до восьми идентификаторов моделей через запятую."
            return
        }
        run(gateway) {
            let previous = self.profiles[gateway]
            var profile = previous.flatMap {
                $0.base == base && $0.key == key && $0.folderID == folderID && $0.gigaScope == scope ? $0 : nil
            } ?? .init(id: UUID(), gateway: gateway, base: base, key: key)
            profile.folderID = folderID
            profile.gigaScope = scope
            if gateway.configuredCatalog { profile.configuredModelIDs = ids }
            if gateway == .copilot { profile.account = try await self.http.copilotAccount(profile) }
            try await self.verify(profile)
        }
    }

    static func parseModelIDs(_ text: String) -> [String] {
        let ids = text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard ids.count <= 8, ids.allSatisfy({
            $0.utf8.count <= 160 && $0.range(of: #"^[A-Za-z0-9_./:+-]+$"#, options: .regularExpression) != nil
        }) else { return [] }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func verify(_ profile: AssistantGatewayProfile) async throws {
        let balance = profile.gateway == .openRouter ? try await http.remainingKeyBudget(profile) : nil
        try await http.verifyConfiguredModels(profile)
        let models = try await http.models(profile)
        try Task.checkCancellation()
        // Старое подключение остаётся рабочим, пока новое не проверено и не сохранено.
        try keychain.save(profile)
        profiles[profile.gateway] = profile
        if profile.gateway == .copilot { copilotQuota = nil }
        if profile.gateway == .miniMaxPlan { miniMaxQuota = [:] }
        catalogs[profile.gateway] = models
        remaining[profile.gateway] = balance
    }

    func refresh(_ gateway: AssistantGateway) {
        guard let profile = profiles[gateway] else { return }
        run(gateway) {
            if gateway == .openRouter { _ = try await self.http.remainingKeyBudget(profile) }
            let models = try await self.http.models(profile)
            try Task.checkCancellation()
            self.catalogs[gateway] = models
        }
    }

    func refreshBudget(for profile: AssistantGatewayProfile, modelID: String?) async {
        if profile.gateway == .copilot {
            let percent = try? await http.remainingCopilotPercent(profile)
            guard !Task.isCancelled, profiles[.copilot]?.id == profile.id else { return }
            copilotQuota = percent
            return
        }
        if profile.gateway == .miniMaxPlan, let modelID {
            let percent = try? await http.remainingMiniMaxPercent(profile, modelID: modelID)
            guard !Task.isCancelled, profiles[.miniMaxPlan]?.id == profile.id else { return }
            miniMaxQuota[modelID] = percent
            return
        }
        guard profile.gateway.supportsKeyBudget else { return }
        let balance = try? await http.remainingKeyBudget(profile)
        guard !Task.isCancelled, profiles[profile.gateway]?.id == profile.id else { return }
        remaining[profile.gateway] = balance
    }

    func setTools(_ enabled: Bool, gateway: AssistantGateway, modelID: String) {
        guard var profile = profiles[gateway], !busy.contains(gateway),
              catalogs[gateway]?.contains(where: { $0.id == modelID && $0.reportedTools == nil }) == true else { return }
        if enabled { profile.toolModelIDs.insert(modelID) } else { profile.toolModelIDs.remove(modelID) }
        do {
            try keychain.save(profile)
            profiles[gateway] = profile
            errors[gateway] = nil
        } catch { errors[gateway] = AssistantGatewayKeychain.failure.message }
    }

    func disconnect(_ gateway: AssistantGateway) {
        guard !busy.contains(gateway) else { return }
        do {
            try keychain.remove(gateway)
            profiles[gateway] = nil
            catalogs[gateway] = nil
            remaining[gateway] = nil
            if gateway == .copilot { copilotQuota = nil }
            if gateway == .miniMaxPlan { miniMaxQuota = [:] }
            errors[gateway] = nil
        } catch { errors[gateway] = AssistantGatewayKeychain.failure.message }
    }

    func cancel(_ gateway: AssistantGateway) { operations[gateway]?.cancel() }

    private func run(_ gateway: AssistantGateway, _ work: @escaping @MainActor () async throws -> Void) {
        #if !SHOWCASE
        guard !busy.contains(gateway), loaded.contains(gateway) || load(gateway) else { return }
        busy.insert(gateway)
        errors[gateway] = nil
        operations[gateway] = Task {
            defer {
                busy.remove(gateway)
                operations[gateway] = nil
            }
            do { try await work() } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    errors[gateway] = (error as? AssistantFailure)?.message ?? AssistantGatewayHTTP.invalid.message
                }
            }
        }
        #endif
    }
}

private struct AssistantGatewayKeychain {
    static let failure = AssistantFailure(message: "Не удалось сохранить подключение в Связке ключей.")

    private func query(_ gateway: AssistantGateway) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "local.planner.Planner") + ".model-gateways",
         kSecAttrAccount as String: gateway.rawValue]
    }

    func load(_ gateway: AssistantGateway) throws -> AssistantGatewayProfile? {
        var request = query(gateway)
        request[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let profile = try? JSONDecoder().decode(AssistantGatewayProfile.self, from: data),
              profile.gateway == gateway, AssistantGatewayHTTP.validKey(profile.key),
              gateway.permits(profile.base) else { throw Self.failure }
        return profile
    }

    func save(_ profile: AssistantGatewayProfile) throws {
        let query = query(profile.gateway)
        let data = [kSecValueData as String: try JSONEncoder().encode(profile)]
        let status = SecItemUpdate(query as CFDictionary, data as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound,
              SecItemAdd(query.merging(data) { original, _ in original } as CFDictionary, nil) == errSecSuccess else { throw Self.failure }
    }

    func remove(_ gateway: AssistantGateway) throws {
        let status = SecItemDelete(query(gateway) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure }
    }
}
