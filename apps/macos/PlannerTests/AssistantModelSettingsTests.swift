import AppKit
import Testing
@testable import Planner

@MainActor struct AssistantModelSettingsTests {
    @Test func priorPreferencesKeepOnlyExplicitSelectionsPerProvider() throws {
        let data = Data(#"{"chat":{"openRouter":["hidden"]},"transcription":{},"knownSources":["openRouter"],"choices":{"openRouter":{"picked":true,"removed":false}}}"#.utf8)
        var visibility = try JSONDecoder().decode(AssistantModelVisibility.self, from: data)
        let chosen = AssistantCatalogModel(gateway: .openRouter, modelID: "picked", name: "Selected", supportsChat: true)
        #expect(visibility.includes(chosen))
        for id in ["hidden", "removed", "new"] {
            #expect(!visibility.includes(.init(gateway: .openRouter, modelID: id)))
        }
        #expect(!visibility.includes(.init(gateway: .liteLLM, modelID: "picked")))
        visibility.setIncluded(false, model: chosen)
        #expect(!visibility.includes(chosen))
        let old = try JSONDecoder().decode(AssistantModelVisibility.self, from: Data(#"{"chat":{},"transcription":{}}"#.utf8))
        #expect(!old.includes(chosen))
    }

    @Test func chatMenuShowsOnlyChosenChatCapableModelsAcrossRestarts() throws {
        let fixture = try ModelSettingsFixture()
        defer { fixture.close() }
        let suite = "assistant.model-settings.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let service = fixture.assistant
        let profile = try #require(fixture.gateways.profiles[.liteLLM])
        let speech = AssistantTranscriptionSelection(gateway: .liteLLM, profileID: profile.id, modelID: "audio", name: "Speech")
        preferences.manualSpeechModels = [speech]
        preferences.transcriptionModel = speech
        #expect(service.chatMenuModels(preferences: preferences).isEmpty)
        let catalog = service.modelCatalog(preferences: preferences)
        for model in catalog where ["second", "audio"].contains(model.modelID) {
            preferences.assistantModelVisibility.setIncluded(true, model: model)
        }
        let reopened = AppPreferences(defaults: defaults)
        #expect(service.chatMenuModels(preferences: reopened).map(\.modelID) == ["second"])
        #expect(reopened.transcriptionModel == speech)
    }

    @Test func logoIdentifiesTheModelCompanyAcrossConnections() {
        func logo(_ gateway: AssistantGateway?, _ id: String) -> String? {
            AssistantCatalogModel(gateway: gateway, modelID: id, name: id).brandLogo
        }
        #expect(logo(nil, "gpt-test") == "ChatGPTLogo")
        #expect(logo(.openRouter, "anthropic/claude-test") == logo(.claude, "claude-test"))
        #expect(logo(.copilot, "gemini-test") == logo(.gemini, "gemini-test"))
        #expect(logo(.liteLLM, "qwen3.5-test") == logo(.qwen, "qwen-test"))
        #expect(logo(.liteLLM, "private-alias") == nil)
        #expect(logo(.openRouter, "unlisted/claude-alias") == nil)
        for gateway in AssistantGateway.allCases {
            if let asset = logo(gateway, "test") { #expect(NSImage(named: asset) != nil) }
        }
        #expect(NSImage(named: "ChatGPTLogo") != nil)
    }

    @Test func malformedDisplayPreferencesDoNotDiscardTheTranscriptionSelection() throws {
        let suite = "assistant.model-settings.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.transcriptionModel = .init(gateway: .openAI, profileID: UUID(), modelID: "whisper-1", name: "Whisper")
        defaults.set(Data("invalid json".utf8), forKey: "assistantModelVisibility")
        let restored = AppPreferences(defaults: defaults)
        #expect(restored.assistantModelVisibility == AssistantModelVisibility())
        #expect(restored.transcriptionModel == preferences.transcriptionModel)
    }

    @Test func chatSelectionIsSharedPersistsAndIsInheritedByANewConversation() throws {
        let fixture = try ModelSettingsFixture()
        defer { fixture.close() }
        let assistant = fixture.assistant
        assistant.selectGatewayModel("first", gateway: .liteLLM)
        #expect(assistant.cloudModelName == "First model")
        let firstConversation = try #require(assistant.current?.id)
        assistant.selectGatewayModel("second", gateway: .liteLLM)
        #expect(assistant.current?.cloud?.modelID == "second")
        #expect(assistant.cloudModelName == "Second model")
        assistant.newConversation()
        #expect(assistant.current?.cloud?.modelID == "second")
        assistant.selectGatewayModel("first", gateway: .liteLLM)
        assistant.selectConversation(firstConversation)
        #expect(assistant.cloudModelName == "Second model")
        let restored = AssistantService(store: fixture.store, gateways: fixture.gateways)
        #expect(restored.current?.id == firstConversation)
        #expect(restored.current?.cloud?.modelID == "second")
    }

    @Test func removingCurrentChatModelKeepsDraftAndRequiresAnExplicitReplacement() throws {
        let fixture = try ModelSettingsFixture()
        defer { fixture.close() }
        let assistant = fixture.assistant
        let first = AssistantCatalogModel(gateway: .liteLLM, modelID: "first", name: "First model", supportsChat: true)
        let second = AssistantCatalogModel(gateway: .liteLLM, modelID: "second", name: "Second model", supportsChat: true)
        var visibility = AssistantModelVisibility()
        visibility.setIncluded(true, model: first)
        visibility.setIncluded(true, model: second)
        assistant.selectChatModel(first, visibility: visibility)
        assistant.setDraft("Unsent text")
        #expect(assistant.canSendCloud(using: visibility))

        visibility.setIncluded(false, model: first)
        #expect(assistant.selectedChatModelID(in: visibility) == nil)
        #expect(!assistant.canSendCloud(using: visibility))
        let context = AssistantContext(now: .now, timeZoneID: "UTC", language: "en", folders: [], calendars: [],
            defaultFolderID: "inbox", durationMinutes: 30)
        assistant.sendCloud("Unsent text", context: context, visibility: visibility, tasks: nil)
        #expect(assistant.error == "Выберите модель чата перед отправкой сообщения.")
        #expect(assistant.current?.messages.isEmpty == true && assistant.current?.draft == "Unsent text")
        #expect(!assistant.generating)
        assistant.selectChatModel(second, visibility: visibility)
        assistant.selectChatModel(first, visibility: visibility)
        #expect(assistant.selectedChatModelID(in: visibility) == second.id)
        #expect(assistant.canSendCloud(using: visibility) && assistant.error == nil)
    }

    @Test func modelSelectionRemainsLockedDuringGenerationAndRejectsUnknownModels() throws {
        let fixture = try ModelSettingsFixture()
        defer { fixture.close() }
        fixture.assistant.selectGatewayModel("first", gateway: .liteLLM)
        fixture.assistant.generating = true
        fixture.assistant.selectGatewayModel("second", gateway: .liteLLM)
        #expect(fixture.assistant.current?.cloud?.modelID == "first")
        fixture.assistant.generating = false
        fixture.assistant.selectGatewayModel("unknown", gateway: .liteLLM)
        #expect(fixture.assistant.current?.cloud?.modelID == "first")
    }
}

@MainActor private final class ModelSettingsFixture {
    let directory: URL
    let store: AssistantStore
    let gateways: AssistantGatewayConnections
    let assistant: AssistantService
    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "AssistantModelSettings-\(UUID())", directoryHint: .isDirectory)
        store = AssistantStore(url: directory.appending(path: "history.json"))
        let profile = AssistantGatewayProfile(id: UUID(), gateway: .liteLLM,
            base: try #require(AssistantGatewayProfile.liteLLMBase("http://localhost:4000")), key: "fixture")
        gateways = AssistantGatewayConnections(profiles: [.liteLLM: profile], catalogs: [.liteLLM: [
            .init(id: "first", name: "First model", reportedTools: true),
            .init(id: "second", name: "Second model", reportedTools: true)
        ]])
        assistant = AssistantService(store: store, gateways: gateways)
    }
    func close() { try? FileManager.default.removeItem(at: directory) }
}
