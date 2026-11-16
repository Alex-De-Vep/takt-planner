import Foundation

/// История и журнал действий записываются атомарно, отдельно от схемы задач V5.
struct AssistantStore {
    struct Draft: Codable {
        let afterUserMessageID: UUID?
        let text: String

        init(_ thread: AssistantThread) {
            afterUserMessageID = thread.messages.last(where: { $0.role == .user })?.id
            text = thread.draft
        }
    }

    let url: URL
    init(url: URL = AssistantPaths.root.appending(path: "conversations.json")) { self.url = url }

    private func draftURL(for threadID: UUID) -> URL {
        url.appendingPathExtension("drafts").appending(path: "\(threadID.uuidString).json")
    }

    func load() throws -> AssistantArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return AssistantArchive() }
        var archive = try JSONDecoder().decode(AssistantArchive.self, from: Data(contentsOf: url))
        guard (1...2).contains(archive.version) else { throw AssistantFailure(message: "Формат истории помощника не поддерживается.") }
        archive.version = 2
        for index in archive.threads.indices {
            let thread = archive.threads[index]
            let url = draftURL(for: thread.id)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let saved = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: url))
            // A successful send commits a new user message. An older draft file can remain
            // after a crash between committing the history and removing that file.
            if saved.afterUserMessageID == Draft(thread).afterUserMessageID {
                archive.threads[index].draft = saved.text
            }
        }
        return archive
    }

    func save(_ archive: AssistantArchive) throws {
        var history = archive
        for index in archive.threads.indices where !archive.threads[index].draft.isEmpty {
            let thread = archive.threads[index]
            // Persist legacy inline drafts before removing them from the history.
            try saveDraft(Draft(thread), for: thread.id)
            history.threads[index].draft = ""
        }
        try write(history, to: url)
        for thread in archive.threads where thread.draft.isEmpty { discardDraft(for: thread.id) }
    }

    func saveDraft(_ draft: Draft, for threadID: UUID) throws {
        try write(draft, to: draftURL(for: threadID))
    }

    func discardDraft(for threadID: UUID) {
        let url = draftURL(for: threadID)
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
