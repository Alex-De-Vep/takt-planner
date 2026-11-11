import Foundation

/// История и журнал действий записываются атомарно, отдельно от схемы задач V5.
struct AssistantStore {
    let url: URL
    init(url: URL = AssistantPaths.root.appending(path: "conversations.json")) { self.url = url }
    func load() throws -> AssistantArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return AssistantArchive() }
        var archive = try JSONDecoder().decode(AssistantArchive.self, from: Data(contentsOf: url))
        guard (1...2).contains(archive.version) else { throw AssistantFailure(message: "Формат истории помощника не поддерживается.") }
        archive.version = 2
        return archive
    }
    func save(_ archive: AssistantArchive) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
    }
}
