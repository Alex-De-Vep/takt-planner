import Foundation

/// История и журнал действий записываются атомарно, отдельно от схемы задач V5.
struct AssistantStore {
    let url: URL
    init(url: URL = AssistantPaths.root.appending(path: "conversations.json")) { self.url = url }
    func load() throws -> AssistantArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return AssistantArchive() }
        let archive = try JSONDecoder().decode(AssistantArchive.self, from: Data(contentsOf: url))
        guard archive.version == 1 else { throw AssistantFailure(message: "Формат истории помощника не поддерживается.") }
        return archive
    }
    func save(_ archive: AssistantArchive) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
    }
}
