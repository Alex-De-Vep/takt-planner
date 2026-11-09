import Foundation
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
