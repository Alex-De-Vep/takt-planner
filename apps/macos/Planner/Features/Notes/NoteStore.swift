import AppKit
import CryptoKit
import Observation

struct NoteSyncVersion: Codable, Equatable, Sendable {
    let revision: String
    let localDigest: String
}

struct PlannerNote: Codable, Identifiable, Sendable {
    var id = UUID()
    var title = ""
    var folder = "inbox"
    var document = Data()
    var text = ""
    var pinned = false
    var createdAt = Date()
    var updatedAt = Date()
    var deletedAt: Date?
    var syncVersion: NoteSyncVersion?
    var lastVoiceTranscriptID: UUID?
    var appliedVoiceTranscriptIDs: Set<UUID>?
    var richText: SharedNoteText?
    var purged: Bool?

    func hasVoiceTranscript(_ id: UUID) -> Bool {
        lastVoiceTranscriptID == id || appliedVoiceTranscriptIDs?.contains(id) == true
    }

    var isPurged: Bool { purged == true }

    func trashHasExpired(at time: Date) -> Bool {
        deletedAt.map { time.timeIntervalSince($0) >= 30 * 24 * 60 * 60 } ?? false
    }

    func withoutContent() -> PlannerNote {
        let time = deletedAt ?? updatedAt
        return PlannerNote(id: id, createdAt: time, updatedAt: time, deletedAt: time,
                           syncVersion: syncVersion, richText: richText.map { _ in SharedNoteText(spans: []) }, purged: true)
    }

    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var assistantContentVersion: String {
        // Изменение папки и закрепления не отменяет предложение по тексту.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = document.isEmpty ? Data(text.utf8) : document
        if let richText, let style = try? encoder.encode(richText) { data.append(style) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor]
    }

    @MainActor func attributedText() -> NSAttributedString {
        if let richText, let value = try? richText.attributedText(text) { return value }
        guard !document.isEmpty,
              let value = NSAttributedString(rtfd: document, documentAttributes: nil) else {
            return NSAttributedString(string: text, attributes: Self.bodyAttributes)
        }

        // В старых заметках некоторые фрагменты RTFD не содержат цвета. AppKit рисует их чёрным.
        let result = NSMutableAttributedString(attributedString: value)
        value.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: value.length)) { color, range, _ in
            if color == nil { result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range) }
        }
        return result
    }
}

@MainActor @Observable
final class NoteStore {
    private(set) var notes: [PlannerNote] = []
    private struct SaveFailure {
        let message: String
        var noteID: UUID? = nil
    }

    private var failure: SaveFailure?
    var error: String? { failure?.message }
    var libraryError: String? { failure?.noteID == nil ? error : nil }

    func saveError(for noteID: UUID) -> String? {
        failure?.noteID == noteID ? error : nil
    }
    private(set) var unreadable = false
    var syncEnabled = false
    var awaitingCloudNoteFormat = false
    var sharedFormatLimit: Int?
    private var remoteEdits: [UUID: UUID] = [:]
    @ObservationIgnored private var transcriptStarts: [UUID: Int] = [:]
    @ObservationIgnored let voice: NoteVoiceRecording
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var pending: [UUID: NSAttributedString] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored var syncQueued: (() -> Void)?

    init(url: URL? = nil) {
        self.url = url
        voice = NoteVoiceRecording(directory: url?.deletingLastPathComponent().appending(path: "NoteRecordings", directoryHint: .isDirectory))
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            notes = try JSONDecoder().decode([PlannerNote].self, from: Data(contentsOf: url))
            try Self.validate(notes)
            voice.restoreDrafts(for: notes)
        } catch {
            failure = SaveFailure(message: error.localizedDescription)
            unreadable = true
        }
        purgeExpiredTrash()
    }

    static func validate(_ notes: [PlannerNote]) throws {
        guard Set(notes.map(\.id)).count == notes.count else { throw BackupError.invalid }
        for note in notes {
            if let richText = note.richText {
                guard note.document.isEmpty else { throw BackupError.invalid }
                _ = try richText.attributedText(note.text)
            } else if !note.document.isEmpty {
                guard NSAttributedString(rtfd: note.document, documentAttributes: nil) != nil else { throw BackupError.invalid }
            }
        }
    }

    func content(_ note: PlannerNote) -> NSAttributedString {
        pending[note.id] ?? (notes.first { $0.id == note.id } ?? note).attributedText()
    }

    func takeTranscriptStart(for id: UUID) -> Int? { transcriptStarts.removeValue(forKey: id) }

    func remoteEdit(_ id: UUID) -> UUID? { remoteEdits[id] }

    @discardableResult func create(folder: String) -> UUID? {
        guard !unreadable else { return nil }
        var note = PlannerNote()
        if awaitingCloudNoteFormat || sharedFormatLimit != nil {
            note.richText = SharedNoteText(spans: [])
        }
        note.folder = folder
        notes.insert(note, at: 0)
        dirty = true
        _ = flush()
        return note.id
    }

    func edit(_ id: UUID, content: NSAttributedString) {
        guard !unreadable, notes.contains(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        pending[id] = NSAttributedString(attributedString: content)
        scheduleSave()
    }

    func update(_ id: UUID, _ change: (inout PlannerNote) -> Void) {
        guard !unreadable, let index = notes.firstIndex(where: { $0.id == id && !$0.isPurged }) else { return }
        change(&notes[index])
        notes[index].updatedAt = .now
        dirty = true
        scheduleSave()
    }

    @discardableResult func move(_ id: UUID, to folder: TaskFilter) -> Bool {
        guard folder.acceptsNotes, flush(),
              let index = notes.firstIndex(where: { $0.id == id && $0.deletedAt == nil && !$0.isPurged }) else {
            return false
        }
        if notes[index].folder == folder.id { return true }
        var next = notes
        next[index].folder = folder.id
        next[index].updatedAt = .now
        do {
            try save(next)
            syncQueued?()
            return true
        } catch {
            failure = SaveFailure(message: error.localizedDescription)
            return false
        }
    }

    @discardableResult func moveToTrash(_ id: UUID) -> Bool {
        guard flush(), let index = notes.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else {
            return false
        }
        var next = notes
        let time = Date.now
        next[index].deletedAt = time
        next[index].updatedAt = time
        do {
            try save(next)
            syncQueued?()
            return true
        } catch {
            failure = SaveFailure(message: error.localizedDescription)
            return false
        }
    }

    func restoreFromTrash(_ id: UUID) {
        purgeExpiredTrash()
        guard let note = notes.first(where: { $0.id == id }), !note.isPurged,
              note.deletedAt != nil, !note.trashHasExpired(at: .now) else { return }
        update(id) { $0.deletedAt = nil }
        flush()
    }

    func purgeExpiredTrash(now: Date = .now) {
        guard !unreadable else { return }
        if notes.contains(where: { !$0.isPurged && $0.trashHasExpired(at: now) }) {
            guard flush() else { return }
            do {
                try save(notes.map { !$0.isPurged && $0.trashHasExpired(at: now) ? $0.withoutContent() : $0 })
                syncQueued?()
            } catch {
                failure = SaveFailure(message: error.localizedDescription)
            }
        }
        for note in notes where note.isPurged { voice.discardAll(for: note.id) }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flush()
        }
    }

    @discardableResult func flush() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard !unreadable else { return false }
        guard dirty || !pending.isEmpty else { return true }
        var currentNoteID: UUID?
        do {
            var next = notes
            for (id, value) in pending {
                guard let index = next.firstIndex(where: { $0.id == id }) else { continue }
                currentNoteID = id
                try setBody(value, in: &next[index])
                next[index].updatedAt = .now
            }
            currentNoteID = nil
            try save(next)
            pending.removeAll()
            dirty = false
            syncQueued?()
            return true
        } catch {
            failure = SaveFailure(message: error.localizedDescription, noteID: currentNoteID)
            return false
        }
    }

    // Сохраняем внешний текст одной записью. При ошибке повтор не добавит его второй раз.
    func applyText(_ text: String, to id: UUID, append: Bool, expectedVersion: String? = nil, voiceTranscriptID: UUID? = nil) throws {
        guard flush() else { throw AssistantFailure(message: "Не удалось сохранить текст заметки.") }
        guard let index = notes.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else {
            throw AssistantFailure(message: "Заметка недоступна.")
        }
        let note = notes[index]
        if let voiceTranscriptID, note.hasVoiceTranscript(voiceTranscriptID) { return }
        if let expectedVersion, expectedVersion != note.assistantContentVersion {
            throw AssistantFailure(message: "Заметка изменилась. Попросите помощника обновить предложение.")
        }
        let value = NSMutableAttributedString(string: "")
        let old = note.attributedText()
        let attributes = PlannerNote.bodyAttributes
        if append {
            value.append(old)
            if old.length > 0 { value.append(NSAttributedString(string: "\n\n", attributes: attributes)) }
        }
        value.append(NSAttributedString(string: text, attributes: attributes))
        if !append {
            old.enumerateAttribute(.attachment, in: NSRange(location: 0, length: old.length)) { attachment, range, _ in
                guard attachment != nil else { return }
                value.append(NSAttributedString(string: "\n", attributes: attributes))
                value.append(old.attributedSubstring(from: range))
            }
        }
        var next = notes
        try setBody(value, in: &next[index])
        next[index].updatedAt = .now
        if let voiceTranscriptID {
            var applied = note.appliedVoiceTranscriptIDs ?? []
            if let previousID = note.lastVoiceTranscriptID { applied.insert(previousID) }
            applied.insert(voiceTranscriptID)
            next[index].appliedVoiceTranscriptIDs = applied
            next[index].lastVoiceTranscriptID = voiceTranscriptID
        }
        try save(next)
        transcriptStarts[id] = voiceTranscriptID.map { _ in value.length - (text as NSString).length }
        remoteEdits[id] = UUID()
        syncQueued?()
    }

    private func setBody(_ content: NSAttributedString, in note: inout PlannerNote) throws {
        note.text = content.string
        guard note.richText != nil else {
            note.document = try content.data(from: NSRange(location: 0, length: content.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            return
        }
        note.richText = try SharedNoteText.encode(content)
        if let limit = sharedFormatLimit, try Self.wireData(note).count > limit {
            throw SharedNoteText.Failure.noteTooLarge
        }
    }

    func restore(_ notes: [PlannerNote]) throws {
        try Self.validate(notes)
        guard self.notes.isEmpty, !unreadable else { throw BackupError.invalid }
        try mergeLocal(notes)
    }

    func mergeLocal(_ source: [PlannerNote]) throws {
        guard flush() else { throw BackupError.unsavedChanges }
        let ids = Set(notes.map(\.id))
        let additions = source.filter { !ids.contains($0.id) && !$0.isPurged && !$0.trashHasExpired(at: .now) }.map { note in
            var copy = note
            copy.syncVersion = nil
            copy.lastVoiceTranscriptID = nil
            copy.appliedVoiceTranscriptIDs = nil
            return copy
        }
        if !additions.isEmpty { try save(notes + additions) }
    }

    func applyRemote(_ note: PlannerNote, revision: String) throws {
        guard flush() else { throw BackupError.unsavedChanges }
        try Self.validate([note])
        var next = notes
        var incoming = note
        let previous = notes.first(where: { $0.id == note.id })
        incoming.lastVoiceTranscriptID = previous?.lastVoiceTranscriptID
        incoming.appliedVoiceTranscriptIDs = previous?.appliedVoiceTranscriptIDs
        let digest = try Self.digest(Self.wireData(note))
        incoming.syncVersion = NoteSyncVersion(revision: revision, localDigest: digest)
        if incoming.isPurged || incoming.trashHasExpired(at: .now) { incoming = incoming.withoutContent() }
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            var local = notes[index]
            let localDigest = try Self.digest(Self.wireData(local))
            if !incoming.isPurged && !local.isPurged && digest != localDigest && localDigest != local.syncVersion?.localDigest {
                local.id = UUID()
                local.syncVersion = nil
                local.lastVoiceTranscriptID = nil
                local.appliedVoiceTranscriptIDs = nil
                next.append(local)
            }
            next[index] = incoming
        } else {
            next.append(incoming)
        }
        try save(next)
        if incoming.isPurged { voice.discardAll(for: incoming.id) }
        if let previous, previous.document != incoming.document || previous.text != incoming.text ||
            previous.richText != incoming.richText {
            transcriptStarts[note.id] = nil
            remoteEdits[note.id] = UUID()
        }
    }

    func acknowledge(_ id: UUID, revision: String, digest: String) throws {
        guard flush() else { throw BackupError.unsavedChanges }
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var next = notes
        next[index].syncVersion = NoteSyncVersion(revision: revision, localDigest: digest)
        try save(next)
    }

    static func wireData(_ note: PlannerNote) throws -> Data {
        var copy = note
        copy.syncVersion = nil
        copy.lastVoiceTranscriptID = nil
        copy.appliedVoiceTranscriptIDs = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(copy)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func save(_ next: [PlannerNote]) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
        }
        notes = next
        failure = nil
    }
}
