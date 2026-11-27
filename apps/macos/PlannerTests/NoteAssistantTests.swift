import AppKit
import AVFoundation
import SwiftUI
import Synchronization
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

    @Test func longRecordingIsRetriedFromTheMissingPartAndSavedInOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = NoteStore()
        let note = try #require(store.create(folder: "inbox"))
        let recordingID = UUID()
        let source = directory.appending(path: "\(note).voice.\(recordingID).m4a")
        let writer = try NoteCallAudio(url: source)
        let second = Data(repeating: 0, count: NoteCallAudio.sampleRate * 4)
        for _ in 0...300 { _ = try writer.append(second) }
        writer.close()

        let voice = NoteVoiceRecording(directory: directory)
        voice.restoreDrafts(for: store.notes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoteSpeechFixture.self]
        let http = AssistantGatewayHTTP(configuration: configuration)
        let profile = AssistantGatewayProfile(id: UUID(), gateway: .openAI,
            base: try #require(AssistantGateway.openAI.bases.first), key: "long-recording-fixture")

        await voice.transcribe(recordingID, store: store, profile: profile, modelID: "whisper-1", transport: http)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(voice.transcriptionIssues[recordingID]?.part == 2)
        #expect(voice.transcriptionIssues[recordingID]?.interval.hasPrefix("05:00–") == true)
        #expect(voice.transcriptionIssues[recordingID]?.code == "HTTP 400")
        #expect(voice.drafts[recordingID]?.checkpoint?.parts.map(\.text) == ["First part", nil])
        #expect(store.notes.first?.text.isEmpty == true)

        let restored = NoteVoiceRecording(directory: directory)
        restored.restoreDrafts(for: store.notes)
        await restored.transcribe(recordingID, store: store, profile: profile, modelID: "whisper-1", transport: http)
        #expect(restored.errors[recordingID] == nil)
        #expect(restored.transcriptPreviews.first?.text == "First part\n\nLast part")
        #expect(store.notes.first?.text.isEmpty == true)
        restored.dismissTranscript(recordingID)
        let reopened = NoteVoiceRecording(directory: directory)
        reopened.restoreDrafts(for: store.notes)
        #expect(reopened.transcriptPreviews.isEmpty)
        reopened.presentTranscript(recordingID, strings: .init(language: .russian))
        reopened.presentTranscript(recordingID, strings: .init(language: .russian))
        #expect(reopened.transcriptPreviews.count == 1)
        store.edit(note, content: NSAttributedString(string: "Edited while reviewing"))
        try reopened.insertTranscript(recordingID, store: store)
        reopened.presentTranscript(recordingID, strings: .init(language: .russian))
        #expect(reopened.transcriptPreviews.isEmpty)
        #expect(reopened.drafts[recordingID]?.saved == true)
        #expect(store.notes.first?.text == "Edited while reviewing\n\nFirst part\n\nLast part")
        #expect(NoteSpeechFixture.longRecordingRequests.withLock { $0 } == 3)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func gigaChatRetriesSplitsAndKeepsAnExplicitEmptyResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore()
        let note = try #require(store.create(folder: "inbox"))
        let recordingID = UUID()
        let source = directory.appending(path: "\(note).call.\(recordingID).m4a")
        let writer = try NoteCallAudio(url: source)
        let second = Data(repeating: 0, count: NoteCallAudio.sampleRate * 4)
        for _ in 0..<12 { _ = try writer.append(second) }
        writer.close()

        let voice = NoteVoiceRecording(directory: directory)
        voice.restoreDrafts(for: store.notes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoteSpeechFixture.self]
        let http = AssistantGatewayHTTP(configuration: configuration)
        let profile = AssistantGatewayProfile(id: UUID(), gateway: .gigaChat,
            base: try #require(AssistantGateway.gigaChat.bases.first), key: "split-fixture")

        await voice.transcribe(recordingID, store: store, profile: profile, modelID: "GigaChat-2-Max", transport: http)

        #expect(voice.transcriptionIssues[recordingID] == nil)
        #expect(voice.errors[recordingID] == "Не удалось удалить загруженный файл из GigaChat.")
        #expect(store.notes.first?.text.isEmpty == true)
        #expect(voice.transcriptPreviews.first?.noteID == note)
        try voice.insertTranscript(recordingID, store: store)
        #expect(store.notes.first?.text == "Short first part\n\n[Пустая расшифровка · 00:06–00:12]")
        #expect(NoteSpeechFixture.splitRequests.withLock { $0 } == 4)
        #expect(NoteSpeechFixture.splitCleanupRequests.withLock { $0 } == 4)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func failedSegmentCanBeSkippedBeforeExplicitPartialSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore()
        let note = try #require(store.create(folder: "inbox"))
        let recordingID = UUID()
        let source = directory.appending(path: "\(note).voice.\(recordingID).m4a")
        let writer = try NoteCallAudio(url: source)
        _ = try writer.append(Data(repeating: 0, count: NoteCallAudio.sampleRate * 4))
        writer.close()

        let voice = NoteVoiceRecording(directory: directory)
        voice.restoreDrafts(for: store.notes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoteSpeechFixture.self]
        let http = AssistantGatewayHTTP(configuration: configuration)
        let profile = AssistantGatewayProfile(id: UUID(), gateway: .openAI,
            base: try #require(AssistantGateway.openAI.bases.first), key: "malformed-fixture")

        await voice.transcribe(recordingID, store: store, profile: profile, modelID: "whisper-1", transport: http)
        #expect(voice.transcriptionIssues[recordingID]?.code == "invalid_response")
        #expect(voice.skipFailedPart(recordingID))
        await voice.transcribe(recordingID, store: store, profile: profile, modelID: "whisper-1", transport: http)
        #expect(voice.transcriptPreviews.first?.isPartial == true)
        #expect(store.notes.first?.text.isEmpty == true)

        #expect(store.moveToTrash(note))
        #expect(throws: AssistantFailure.self) { try voice.insertTranscript(recordingID, store: store) }
        #expect(voice.transcriptPreviews.first?.id == recordingID)
        store.restoreFromTrash(note)
        try voice.insertTranscript(recordingID, store: store)
        #expect(store.notes.first?.text == "[Фрагмент пропущен · 00:00–00:01]")
        #expect(FileManager.default.fileExists(atPath: source.path))
        let restored = NoteVoiceRecording(directory: directory)
        restored.restoreDrafts(for: store.notes)
        #expect(restored.drafts[recordingID]?.saved == true)
    }

    @Test(arguments: [false, true])
    func insertedTranscriptIsVisibleInAnExistingOrNewEditor(openAfterInsertion: Bool) async throws {
        let store = NoteStore()
        let id = try #require(store.create(folder: "inbox"))
        let original = String(repeating: "Long note 👩🏽‍💻\n", count: 180)
        try store.applyText(original, to: id, append: false)
        let note = try #require(store.notes.first)
        let control = NoteEditorControl()
        let transcript = String(repeating: "Recognized speech\n", count: 70)
        func insert() throws { try store.applyText(transcript, to: id, append: true, voiceTranscriptID: UUID()) }
        if openAfterInsertion { try insert() }
        let host = NSHostingView(rootView: NoteRichTextEditor(note: note, store: store, control: control))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 230),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        if !openAfterInsertion {
            try await Task.sleep(for: .milliseconds(60))
            try insert()
        }
        let start = (original as NSString).length + 2
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            if control.view?.selectedRange().location == start { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let view = try #require(control.view)
        #expect(view.string == original + "\n\n" + transcript)
        let caret = NSRange(location: start, length: 0)
        #expect(view.selectedRange() == caret)
        let line = view.convert(window.convertFromScreen(view.firstRect(forCharacterRange: caret, actualRange: nil)), from: nil)
        #expect(view.visibleRect.intersects(line.insetBy(dx: -1, dy: 0)))
        let nextParagraph = NSRange(location: start + ("Recognized speech\n" as NSString).length, length: 0)
        let secondLine = view.convert(window.convertFromScreen(view.firstRect(forCharacterRange: nextParagraph, actualRange: nil)), from: nil)
        #expect(view.visibleRect.intersects(secondLine.insetBy(dx: -1, dy: 0)))
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
    static let longRecordingRequests = Mutex(0)
    static let splitRequests = Mutex(0)
    static let splitCleanupRequests = Mutex(0)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        let payload: String?
        var status: Int?
        var headers = ["Content-Type": "application/json"]
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
        case ("ngw.devices.sberbank.ru", "/api/v2/oauth", "POST", "Basic split-fixture"):
            payload = #"{"access_token":"split-token","expires_at":4102444800}"#
        case ("api.giga.chat", "/v1/files", "POST", "Bearer split-token"):
            payload = #"{"id":"split-file"}"#
        case ("api.giga.chat", "/v1/chat/completions", "POST", "Bearer split-token"):
            let requestNumber = Self.splitRequests.withLock { count in
                count += 1
                return count
            }
            switch requestNumber {
            case 1:
                status = 429
                headers["Retry-After"] = "0"
                payload = nil
            case 2: payload = #"{"choices":[{"finish_reason":"length"}]}"#
            case 3: payload = #"{"choices":[{"message":{"content":"Short first part"},"finish_reason":"stop"}]}"#
            default: payload = #"{"choices":[{"message":{"content":null},"finish_reason":"stop"}]}"#
            }
        case ("api.giga.chat", "/v1/files/split-file/delete", "POST", "Bearer split-token"):
            Self.splitCleanupRequests.withLock { $0 += 1 }
            if Self.splitRequests.withLock({ $0 }) == 2 { status = 500 }
            payload = ""
        case ("api.openai.com", "/v1/audio/transcriptions", "POST", "Bearer malformed-fixture"):
            payload = #"{"unexpected":"This is not a transcription"}"#
        case ("api.openai.com", "/v1/models", "GET", "Bearer fixture"):
            payload = #"{"data":[{"id":"gpt-transcribe"},{"id":"gpt-4o"}]}"#
        case ("api.openai.com", "/v1/audio/transcriptions", "POST", "Bearer long-recording-fixture"):
            let requestNumber = Self.longRecordingRequests.withLock { count in
                count += 1
                return count
            }
            switch requestNumber {
            case 1: payload = #"{"text":"First part"}"#
            case 3: payload = #"{"text":"Last part"}"#
            default: payload = nil
            }
        case ("api.openai.com", "/v1/audio/transcriptions", "POST", "Bearer fixture"):
            payload = #"{"text":"OpenAI transcript"}"#
        default: payload = nil
        }
        let response = HTTPURLResponse(url: url, statusCode: status ?? (payload == nil ? 400 : 200),
                                      httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let payload, !payload.isEmpty { client?.urlProtocol(self, didLoad: Data(payload.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
