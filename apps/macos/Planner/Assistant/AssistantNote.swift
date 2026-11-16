import Foundation

struct AssistantAttachedNote {
    let id: UUID
    let title: String
    let body: String
    let version: String
    var context: AssistantNoteContext { .init(title: title, text: body) }

    init(_ note: PlannerNote) {
        id = note.id
        title = note.title
        body = note.text.replacingOccurrences(of: "\u{FFFC}", with: "")
        version = note.assistantContentVersion
    }
}

struct AssistantNoteProposal: Codable, Identifiable {
    var id = UUID()
    let noteID: UUID
    let title: String
    let version: String
    let body: String
    var applied = false
}

extension AssistantService {
    @discardableResult func attachNote(_ id: UUID?) -> Bool {
        guard !generating, !applying, !storageFailed, let index = currentIndex else { return false }
        let previous = archive.threads[index]
        guard previous.attachedNoteID != id else { return true }
        archive.threads[index].attachedNoteID = id
        if id != nil {
            archive.threads[index].activeTextEditID = nil
            archive.threads[index].focusedDraftID = nil
            archive.threads[index].focusedEventID = nil
        }
        if persist() { return true }
        archive.threads[index] = previous
        return false
    }

    func applyNoteProposal(_ id: UUID, notes: NoteStore, append: Bool) {
        guard !generating, !applying, !storageFailed, let index = currentIndex,
              let proposal = archive.threads[index].noteProposal, proposal.id == id, !proposal.applied else { return }
        applying = true
        error = nil
        defer { applying = false }
        do {
            try notes.applyText(proposal.body, to: proposal.noteID, append: append, expectedVersion: proposal.version)
            // Проверка версии защищает от повторной вставки, даже если история не сохранилась.
            archive.threads[index].noteProposal?.applied = true
            _ = persist()
        } catch {
            self.error = (error as? AssistantFailure)?.message ?? "Не удалось сохранить текст заметки."
        }
    }
}
