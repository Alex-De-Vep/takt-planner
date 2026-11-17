import Foundation
import Testing
@testable import Planner

@MainActor
struct NoteStreamTests {
    @Test func parsesCompleteFramesAndIgnoresKeepAlives() throws {
        let wire = ": keep-alive\n\nevent: ready\r\ndata: {}\r\n\r\nevent: unknown\ndata: {}\n\n"
            + "event: notes.changed\n\nevent:notes.changed\ndata: {}\n\nevent: ready\ndata: {}\n"
        var parser = NoteStreamParser()
        #expect(try wire.utf8.compactMap { try parser.append($0) } == [.ready, .changed])
    }

    @Test func switchesBetweenNoteEventsAndPolling() async throws {
        let server = NoteEventFixture.server
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let repository = try SyncRepository(context: container.mainContext, libraryID: server.library, deviceID: UUID().syncID)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoteEventFixture.self]
        let session = URLSession(configuration: configuration)
        let api = SyncHTTP(origin: URL(string: "https://note-events.example.test")!, store: NoteEventCredential(), session: session)
        try await api.install(SyncTokens(accessToken: "notes", refreshToken: "refresh", expiresIn: 900))
        let notes = NoteStore()
        let engine = SyncEngine(repository: repository, api: api, notes: notes)
        defer {
            engine.stop()
            session.invalidateAndCancel()
        }

        var note = PlannerNote(title: "Saved before subscription")
        try server.store(note)
        engine.start()
        try await wait { server.count("/v1/notes/events") == 1 && notes.notes.first?.title == note.title && engine.status == .upToDate }
        var checks = server.count("/v1/notes")
        server.frame("ready")
        try await wait { server.count("/v1/notes") == checks + 1 && engine.status == .upToDate }

        checks = server.count("/v1/notes")
        let changes = server.count("/v1/sync/changes")
        engine.wakeTasks()
        try await wait { server.count("/v1/sync/changes") == changes + 2 && engine.status == .upToDate }
        #expect(server.count("/v1/notes") == checks)

        note.title = "Received through SSE"
        note.updatedAt = .now
        try server.store(note)
        server.frame("notes.changed")
        try await wait { notes.notes.first?.title == note.title && engine.status == .upToDate }
        #expect(server.count("/v1/sync/changes") == changes + 2)

        server.disconnect()
        try await wait { server.count("/v1/notes/events") == 2 }
        note.title = "Received through minute fallback"
        note.updatedAt = .now
        try server.store(note)
        engine.wakeTasks()
        try await wait { notes.notes.first?.title == note.title }

        note.title = "Caught up on reconnect"
        note.updatedAt = .now
        try server.store(note)
        server.frame("ready")
        try await wait { notes.notes.first?.title == note.title }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition())
    }
}

private struct NoteEventCredential: SyncCredentialStore {
    func load() throws -> SyncRefreshCredential? { nil }
    func save(_ value: SyncRefreshCredential) throws {}
    func remove() throws {}
}

private final class NoteEventFixture: URLProtocol, @unchecked Sendable {
    static let server = Server()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "note-events.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.server.respond(to: self) }
    override func stopLoading() { Self.server.remove(self) }

    final class Server: @unchecked Sendable {
        let library = UUID().syncID
        private let lock = NSLock()
        private var requests: [String: Int] = [:]
        private var note: (id: String, revision: String, data: String)?
        private weak var stream: NoteEventFixture?

        func count(_ path: String) -> Int { lock.withLock { requests[path, default: 0] } }

        @MainActor func store(_ value: PlannerNote) throws {
            let data = try NoteStore.wireData(value)
            let body = (value.id.syncID, NoteStore.digest(data), data.base64EncodedString())
            lock.withLock { note = body }
        }

        func frame(_ name: String) {
            let connection = lock.withLock { stream }
            if let connection {
                connection.client?.urlProtocol(connection, didLoad: Data("event: \(name)\ndata: {}\n\n".utf8))
            }
        }

        func disconnect() {
            let connection = lock.withLock { stream }
            if let connection { connection.client?.urlProtocolDidFinishLoading(connection) }
        }

        func remove(_ connection: NoteEventFixture) {
            lock.withLock { if stream === connection { stream = nil } }
        }

        func respond(to connection: NoteEventFixture) {
            guard let url = connection.request.url else { return }
            let path = url.path
            let client = connection.client
            let isStream = path == "/v1/notes/events"
            let type = isStream ? "text/event-stream" : "application/json"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": type])!
            client?.urlProtocol(connection, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body = lock.withLock {
                requests[path, default: 0] += 1
                switch path {
                case "/v1/notes/events":
                    stream = connection
                    return ""
                case "/v1/config":
                    return """
                    {"protocolVersion":1,"serverTime":"2026-11-17T10:00:00Z","limits":{"maxBatchOperations":100,"maxRequestBytes":4194304,"maxNoteBytes":8388608,"noteEventsVersion":1}}
                    """
                case "/v1/sync/snapshot":
                    return """
                    {"protocolVersion":1,"libraryId":"\(library)","cursor":"0","initialized":true,"entities":[]}
                    """
                case "/v1/sync/changes":
                    return """
                    {"libraryId":"\(library)","changes":[],"nextCursor":"0","hasMore":false}
                    """
                case "/v1/notes":
                    guard let note else { return #"{"notes":[]}"# }
                    return """
                    {"notes":[{"id":"\(note.id)","revision":"\(note.revision)"}]}
                    """
                default:
                    guard let note, path == "/v1/notes/" + note.id else { return "{}" }
                    return """
                    {"revision":"\(note.revision)","data":"\(note.data)"}
                    """
                }
            }
            guard !isStream else { return }
            client?.urlProtocol(connection, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(connection)
        }
    }
}
