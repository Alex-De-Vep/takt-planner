import Foundation
import Testing
@testable import Planner

@MainActor struct AssistantModelSettingsTests {
    @Test func visibilityStartsWithAllModelsAndSeparatesProvidersAndPurposes() {
        var visibility = AssistantModelVisibility()
        #expect(visibility.isVisible("shared", gateway: .openRouter, purpose: .chat))
        visibility.setVisible(false, modelID: "shared", gateway: .openRouter, purpose: .chat)
        #expect(!visibility.isVisible("shared", gateway: .openRouter, purpose: .chat))
        #expect(visibility.isVisible("shared", gateway: .openRouter, purpose: .transcription))
        #expect(visibility.isVisible("shared", gateway: .liteLLM, purpose: .chat))
        #expect(visibility.isVisible("shared", gateway: nil, purpose: .chat))
        #expect(visibility.isVisible("new-model", gateway: .openRouter, purpose: .chat))
        visibility.setVisible(true, modelID: "shared", gateway: .openRouter, purpose: .chat)
        #expect(visibility == AssistantModelVisibility())
    }

    @Test func sharedChoicesMergePreviousListsAndKeepSelectionsWhenReconnecting() throws {
        var visibility = AssistantModelVisibility()
        let audio = AssistantTranscriptionSelection(gateway: .gemini, profileID: UUID(), modelID: "same", name: "Speech")
        let dual = AssistantCatalogModel(gateway: .gemini, modelID: "same", name: "Dual", supportsChat: true, speech: audio)
        visibility.setVisible(false, modelID: "same", gateway: .gemini, purpose: .chat)
        visibility = try JSONDecoder().decode(AssistantModelVisibility.self, from: JSONEncoder().encode(visibility))
        #expect(visibility.includes(dual))

        visibility.setIncluded(false, model: dual)
        #expect(!visibility.includes(dual))
        visibility.setIncluded(true, model: dual)
        #expect(visibility.includes(dual))

        visibility.startWithEmptyList(gateway: .liteLLM)
        let other = AssistantCatalogModel(gateway: .liteLLM, modelID: "same", name: "Other", supportsChat: true)
        #expect(!visibility.includes(other))
        visibility.setIncluded(true, model: other)
        visibility.startWithEmptyList(gateway: .liteLLM)
        #expect(visibility.includes(other))
    }

    @Test func displayListsAndTranscriptionChoiceSurviveRestartIndependently() throws {
        let suite = "assistant.model-settings.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let selected = AssistantTranscriptionSelection(gateway: .liteLLM, profileID: UUID(), modelID: "audio", name: "Speech")
        preferences.transcriptionModel = selected
        preferences.assistantModelVisibility.setVisible(false, modelID: "chat", gateway: nil, purpose: .chat)
        preferences.assistantModelVisibility.setVisible(false, modelID: "audio", gateway: .liteLLM, purpose: .transcription)

        let restored = AppPreferences(defaults: defaults)
        #expect(!restored.assistantModelVisibility.isVisible("chat", gateway: nil, purpose: .chat))
        #expect(!restored.assistantModelVisibility.isVisible("audio", gateway: .liteLLM, purpose: .transcription))
        #expect(restored.assistantModelVisibility.isVisible("audio", gateway: .liteLLM, purpose: .chat))
        #expect(restored.transcriptionModel == selected)
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

    @Test func hidingTheActiveModelDoesNotChangeChatOrSpeechSelections() throws {
        let fixture = try ModelSettingsFixture()
        defer { fixture.close() }
        let suite = "assistant.model-settings.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        fixture.assistant.selectGatewayModel("first", gateway: .liteLLM)
        preferences.transcriptionModel = .init(gateway: .liteLLM, profileID: UUID(), modelID: "speech", name: "Speech")
        preferences.assistantModelVisibility.setVisible(false, modelID: "first", gateway: .liteLLM, purpose: .chat)
        preferences.assistantModelVisibility.setVisible(false, modelID: "speech", gateway: .liteLLM, purpose: .transcription)
        #expect(fixture.assistant.cloudModelName == "First model")
        #expect(fixture.assistant.canSendCloud)
        #expect(preferences.transcriptionModel?.modelID == "speech")
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
