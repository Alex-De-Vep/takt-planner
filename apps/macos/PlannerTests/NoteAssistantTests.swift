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

    @Test func transcriptionSelectionSurvivesNewPreferencesInstance() throws {
        let suite = "note.transcription.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let choice = AssistantTranscriptionSelection(gateway: .openRouter, profileID: UUID(), modelID: "example/audio", name: "Speech")
        let preferences = AppPreferences(defaults: defaults)
        preferences.transcriptionModel = choice
        #expect(AppPreferences(defaults: defaults).transcriptionModel == choice)
    }
}
