import Foundation
import Security
import Testing
@testable import Planner

@MainActor struct AssistantCloudTests {
    private let context = AssistantContext(now: Date(timeIntervalSince1970: 1_800_000_000), timeZoneID: "Europe/Moscow",
        language: "en", folders: [.init(id: "inbox", name: "Inbox"), .init(id: "week", name: "This Week")],
        calendars: [.init(id: "private-calendar-id", name: "Private calendar")],
        defaultFolderID: "inbox", defaultCalendarID: "private-calendar-id",
        taskID: nil, taskTitle: nil, durationMinutes: 60)

    private func model() throws -> ChatGPTModel {
        try JSONDecoder().decode(ChatGPTModel.self, from: Data(#"{"slug":"test","display_name":"Test","visibility":"list","supported_reasoning_efforts":["medium","high"]}"#.utf8))
    }

    private func proposal(key: String = "new_1") -> AssistantProposal {
        .init(key: key, kind: .task, title: "Prepare slides", description: "Summarize the results.",
              checklist: ["Find figures", "Make slides"])
    }

    @Test func olderHistoryDefaultsToLocal() throws {
        let data = Data("""
            {"id":"\(UUID())","title":"Old chat","draft":"","messages":[],"actions":[],"createdAt":0}
            """.utf8)
        #expect(try JSONDecoder().decode(AssistantThread.self, from: data).cloud == nil)
    }

    @Test func gigaChatTrustIsRestrictedToItsHTTPSOrigins() throws {
        #expect(GigaChatTrust.allows(GigaChatTrust.tokenURL))
        #expect(GigaChatTrust.allows(GigaChatTrust.apiBase))
        for address in ["http://api.giga.chat/v1", "https://api.giga.chat:9443/v1",
                        "https://ngw.devices.sberbank.ru/api/v2/oauth", "https://other.api.giga.chat/v1",
                        "https://api.giga.chat.example.com/v1", "https://name@api.giga.chat/v1"] {
            #expect(!GigaChatTrust.allows(URL(string: address)!))
        }
        let anchor = try #require(GigaChatTrust.bundledAnchor)
        let root = try #require(SecCertificateCreateWithData(nil, anchor as CFData))
        #expect(GigaChatTrust.evaluate(chain: [root], host: "api.giga.chat", port: 443, anchor: anchor) == nil)
    }

    @Test(arguments: [AssistantGateway?.none, .some(.deepSeek)])
    func clearingHistoryKeepsCloudSelectionAcrossReopen(gateway: AssistantGateway?) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ClearChat-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AssistantStore(url: directory.appending(path: "chat.json"))
        let profileID = gateway == nil ? nil : UUID()
        let accountID = gateway == nil ? "test-account" : nil
        var thread = AssistantThread()
        thread.messages = [.init(role: .user, text: "Old history")]
        thread.draft = "Old draft"
        thread.chooseModel(id: "test-model", efforts: ["high"], accountID: accountID, gateway: gateway, profileID: profileID)
        thread.cloud?.effort = "high"
        let action = AssistantAction(proposal: proposal(), context: context)
        thread.actions = [action]
        thread.cloud?.draftIDs = [action.id]
        thread.clarificationContext = context
        try store.save(.init(currentID: thread.id, threads: [AssistantThread(), thread]))

        let service = AssistantService(model: ModelManager(backend: FakeAIBackend()), store: store)
        service.clearHistory()

        let saved = try store.load()
        let cleared = try #require(saved.threads.first)
        #expect(saved.threads.count == 1 && saved.currentID == cleared.id && cleared.id != thread.id)
        #expect(cleared.messages.isEmpty && cleared.actions.isEmpty && cleared.draft.isEmpty)
        #expect(cleared.clarificationContext == nil)
        #expect(cleared.usesCloudModel && cleared.cloud?.modelID == "test-model")
        #expect(cleared.cloud?.accountID == accountID && cleared.cloud?.gateway == gateway)
        #expect(cleared.cloud?.gatewayProfileID == profileID && cleared.cloud?.effort == "high")
        #expect(cleared.cloud?.historyStart == 0 && cleared.cloud?.draftIDs == [])
    }

    @Test func requestSendsOnlyExplicitTaskAndSmallHistory() throws {
        var thread = AssistantThread()
        thread.actions = [.init(proposal: proposal(), context: context)]
        thread.messages = [.init(role: .user, text: "Previous request")]
        let snapshot = AssistantTextSnapshot(id: UUID(), title: "Open task", description: "Task text", checklist: [])
        let request = try AssistantCloudRequest(thread: thread, text: "Improve the description", context: context,
            edit: .init(target: .savedTask, before: snapshot), model: model(), effort: "high")
        let json = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let payload = String(decoding: request.body, as: UTF8.self)
        #expect(request.drafts["draft_1"] == thread.actions[0].id)
        #expect(json["store"] as? Bool == false)
        #expect(json["stream"] as? Bool == true)
        #expect((json["reasoning"] as? [String: String])?["effort"] == "high")
        #expect(payload.contains("Task text"))
        #expect(payload.contains("Previous request"))
        #expect(!payload.contains(snapshot.id.uuidString))
        #expect(!payload.contains(thread.actions[0].id.uuidString))
        #expect(!payload.contains("Private calendar"))
        #expect(!payload.contains("private-calendar-id"))
        let detached = try AssistantCloudRequest(thread: thread, text: "Hello", context: context, edit: nil,
            model: model(), effort: "unknown")
        let detachedJSON = try #require(JSONSerialization.jsonObject(with: detached.body) as? [String: Any])
        #expect(detachedJSON["reasoning"] == nil)
        #expect(!String(decoding: detached.body, as: UTF8.self).contains("Task text"))
    }

    @Test func selectingModelsPreservesTheChatAndOnlySharesTheCurrentCloudSegment() throws {
        let selected = try model()
        var thread = AssistantThread()
        let originalID = thread.id
        thread.draft = "Unsent draft"
        thread.messages = [.init(role: .user, text: "Private local message")]
        thread.actions = [.init(proposal: proposal(), context: context)]
        thread.activeTextEditID = UUID()

        thread.chooseModel(selected)
        #expect(thread.usesCloudModel)
        #expect(thread.id == originalID)
        #expect(thread.draft == "Unsent draft")
        #expect(thread.activeTextEditID == nil)
        #expect(thread.messages.map(\.text) == ["Private local message"])
        let initial = try AssistantCloudRequest(thread: thread, text: "Hello", context: context,
            edit: nil, model: selected, effort: nil)
        #expect(initial.drafts.isEmpty)
        #expect(!String(decoding: initial.body, as: UTF8.self).contains("Private local message"))

        thread = try AssistantService.cloudReply(.init(message: "Cloud answer", actions: [proposal()]),
            to: thread, drafts: initial.drafts, text: "Hello", context: context, edit: nil)
        let continued = try AssistantCloudRequest(thread: thread, text: "Please elaborate", context: context,
            edit: nil, model: selected, effort: nil)
        #expect(continued.drafts.values.contains(thread.actions[1].id))
        #expect(String(decoding: continued.body, as: UTF8.self).contains("Cloud answer"))

        thread.chooseModel(nil)
        #expect(!thread.usesCloudModel)
        #expect(thread.protectedLocalActionIDs == Set(thread.actions.map(\.id)))
        thread.messages.append(.init(role: .user, text: "Another local message"))
        thread.chooseModel(selected)
        let restored = try JSONDecoder().decode(AssistantThread.self, from: JSONEncoder().encode(thread))
        let next = try AssistantCloudRequest(thread: restored, text: "Hello again", context: context,
            edit: nil, model: selected, effort: nil)
        #expect(restored.usesCloudModel && restored.id == originalID)
        #expect(restored.actions.count == 2)
        #expect(next.drafts.isEmpty)
        #expect(!String(decoding: next.body, as: UTF8.self).contains("Another local message"))
    }

    @Test func streamWaitsForCompletedAndRejectsEvents() throws {
        var stream = AssistantCloudStream()
        _ = try stream.consume(#"data: {"type":"response.output_text.delta","delta":"Hello"}"#)
        let delta = try stream.consume("")
        #expect(delta.delta == "Hello")
        #expect(delta.reply == nil)
        _ = try stream.consume(#"data: {"type":"response.function_call_arguments.done","arguments":"{}"}"#)
        #expect(try stream.consume("").reply == nil)
        _ = try stream.consume(#"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Hello"}]}]}}"#)
        #expect(try stream.consume("").reply?.response.message == "Hello")

        let eventArgs = #"{"message":"","actions":[{"key":"event1","kind":"event","title":"Event"}]}"#
        let frame: [String: Any] = ["type": "response.completed", "response": ["status": "completed", "output": [
            ["type": "function_call", "namespace": "planner", "name": "propose_changes", "arguments": eventArgs]
        ]]]
        _ = try stream.consume("data: " + String(decoding: JSONSerialization.data(withJSONObject: frame), as: UTF8.self))
        #expect(throws: AssistantFailure.self) { try stream.consume("") }
    }

    @Test func completedResponseUsesOnlyServerReportedTokenCount() throws {
        var stream = AssistantCloudStream()
        for (field, expected) in [("42", 42 as Int?), ("null", nil), ("true", nil), ("-1", nil), ("5.5", nil)] {
            let payload = """
            {"type":"response.completed","response":{"status":"completed","usage":{"total_tokens":\(field)},
            "output":[{"type":"message","content":[{"type":"output_text","text":"Hello"}]}]}}
            """
            // В SSE каждую строку JSON предваряет data.
            for line in payload.split(separator: "\n") { _ = try stream.consume("data: " + line) }
            let completion = try #require(stream.consume("").reply)
            #expect(completion.response.message == "Hello")
            #expect(completion.usage.tokens == expected)
        }
        _ = try stream.consume(#"data: {"type":"response.incomplete","response":{"usage":{"total_tokens":42}}}"#)
        #expect(throws: AssistantFailure.self) { try stream.consume("") }
    }

    @Test func usageKeepsHistoryAndUsesLocalDayBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Moscow"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = try #require(calendar.dateInterval(of: .day, for: now))
        var thread = AssistantThread()
        thread.messages = [
            .init(role: .assistant, text: "Old archive entry", createdAt: now),
            .init(role: .assistant, text: "Yesterday", createdAt: day.start - 1, cloudUsage: .init(tokens: 12)),
            .init(role: .assistant, text: "Today", createdAt: day.start, cloudUsage: .init(tokens: 37))
        ]
        thread = try AssistantService.cloudReply(.init(message: "No token report"), to: thread, drafts: [:],
            text: "Request", context: context, edit: nil, usage: .init(tokens: nil))
        thread.messages[3].createdAt = now
        var another = AssistantThread()
        another.messages = [
            .init(role: .assistant, text: "Another chat", createdAt: now, cloudUsage: .init(tokens: 8)),
            .init(role: .assistant, text: "Tomorrow", createdAt: day.end, cloudUsage: .init(tokens: 100))
        ]
        let archive = AssistantArchive(currentID: thread.id, threads: [thread, another])
        let restored = try JSONDecoder().decode(AssistantArchive.self, from: JSONEncoder().encode(archive))
        let totals = restored.cloudUsage(for: thread.id, on: now, calendar: calendar)
        #expect(totals.conversation.requests == 3)
        #expect(totals.conversation.reportedRequests == 2)
        #expect(totals.conversation.tokens == 49)
        #expect(totals.today.requests == 3)
        #expect(totals.today.reportedRequests == 2)
        #expect(totals.today.tokens == 45)
    }

    @Test func structuredReplyKeepsDraftAndEditsSeparate() throws {
        var thread = AssistantThread()
        let old = AssistantAction(proposal: proposal(), context: context)
        thread.actions = [old]
        let before = AssistantTextSnapshot(id: UUID(), title: "Original", description: "Before", checklist: [
            .init(id: UUID(), title: "Completed step", isCompleted: true)
        ])
        let edit = AssistantTextEdit(target: .savedTask, before: before)
        let reply = AssistantResponse(message: "", actions: [proposal()],
            textEdit: .init(description: "After", checklist: ["Completed step", "New step"]))
        let updated = try AssistantService.cloudReply(reply, to: thread, drafts: [:],
            text: "Create a task in folder This Week", context: context, edit: edit)
        #expect(updated.actions.count == 2)
        #expect(updated.actions[0].id == old.id)
        #expect(updated.actions[1].proposal.folderID == "week")
        #expect(updated.actions[1].proposal.checklist == ["Find figures", "Make slides"])
        #expect(updated.actions.allSatisfy { $0.status == .pending && $0.createdTaskID == nil })
        let comparison = try #require(updated.textEdits?.first)
        #expect(comparison.before.description == "Before")
        #expect(comparison.selected.description == "After")
        #expect(comparison.selected.checklist.map(\.title) == ["Completed step", "New step"])
        #expect(comparison.selected.checklist.first?.isCompleted == true)
        #expect(comparison.status == .pending)
    }

    @Test func plainReplyAndClarificationDoNotChangePendingActions() throws {
        var thread = AssistantThread()
        let old = AssistantAction(proposal: proposal(), context: context)
        thread.actions = [old]
        for reply in [AssistantResponse(message: "Yes"),
                      AssistantResponse(message: "Which?", questions: [.init(text: "Which?", options: ["One"])], actions: [proposal()])] {
            let result = try AssistantService.cloudReply(reply, to: thread, drafts: [:], text: "Test", context: context, edit: nil)
            #expect(result.actions.map(\.id) == [old.id])
        }
        #expect(throws: AssistantFailure.self) {
            try AssistantService.cloudReply(.init(message: "", actions: [proposal(key: "draft_99")]),
                to: thread, drafts: [:], text: "Revise the draft", context: context, edit: nil)
        }
        let revised = try AssistantService.cloudReply(.init(message: "", actions: [proposal(key: "draft_1")]),
            to: thread, drafts: ["draft_1": old.id], text: "Revise the draft", context: context, edit: nil)
        #expect(revised.actions.map(\.id) == [old.id])
        #expect(revised.actions.first?.proposal.key == old.proposal.key)
    }

    @Test func pkceAndCallbackValidation() throws {
        #expect(ChatGPTIdentity.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(ChatGPTLoopback.callback("GET /auth/callback?state=wrong&code=a&client_id=oaiapp_test HTTP/1.1",
            expectedState: "right", registeredClientID: nil) == nil)
        #expect(ChatGPTLoopback.callback("GET /auth/callback?state=right&state=right&code=a&client_id=oaiapp_test HTTP/1.1",
            expectedState: "right", registeredClientID: nil) == nil)
        let parsed = try #require(ChatGPTLoopback.callback("GET /auth/callback?state=right&code=a%2Bb&client_id=oaiapp_test HTTP/1.1",
            expectedState: "right", registeredClientID: nil)).get()
        #expect(parsed == .init(code: "a+b", clientID: "oaiapp_test"))
        let wrongAccount = try #require(ChatGPTLoopback.callback("GET /auth/callback?state=right&code=a&client_id=oaiapp_wrong HTTP/1.1",
            expectedState: "right", registeredClientID: "oaiapp_test"))
        #expect(throws: AssistantFailure.self) { try wrongAccount.get() }
    }


    @Test func verifiesSignedIdentityAndRejectsMismatchedClaims() throws {
        // Синтетическая подпись RSA. Ни реальные аккаунты, ни сеть для теста не нужны.
        let token = "eyJhbGciOiJSUzI1NiIsImtpZCI6ImZpeHR1cmUta2V5In0.eyJpc3MiOiJodHRwczovL2F1dGgub3BlbmFpLmNvbSIsImF1ZCI6Im9haWFwcF9mYWtlIiwic3ViIjoiZml4dHVyZS11c2VyIiwiZXhwIjoxODAwMDAwMTAwLCJub25jZSI6ImZpeHR1cmUtbm9uY2UifQ.nJzoQNNx2Ejb6TT-1f3gJHetIVkaJPalB22sZS9e8O863pFjsCA0GSQhZk4E64pV3eOmGeXvuaTZ_KVZAweHkNS1eiq1YpCKzf1D5lHAGUHeRmC_m-t1HH1rjfd319kbOIpNDn5fUY_1XeDfRZIlDQXSv7WaEqajyaQiL1ejE_GM6Q3_WYrLAQ1eyPO9a9VRtfXdvnzmSfBJ5-yv8DpMwwh5sukakRJDWj7V86iAEZApoaRHcdP8Nt-AA3kgnXzm8_SkUPiBpDI2iXQfdH4pTq3Q08Vav9IYw40M3j1a0a0UwDdvxDGNYHu1-l6gvrohU8mRAQSg3oFM0Lr2f0Xvdw"
        let keys = Data(#"{"keys":[{"kid":"fixture-key","kty":"RSA","alg":"RS256","use":"sig","n":"t-k7yaGSZK-PymJYnQe29GI9oMhYFTLIzGG-Nbva1wy3gC_xVuIwd0d-8Lz_u5a3cBd-2bnibikRnqyeNlsX7oL5WWSu2YsIucKMfQvtrbpTqVcZSg1AnQO434JgwG7vfDzzs_P3N7LTk8GoT4fkwJqHmpladM7tJ1NFEv0o1ZeLLCMMtdzjJg3mW5V6rdDe4PbGzcol9CSBvo-rBBAEAv1NZNbjQ-x6il2lqUv10gCKAEBvNnOlnOVdbktYQLkMgGrs__P4fcrqZVgjtiwz8WeWpvnYAr5Zn0knmu7mbA_YqZhcIivrl_EEuwWqfqVXQSK-GU2eLGrwChsVhtVk9w","e":"AQAB"}]}"#.utf8)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = try ChatGPTIdentity.verify(token: token, keys: keys, clientID: "oaiapp_fake", nonce: "fixture-nonce", now: now)
        #expect(identity.sub == "fixture-user")
        #expect(throws: AssistantFailure.self) {
            try ChatGPTIdentity.verify(token: token, keys: keys, clientID: "oaiapp_other", nonce: "fixture-nonce", now: now)
        }
        #expect(throws: AssistantFailure.self) {
            try ChatGPTIdentity.verify(token: token, keys: keys, clientID: "oaiapp_fake", nonce: "different", now: now)
        }
        #expect(throws: AssistantFailure.self) {
            try ChatGPTIdentity.verify(token: token, keys: keys, clientID: "oaiapp_fake", nonce: "fixture-nonce", now: now + 120)
        }
        let parts = token.split(separator: ".")
        let tampered = parts[0] + "." + parts[1] + "." + "AAAA"
        #expect(throws: AssistantFailure.self) {
            try ChatGPTIdentity.verify(token: tampered, keys: keys, clientID: "oaiapp_fake", nonce: "fixture-nonce", now: now)
        }
    }

    @Test func completedNamespacedToolAndPlanLimit() throws {
        var stream = AssistantCloudStream()
        let args = #"{"message":"Review","questions":[],"actions":[{"key":"new_1","kind":"task","title":"Prepare","checklist":["Step"]}],"textEdit":null}"#
        let frame: [String: Any] = ["type": "response.completed", "response": ["status": "completed", "output": [
            ["type": "function_call", "namespace": "planner", "name": "propose_changes", "arguments": args]
        ]]]
        _ = try stream.consume("data: " + String(decoding: JSONSerialization.data(withJSONObject: frame), as: UTF8.self))
        #expect(try stream.consume("").reply?.response.actions?.first?.checklist == ["Step"])
        _ = try stream.consume(#"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#)
        do {
            _ = try stream.consume("")
            Issue.record("Expected usage error")
        } catch let error as ChatGPTHTTPError {
            #expect(error.status == 429)
        }
    }

    @Test func listenerAcceptsLoopbackCallback() async throws {
        let listener = ChatGPTLoopback(state: "expected", registeredClientID: nil, russian: false)
        var response: Task<Int, Error>?
        let grant = try await listener.receive { callback in
            #expect(callback.host() == "127.0.0.1")
            var components = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
            components.queryItems = ["state": "expected", "code": "fake-code", "client_id": "oaiapp_fake"]
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            let url = components.url!
            response = Task {
                let (_, reply) = try await URLSession.shared.data(from: url)
                return (reply as? HTTPURLResponse)?.statusCode ?? 0
            }
            return true
        }
        #expect(grant == .init(code: "fake-code", clientID: "oaiapp_fake"))
        #expect(try await response?.value == 200)
    }
}

extension AssistantCloudTests {
    @Test func gatewaySelectionScopesHistoryToConnectionAndUsesOnlyAttachedText() throws {
        let router = UUID()
        let lite = UUID()
        var thread = AssistantThread()
        thread.messages = [.init(role: .user, text: "private-local-history")]
        thread.actions = [.init(proposal: proposal(), context: context)]
        thread.activeTextEditID = UUID()
        thread.chooseModel(id: "same-slug", gateway: .openRouter, profileID: router)
        #expect(thread.activeTextEditID == nil)
        thread.messages.append(.init(role: .assistant, text: "open-router-history"))
        thread.chooseModel(id: "next-model", gateway: .openRouter, profileID: router)
        #expect(thread.cloud?.historyStart == 1)
        thread.chooseModel(id: "same-slug", gateway: .liteLLM, profileID: lite)
        thread.messages.append(.init(role: .assistant, text: "lite-llm-history"))

        let snapshot = AssistantTextSnapshot(id: UUID(), title: "attached-task-title", description: "attached-task-text", checklist: [])
        let edit = AssistantTextEdit(target: .savedTask, before: snapshot)
        let request = try AssistantCloudRequest(thread: thread, text: "Improve", context: context, edit: edit,
                                               modelID: "same-slug", gateway: .liteLLM)
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let input = String(decoding: request.body, as: UTF8.self)
        #expect(body["model"] as? String == "same-slug")
        #expect((body["messages"] as? [[String: String]])?.first?["role"] == "system")
        #expect(body["tools"] != nil && body["provider"] == nil)
        #expect(input.contains("lite-llm-history") && input.contains("attached-task-text"))
        for privateText in ["private-local-history", "open-router-history", snapshot.id.uuidString, "Private calendar"] {
            #expect(!input.contains(privateText))
        }
        #expect(request.drafts.isEmpty)

        let chat = try AssistantCloudRequest(thread: thread, text: "Hello", context: context, edit: edit,
                                             modelID: "same-slug", gateway: .liteLLM, supportsTools: false)
        #expect(!String(decoding: chat.body, as: UTF8.self).contains("attached-task"))
        #expect((try JSONSerialization.jsonObject(with: chat.body) as? [String: Any])?["tools"] == nil)

        thread.chooseModel(id: "same-slug", gateway: .liteLLM, profileID: UUID())
        #expect(thread.cloud?.historyStart == thread.messages.count)
        thread.chooseModel(id: "chatgpt", accountID: "fake-account")
        #expect(thread.cloud?.gateway == nil && thread.cloud?.gatewayProfileID == nil)
        #expect(thread.cloud?.accountID == "fake-account")
    }

    @Test func gatewayCatalogAndAddresses() throws {
        #expect(AssistantGatewayProfile.liteLLMBase("https://api.example.test/proxy")?.absoluteString == "https://api.example.test/proxy/v1")
        #expect(AssistantGatewayProfile.liteLLMBase("http://127.0.0.1:4000/v1/")?.absoluteString == "http://127.0.0.1:4000/v1")
        #expect(AssistantGatewayProfile.liteLLMBase("http://[::1]:4000")?.absoluteString == "http://[::1]:4000/v1")
        for address in ["http://remote.example.test", "http://localhost.evil.test", "https://a:b@example.test",
                        "https://example.test?key=secret", "https://example.test/#fragment", "https://example.test/a/../b"] {
            #expect(AssistantGatewayProfile.liteLLMBase(address) == nil)
        }
        #expect(!AssistantGatewayHTTP.validKey("fake\r\nInjected: value"))
        let fixture = Data(#"{"data":[{"id":"org/task","name":"Task","supported_parameters":["tools"]},{"id":"org/chat"},{"id":"org/task"},{"id":"org/image","architecture":{"output_modalities":["image"]}}]}"#.utf8)
        let catalog = try JSONDecoder().decode(AssistantGatewayHTTP.Catalog.self, from: fixture)
        let router = catalog.models(for: .openRouter)
        #expect(Set(router.map(\.id)) == ["org/task", "org/chat"])
        #expect(router.first { $0.id == "org/task" }?.reportedTools == true)
        #expect(router.first { $0.id == "org/chat" }?.reportedTools == false)
        let lite = try #require(catalog.models(for: .liteLLM).first { $0.id == "org/chat" })
        var profile = AssistantGatewayProfile(id: UUID(), gateway: .liteLLM,
                                              base: URL(string: "https://example.test/v1")!, key: "fake")
        #expect(!lite.supportsTools(in: profile))
        profile.toolModelIDs.insert(lite.id)
        #expect(lite.supportsTools(in: profile))
    }

    @Test func gatewayStreamWaitsForDoneAndValidatesTools() throws {
        let args = #"{"message":"Review","actions":[{"key":"new_1","kind":"task","title":"Prepare slides","checklist":["Find figures"]}]}"#
        let midpoint = args.index(args.startIndex, offsetBy: 40)
        func chunk(_ function: [String: String]) throws -> Data {
            let tool: [String: Any] = ["index": 0, "type": "function", "function": function]
            let choice: [String: Any] = ["index": 0, "delta": ["tool_calls": [tool]]]
            return try JSONSerialization.data(withJSONObject: ["choices": [choice]])
        }
        let first = try chunk(["name": "propose_changes", "arguments": String(args[..<midpoint])])
        let second = try chunk(["arguments": String(args[midpoint...])])
        var stream = AssistantGatewayStream(tools: true)
        for data in [first, second] {
            _ = try stream.consume("data: " + String(decoding: data, as: UTF8.self))
            #expect(try stream.consume("").reply == nil)
        }
        _ = try stream.consume(#"data: {"choices":[{"index":0,"finish_reason":"tool_calls"}]}"#)
        #expect(try stream.consume("").reply == nil)
        _ = try stream.consume(#"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":"tool_calls"}],"usage":{"total_tokens":28}}"#)
        _ = try stream.consume("")
        _ = try stream.consume("data: [DONE]")
        let reply = try stream.consume("").reply
        #expect(reply?.actions?.first?.checklist == ["Find figures"])
        #expect(stream.tokens == 28)

        var truncated = AssistantGatewayStream(tools: true)
        _ = try truncated.consume("data: [DONE]")
        #expect(throws: AssistantFailure.self) { try truncated.consume("") }
        var chatOnly = AssistantGatewayStream(tools: false)
        _ = try chatOnly.consume("data: " + String(decoding: first, as: UTF8.self))
        #expect(throws: AssistantFailure.self) { try chatOnly.consume("") }

        var chat = AssistantGatewayStream(tools: false)
        _ = try chat.consume(#"data: {"choices":[{"index":0,"delta":{"content":"Hello"}}]}"#)
        #expect(try chat.consume("").delta == "Hello")
        _ = try chat.consume(#"data: {"choices":[{"index":0,"finish_reason":"stop"}]}"#)
        _ = try chat.consume("")
        _ = try chat.consume("data: [DONE]")
        #expect(try chat.consume("").reply?.message == "Hello")
    }

    @Test func openRouterCallbackRequiresTheExactAttemptPath() async throws {
        let path = "/auth/openrouter/fake-nonce"
        #expect(ChatGPTLoopback.openRouterCallback("GET /auth/openrouter/other?code=test&state=expected HTTP/1.1", path: path, expectedState: "expected") == nil)
        #expect(ChatGPTLoopback.openRouterCallback("GET \(path)?code=test&state=other HTTP/1.1", path: path, expectedState: "expected") == nil)
        let duplicate = ChatGPTLoopback.openRouterCallback("GET \(path)?code=a&code=b&state=expected HTTP/1.1", path: path, expectedState: "expected")
        #expect(throws: AssistantFailure.self) { try duplicate?.get() }

        let listener = ChatGPTLoopback(state: "expected", registeredClientID: nil, russian: false, openRouterPath: path)
        var response: Task<Int, Error>?
        let grant = try await listener.receive { callback in
            #expect(callback.host() == "127.0.0.1")
            #expect(callback.path() == path)
            var components = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
            components.queryItems = [.init(name: "code", value: "fake+code="), .init(name: "state", value: "expected")]
            let url = components.url!
            response = Task {
                let (_, reply) = try await URLSession.shared.data(from: url)
                return (reply as? HTTPURLResponse)?.statusCode ?? 0
            }
            return true
        }
        #expect(grant.code == "fake+code=")
        #expect(try await response?.value == 200)
    }
}

extension AssistantCloudTests {
    @Test func directProvidersKeepRequestsOnTheirDocumentedHosts() throws {
        for provider in AssistantGateway.allCases where provider != .liteLLM {
            #expect(!provider.bases.isEmpty)
            for base in provider.bases {
                #expect(provider.permits(base))
                #expect(base.scheme == "https" || provider == .copilot)
                #expect(!provider.permits(base.appending(path: "unexpected")))
            }
            #expect(!provider.permits(URL(string: "https://example.test/v1")!))
        }
        #expect(AssistantGateway.yandex.bases.first?.host() == "ai.api.cloud.yandex.net")
        #expect(AssistantGateway.gigaChat.bases.first?.host() == "api.giga.chat")
        #expect(AssistantGateway.qwen.bases.count == 6)
        #expect(AssistantGatewayConnections.parseModelIDs("glm-5, glm-5,\n glm-4.7") == ["glm-5", "glm-4.7"])
        #expect(AssistantGatewayConnections.parseModelIDs("model with space").isEmpty)
    }

    @Test func directProviderWireFormatsContainOnlyPlannerTools() throws {
        func body(_ provider: AssistantGateway, effort: String? = nil, tools: Bool = true) throws -> [String: Any] {
            let request = try AssistantCloudRequest(thread: AssistantThread(), text: "Create task", context: context,
                                                    edit: nil, modelID: "model", effort: effort,
                                                    gateway: provider, supportsTools: tools)
            return try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        }
        let claude = try body(.claude)
        #expect(claude["system"] != nil && claude["max_tokens"] as? Int == 4096)
        let claudeTools = try #require(claude["tools"] as? [[String: Any]])
        #expect(claudeTools.count == 1 && claudeTools.first?["input_schema"] != nil)
        let schema = try #require(claudeTools.first?["input_schema"] as? [String: Any])
        #expect((schema["required"] as? [String])?.contains("textEdit") == false)
        let deepSeek = try body(.deepSeek, effort: "max")
        #expect(deepSeek["input"] != nil && deepSeek["store"] as? Bool == false)
        #expect((deepSeek["reasoning"] as? [String: String])?["effort"] == "max")
        let miniMax = try body(.miniMaxPlan, effort: "low")
        #expect((miniMax["output_config"] as? [String: String])?["effort"] == "low")
        let giga = try body(.gigaChat)
        #expect(giga["function_call"] as? String == "auto" && giga["tools"] == nil)
        #expect((giga["functions"] as? [[String: Any]])?.first?["name"] as? String == "propose_changes")
        let chatOnly = try body(.gigaChat, tools: false)
        #expect(chatOnly["function_call"] as? String == "none" && chatOnly["functions"] == nil)
        let copilot = try body(.copilot, effort: "medium")
        #expect(copilot["reasoning_effort"] as? String == "medium")
        let yandex = try body(.yandex)
        #expect(yandex["messages"] != nil && yandex["tools"] != nil)
    }

    @Test func providerCatalogsRespectPublishedCapabilities() throws {
        let native = Data(#"{"data":[{"id":"embed","capabilities":{"completion_chat":false}},{"id":"mistral-small-latest","capabilities":{"completion_chat":true,"function_calling":true}},{"id":"deepseek-v4-pro","name":"DeepSeek","input_modalities":["text"],"output_modalities":["text"],"effort":{"supported_levels":["low","high","max"]}}]}"#.utf8)
        let catalog = try JSONDecoder().decode(AssistantGatewayHTTP.Catalog.self, from: native)
        #expect(!catalog.models(for: .mistral).contains { $0.id == "embed" })
        #expect(catalog.models(for: .mistral).first { $0.id == "mistral-small-latest" }?.reportedTools == true)
        #expect(catalog.models(for: .deepSeek).first { $0.id == "deepseek-v4-pro" }?.efforts == ["low", "high", "max"])
        let google = Data(#"{"models":[{"name":"models/gemini-3-flash","displayName":"Gemini Flash","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-3-image","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-embedding","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"next"}"#.utf8)
        let gemini = try JSONDecoder().decode(AssistantGatewayHTTP.GeminiCatalog.self, from: google)
        #expect(gemini.chatModels.map(\.id) == ["gemini-3-flash"])
        #expect(gemini.nextPageToken == "next")
        let xai = Data(#"{"models":[{"id":"grok-4.3","aliases":["Grok 4.3"],"input_modalities":["text","image"],"output_modalities":["text"]}]}"#.utf8)
        let grok = try JSONDecoder().decode(AssistantGatewayHTTP.Catalog.self, from: xai).models(for: .grok)
        #expect(grok.first?.name == "Grok 4.3")
        #expect(grok.first?.reportedTools == true)
    }

    @Test func anthropicToolRequiresTerminalMessageStop() throws {
        var stream = AssistantMessagesStream(tools: true)
        func frame(_ data: String) throws -> AssistantCloudCompletion? {
            _ = try stream.consume("data: " + data)
            return try stream.consume("").reply
        }
        #expect(try frame(#"{"type":"message_start","message":{"usage":{"input_tokens":12,"output_tokens":0}}}"#) == nil)
        #expect(try frame(#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","name":"propose_changes","input":{}}}"#) == nil)
        let arguments = #"{"message":"Review","textEdit":{"description":"Improved description"}}"#
        let frameObject: [String: Any] = ["type": "content_block_delta", "index": 1,
            "delta": ["type": "input_json_delta", "partial_json": arguments]]
        #expect(try frame(String(decoding: JSONSerialization.data(withJSONObject: frameObject), as: UTF8.self)) == nil)
        #expect(try frame(#"{"type":"content_block_stop","index":1}"#) == nil)
        #expect(try frame(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":8}}"#) == nil)
        let completed = try frame(#"{"type":"message_stop"}"#)
        let reply = try #require(completed)
        #expect(reply.response.textEdit?.description == "Improved description")
        #expect(reply.usage.tokens == 20)
    }

    @Test func gigaChatAndGLMAcceptDocumentedObjectArguments() throws {
        var giga = AssistantGatewayStream(tools: true, legacyFunctions: true)
        _ = try giga.consume(#"data: {"choices":[{"index":0,"delta":{"content":"","function_call":{"name":"propose_changes","arguments":{"message":"Review","actions":[{"key":"new_1","kind":"task","title":"Prepare slides"}]}}},"finish_reason":"function_call"}],"usage":{"total_tokens":28}}"#)
        #expect(try giga.consume("").reply == nil)
        _ = try giga.consume("data: [DONE]")
        #expect(try giga.consume("").reply?.actions?.first?.title == "Prepare slides")

        var glm = AssistantGatewayStream(tools: true, objectArguments: true)
        _ = try glm.consume(#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"type":"function","function":{"name":"propose_changes","arguments":{"message":"Review","textEdit":{"description":"Better"}}}}]},"finish_reason":"tool_calls"}]}"#)
        #expect(try glm.consume("").reply == nil)
        _ = try glm.consume("data: [DONE]")
        #expect(try glm.consume("").reply?.textEdit?.description == "Better")
    }
}
