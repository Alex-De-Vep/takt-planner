import Foundation
import SwiftData
import Testing
@testable import Planner

@MainActor
struct SyncStreamTests {
    @Test func parsesCompleteFramesAndIgnoresKeepAlives() throws {
        let wire = ": keep-alive\n\nevent: ready\r\ndata: {}\r\n\r\nevent: unknown\ndata: {}\n\n"
            + "event: notes.changed\n\nevent:notes.changed\ndata: {}\n\nevent: tasks.changed\ndata: {}\n\nevent: ready\ndata: {}\n"
        var parser = SyncStreamParser()
        #expect(try wire.utf8.compactMap { try parser.append($0) } == [.ready, .notesChanged, .tasksChanged])
    }

    @Test(arguments: [false, true])
    func switchesBetweenEventsAndPolling(taskEvents: Bool) async throws {
        let server = taskEvents ? SyncEventFixture.tasksAndNotes : SyncEventFixture.notesOnly
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let repository = try SyncRepository(context: container.mainContext, libraryID: server.library, deviceID: UUID().syncID)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncEventFixture.self]
        let session = URLSession(configuration: configuration)
        let api = SyncHTTP(origin: URL(string: "https://" + server.host)!, store: SyncEventCredential(), session: session)
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
        func taskTitle() -> String? {
            (try? container.mainContext.fetch(FetchDescriptor<PlannerTask>()))?.first?.title
        }

        server.storeTask("Created before subscription")
        var noteChecks = server.count("/v1/notes")
        server.frame("ready")
        try await wait {
            server.count("/v1/notes") == noteChecks + 1 && engine.status == .upToDate
                && taskTitle() == "Created before subscription"
        }

        noteChecks = server.count("/v1/notes")
        var taskChecks = server.count("/v1/sync/changes")
        server.storeTask("Updated on Android")
        if taskEvents {
            let configChecks = server.count("/v1/config")
            engine.poll()
            try await Task.sleep(for: .milliseconds(330))
            #expect(server.count("/v1/config") == configChecks)
            #expect(server.count("/v1/sync/changes") == taskChecks)
            server.frame("tasks.changed")
        } else {
            engine.poll()
        }
        try await wait { taskTitle() == "Updated on Android" && engine.status == .upToDate }
        #expect(server.count("/v1/notes") == noteChecks)
        #expect(server.count("/v1/sync/changes") == taskChecks + 1)

        taskChecks = server.count("/v1/sync/changes")
        note.title = "Received through SSE"
        note.updatedAt = .now
        try server.store(note)
        server.frame("notes.changed")
        try await wait { notes.notes.first?.title == note.title && engine.status == .upToDate }
        #expect(server.count("/v1/sync/changes") == taskChecks)

        server.disconnect()
        try await wait { server.count("/v1/notes/events") == 2 }
        note.title = "Received through minute fallback"
        note.updatedAt = .now
        try server.store(note)
        server.storeTask("Task received through fallback")
        engine.poll()
        try await wait { notes.notes.first?.title == note.title && taskTitle() == "Task received through fallback" }

        note.title = "Caught up on reconnect"
        note.updatedAt = .now
        try server.store(note)
        server.storeTask("Task caught up on reconnect")
        server.frame("ready")
        try await wait { notes.notes.first?.title == note.title && taskTitle() == "Task caught up on reconnect" }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition())
    }
}

private struct SyncEventCredential: SyncCredentialStore {
    func load() throws -> SyncRefreshCredential? { nil }
    func save(_ value: SyncRefreshCredential) throws {}
    func remove() throws {}
}

private final class SyncEventFixture: URLProtocol, @unchecked Sendable {
    static let tasksAndNotes = Server(host: "all-events.example.test", taskEvents: true)
    static let notesOnly = Server(host: "note-events.example.test", taskEvents: false)
    private static let servers = [tasksAndNotes.host: tasksAndNotes, notesOnly.host: notesOnly]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host.flatMap { servers[$0] } != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { request.url?.host.flatMap { Self.servers[$0] }?.respond(to: self) }
    override func stopLoading() { request.url?.host.flatMap { Self.servers[$0] }?.remove(self) }

    final class Server: @unchecked Sendable {
        let library = UUID().syncID
        let host: String
        private let taskEvents: Bool
        private let taskID = UUID().syncID
        private var taskRevision = 0
        private var taskTitle = ""
        private let lock = NSLock()
        private var requests: [String: Int] = [:]
        private var note: (id: String, revision: String, data: String)?
        private weak var stream: SyncEventFixture?

        init(host: String, taskEvents: Bool) {
            self.host = host
            self.taskEvents = taskEvents
        }

        func storeTask(_ title: String) {
            lock.withLock {
                taskRevision += 1
                taskTitle = title
            }
        }

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

        func remove(_ connection: SyncEventFixture) {
            lock.withLock { if stream === connection { stream = nil } }
        }

        func respond(to connection: SyncEventFixture) {
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
                    let tasks = taskEvents ? #","taskEventsVersion":1"# : ""
                    return """
                    {"protocolVersion":1,"serverTime":"2026-11-17T10:00:00Z","limits":{"maxBatchOperations":100,"maxRequestBytes":4194304,"maxNoteBytes":8388608,"noteEventsVersion":1\(tasks)}}
                    """
                case "/v1/sync/snapshot":
                    return """
                    {"protocolVersion":1,"libraryId":"\(library)","cursor":"0","initialized":true,"entities":[]}
                    """
                case "/v1/sync/changes":
                    let cursor = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? "") ?? 0
                    let revision = String(taskRevision)
                    let task = SyncEntity(id: taskID, type: .task,
                        fields: ["title": .text(taskTitle), "createdAt": .text("2026-11-17T10:00:00Z"),
                                 "placement": .object(["kind": .text("inbox")])],
                        versions: [:], deleted: false, revision: revision)
                    let changes = cursor < taskRevision ? [SyncChanges.Change(revision: revision, entity: task)] : []
                    let page = SyncChanges(libraryId: library, changes: changes, nextCursor: revision, hasMore: false)
                    return (try? JSONEncoder().encode(page)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
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
