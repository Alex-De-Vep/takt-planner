import AppKit
import Testing
@testable import Planner

@MainActor struct NoteAssistantTests {
    @Test func attachingOneNoteAndApplyingItsProposalDoesNotTouchAnotherNote() throws {
        let notes = NoteStore()
        let first = try #require(notes.create(folder: "inbox"))
        let second = try #require(notes.create(folder: "week"))
        try notes.applyText("Исходная заметка", to: first, append: true)
        try notes.applyText("Другая заметка", to: second, append: true)
        let original = AssistantAttachedNote(try #require(notes.notes.first { $0.id == first }))

        let url = FileManager.default.temporaryDirectory.appending(path: "NoteAssistant-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let assistant = AssistantService(store: AssistantStore(url: url))
        #expect(assistant.attachNote(first))
        let index = try #require(assistant.currentIndex)
        let snapshot = assistant.archive.threads[index]
        let proposal = AssistantNoteProposal(noteID: original.id, title: original.title, version: original.version, body: "Готовый итог")
        assistant.archive.threads[index].noteProposal = proposal
        #expect(snapshot.attachedNoteID == first)

        #expect(assistant.attachNote(second))
        assistant.applyNoteProposal(proposal.id, notes: notes, append: true)
        assistant.applyNoteProposal(proposal.id, notes: notes, append: true)
        #expect(notes.notes.first { $0.id == first }?.text == "Исходная заметка\n\nГотовый итог")
        #expect(notes.notes.first { $0.id == second }?.text == "Другая заметка")
        let reopened = AssistantService(store: AssistantStore(url: url))
        #expect(reopened.current?.attachedNoteID == second)
        #expect(reopened.current?.noteProposal?.applied == true)
    }

    @Test func rejectsProposalForOlderTextIncludingUnsavedEditorInput() throws {
        let notes = NoteStore()
        let id = try #require(notes.create(folder: "inbox"))
        try notes.applyText("Оригинал", to: id, append: true)
        let version = try #require(notes.notes.first?.assistantContentVersion)
        notes.edit(id, content: NSAttributedString(string: "Текст, который ещё вводят"))
        #expect(throws: AssistantFailure.self) {
            try notes.applyText("Устаревший результат", to: id, append: false, expectedVersion: version)
        }
        #expect(notes.notes.first?.text == "Текст, который ещё вводят")
    }

    @Test func cloudRequestIncludesTheEntireNoteButKeepsItsIdentifierLocal() throws {
        var local = PlannerNote()
        local.title = "Project notes"
        local.text = String(repeating: "Milestone ", count: 460) + "End of the note"
        let note = AssistantAttachedNote(local)
        let context = AssistantContext(now: .now, timeZoneID: "UTC", language: "en", folders: [], calendars: [],
                                       defaultFolderID: "inbox", durationMinutes: 60)
        let input = try AssistantCloudRequest(thread: AssistantThread(), text: "Rewrite the note", context: context,
                                              edit: nil, modelID: "test", gateway: .openRouter, note: note.context)
        let body = String(decoding: input.body, as: UTF8.self)
        #expect(body.contains(note.body))
        #expect(body.contains("noteEdit"))
        #expect(!body.contains(note.id.uuidString))
    }

    @Test func speechCatalogAndUploadsUseTheirOwnProviders() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoteSpeechFixture.self]
        let http = AssistantGatewayHTTP(configuration: configuration)
        let gigaChat = AssistantGatewayProfile(id: UUID(), gateway: .gigaChat,
            base: try #require(AssistantGateway.gigaChat.bases.first), key: "fixture")
        let openAI = AssistantGatewayProfile(id: UUID(), gateway: .openAI,
            base: try #require(AssistantGateway.openAI.bases.first), key: "fixture")

        #expect(try await http.transcriptionModels(gigaChat).map(\.id) == ["GigaChat-2-Max"])
        #expect(try await http.transcriptionModels(openAI).map(\.id) == ["gpt-transcribe"])
        #expect(try await http.models(openAI).isEmpty)

        let audio = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        try Data("fixture audio".utf8).write(to: audio)
        let gigaResult = try await http.transcribe(audio, profile: gigaChat, modelID: "GigaChat-2-Max")
        #expect(gigaResult.text == "Текст GigaChat")
        #expect(!gigaResult.remoteCleanupFailed)
        #expect(try await http.transcribe(audio, profile: openAI, modelID: "gpt-transcribe").text == "OpenAI transcript")
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func transcriptionSelectionSurvivesNewPreferencesInstance() throws {
        let suite = "note.transcription.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let choice = AssistantTranscriptionSelection(gateway: .openRouter, profileID: UUID(), modelID: "example/audio", name: "Speech")
        let preferences = AppPreferences(defaults: defaults)
        preferences.transcriptionModel = choice
        let reloaded = AppPreferences(defaults: defaults)
        #expect(reloaded.transcriptionModel == choice)
    }
}


private final class NoteSpeechFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        let payload: String?
        switch (url.host(), url.path, request.httpMethod, authorization) {
        case ("ngw.devices.sberbank.ru", "/api/v2/oauth", "POST", "Basic fixture"):
            payload = #"{"access_token":"test-token","expires_at":4102444800}"#
        case ("api.giga.chat", "/v1/models", "GET", "Bearer test-token"):
            payload = #"{"data":[{"id":"GigaChat-2-Max"},{"id":"GigaChat-Embeddings"}]}"#
        case ("api.giga.chat", "/v1/files", "POST", "Bearer test-token"):
            payload = #"{"id":"uploaded-fixture"}"#
        case ("api.giga.chat", "/v1/chat/completions", "POST", "Bearer test-token"):
            payload = #"{"choices":[{"message":{"content":"Текст GigaChat"},"finish_reason":"stop"}]}"#
        case ("api.giga.chat", "/v1/files/uploaded-fixture/delete", "POST", "Bearer test-token"):
            payload = ""
        case ("api.openai.com", "/v1/models", "GET", "Bearer fixture"):
            payload = #"{"data":[{"id":"gpt-transcribe"},{"id":"gpt-4o"}]}"#
        case ("api.openai.com", "/v1/audio/transcriptions", "POST", "Bearer fixture"):
            payload = #"{"text":"OpenAI transcript"}"#
        default: payload = nil
        }
        let response = HTTPURLResponse(url: url, statusCode: payload == nil ? 400 : 200,
                                      httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let payload, !payload.isEmpty { client?.urlProtocol(self, didLoad: Data(payload.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
