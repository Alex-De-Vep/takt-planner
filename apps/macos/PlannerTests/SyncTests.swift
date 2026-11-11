import Foundation
import SwiftData
import Testing
@testable import Planner

@MainActor
struct SyncTests {
    @Test func defaultLanguageFollowsSystemAndKeepsManualChoice() throws {
        let suite = "local.planner.language.test." + UUID().syncID
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.language == .system)
        preferences.language = .english
        #expect(AppPreferences(defaults: defaults).language == .english)
    }

    @Test(arguments: [false, true])
    func updatedWelcomeReappearsOnceAndKeepsStorageMode(signedIn: Bool) throws {
        let suite = "local.planner.welcome.test." + UUID().syncID
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "planner.welcome.v1")
        defaults.set(true, forKey: "planner.welcome.v2")
        let profile = signedIn ? SyncProfile(
            account: SyncAccount(id: UUID().syncID, email: "welcome@example.test", libraryId: UUID().syncID),
            sessionID: UUID().syncID
        ) : nil
        if let profile { defaults.set(try JSONEncoder().encode(profile), forKey: "planner.cloud.profile") }
        let first = CloudWorkspace(defaults: defaults)
        #expect(!first.welcomeCompleted)
        #expect(first.profile == profile)
        first.welcomeCompleted = true

        let second = CloudWorkspace(defaults: defaults)
        #expect(second.welcomeCompleted)
        #expect(second.profile == profile)
    }

    @Test func failedSaveRollsBackTaskAndOutboxTogether() throws {
        struct FailedSave: Error {}
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let repo = try SyncRepository(context: context, libraryID: UUID().syncID, deviceID: UUID().syncID)
        let service = TaskService(context: context) { _ in throw FailedSave() }
        service.syncRepository = repo

        #expect(service.createTask(in: .inbox, folders: []) == nil)
        #expect(try context.fetchCount(FetchDescriptor<PlannerTask>()) == 0)
        #expect(try repo.pendingOperations().isEmpty)
    }

    @Test func initialMergeKeepsCloudDuplicatesAndCopiesNewTasksWithChecklist() throws {
        let source = try PlannerPersistence.makeContainer(inMemory: true)
        let local = TaskService(context: source.mainContext)
        let duplicate = try #require(local.createTask(in: .inbox, folders: []))
        let deleted = try #require(local.createTask(in: .inbox, folders: []))
        let folder = try local.saveFolder(name: "Local folder")
        let newTask = try #require(local.createTask(in: .folder(folder.id), folders: [folder]))
        let checklist = try #require(local.addChecklistItem(to: newTask))
        #expect(local.renameChecklistItem(checklist, to: "Local checklist"))

        let destination = try PlannerPersistence.makeContainer(inMemory: true)
        let repo = try SyncRepository(context: destination.mainContext, libraryID: UUID().syncID, deviceID: UUID().syncID)
        let model = try #require(SyncLocalEntity(duplicate))
        var fields = model.fields
        fields["title"] = .text("Current cloud title")
        try repo.applySnapshot(SyncSnapshot(protocolVersion: 1, libraryId: repo.libraryID, cursor: "2",
            initialized: true, entities: [
                SyncEntity(id: duplicate.id.syncID, type: .task, fields: fields, versions: [:], deleted: false, revision: "1"),
                SyncEntity(id: deleted.id.syncID, type: .task, fields: [:], versions: [:], deleted: true, revision: "2")
            ]))
        try repo.mergeLocal(from: source.mainContext)
        try repo.mergeLocal(from: source.mainContext)

        let tasks = try destination.mainContext.fetch(FetchDescriptor<PlannerTask>())
        #expect(Set(tasks.map(\.id)) == Set([duplicate.id, newTask.id]))
        #expect(tasks.first { $0.id == duplicate.id }?.title == "Current cloud title")
        let copy = try #require(tasks.first { $0.id == newTask.id })
        #expect(copy.folder?.id == folder.id)
        #expect(copy.orderedChecklistItems.map(\.title) == ["Local checklist"])
        #expect(try repo.pendingOperations().map(\.entityType) == [.folder, .task, .checklistItem])
    }

    @Test func v5LibraryMigratesWithItsTasksAndChecklist() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().syncID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Planner.store")
        let id: UUID
        do {
            let schema = Schema(versionedSchema: PlannerSchemaV5.self)
            let config = ModelConfiguration("Planner", schema: schema, url: url, cloudKitDatabase: .none)
            let old = try ModelContainer(for: schema, configurations: [config])
            let context = old.mainContext
            let service = TaskService(context: context)
            let group = try service.saveFolder(name: "Existing folder")
            let task = try #require(service.createTask(in: .folder(group.id), folders: [group]))
            service.rename(task, to: "Existing task")
            let item = try #require(service.addChecklistItem(to: task))
            #expect(service.renameChecklistItem(item, to: "Existing\nchecklist"))
            id = task.id
        }
        let migrated = try PlannerPersistence.makeContainer(at: url)
        let task = try #require(migrated.mainContext.fetch(FetchDescriptor<PlannerTask>()).first)
        #expect(task.id == id)
        #expect(task.folder?.name == "Existing folder")
        #expect(task.title == "Existing task")
        #expect(task.orderedChecklistItems.map(\.title) == ["Existing\nchecklist"])
        #expect(try migrated.mainContext.fetchCount(FetchDescriptor<PlannerSchemaV6.SyncQueueItem>()) == 0)
    }
}

@MainActor
struct SyncPilotTests {
    private struct Pair: Codable {
        let library: String
        let first: String
        let second: String
        let task: UUID
    }

    fileprivate struct TestCredential: SyncCredentialStore {
        let url: URL
        func load() throws -> SyncRefreshCredential? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try JSONDecoder().decode(SyncRefreshCredential.self, from: Data(contentsOf: url))
        }
        func save(_ value: SyncRefreshCredential) throws {
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        }
        func remove() throws {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    @MainActor
    private struct Instance {
        let container: ModelContainer
        let service: TaskService
        let repo: SyncRepository
        let api: SyncHTTP
        let engine: SyncEngine

        init(root: URL, origin: URL, library: String, device: String) throws {
            container = try PlannerPersistence.makeContainer(at: root.appending(path: device).appending(path: "Planner.store"))
            service = TaskService(context: container.mainContext)
            repo = try SyncRepository(context: container.mainContext, libraryID: library, deviceID: device)
            service.syncRepository = repo
            api = SyncHTTP(origin: origin, store: TestCredential(url: root.appending(path: device + ".json")))
            engine = SyncEngine(repository: repo, api: api)
        }

        func task(_ id: UUID) throws -> PlannerTask {
            try #require(container.mainContext.fetch(FetchDescriptor<PlannerTask>(predicate: #Predicate { $0.id == id })).first)
        }
    }

    @Test func offlineEditSurvivesIndependentProcessRestart() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let stage = env["PLANNER_SYNC_TEST_STAGE"] else { return }
        let origin = try #require(env["PLANNER_SYNC_TEST_ORIGIN"].flatMap(URL.init(string:)))
        #expect(origin.host == "127.0.0.1")
        guard origin.host == "127.0.0.1" else { return }
        let run = try #require(env["PLANNER_SYNC_TEST_RUN"].flatMap(UUID.init(uuidString:)))
        let root = try PlannerPersistence.liveStoreURL().deletingLastPathComponent().appending(path: "SyncPilot/" + run.syncID)
        let pairURL = root.appending(path: "pair.json")
        switch stage {
        case "prepare":
            let first = UUID().syncID, second = UUID().syncID
            let publicAPI = SyncHTTP(origin: origin, store: TestCredential(url: root.appending(path: "public.json")))
            let email = env["PLANNER_SYNC_TEST_EMAIL"] ?? "sync-client@example.test"
            let password = "Pilot-local-fixture-2026"
            let loginA = try await login(first, publicAPI: publicAPI, email: email, password: password)
            let account: SyncAccount = try await publicAPI.publicRequest("/v1/me", bearer: loginA.accessToken)
            let loginB = try await login(second, publicAPI: publicAPI, email: email, password: password)
            #expect(loginA.user.id == loginB.user.id && loginA.sessionId != loginB.sessionId)
            let a = try Instance(root: root, origin: origin, library: account.libraryId, device: first)
            let b = try Instance(root: root, origin: origin, library: account.libraryId, device: second)
            try await a.api.install(loginA.tokens)
            try await b.api.install(loginB.tokens)

            let source = try PlannerPersistence.makeContainer(inMemory: true)
            let local = TaskService(context: source.mainContext)
            let folder = try local.saveFolder(name: "Sync pilot")
            let task = try #require(local.createTask(in: .folder(folder.id), folders: [folder]))
            local.rename(task, to: "Original title")
            let item = try #require(local.addChecklistItem(to: task))
            #expect(local.renameChecklistItem(item, to: "First line\nSecond line"))
            let deadline = Date(timeIntervalSince1970: 1_900_000_000)
            #expect(local.setDeadline(task, to: TaskDeadline(date: deadline, includesTime: true, timeZoneID: "Europe/Moscow")))
            let imports = try a.repo.importOperations(from: source.mainContext)
            let importID = UUID().syncID
            let importPath = "/v1/library/imports/" + importID
            let staged: SyncImportResponse = try await a.api.authorized("/v1/library/imports", method: "POST",
                body: SyncHTTP.payload(["importId": importID]))
            #expect(staged.importId == importID)
            let batch: SyncImportBatch = try await a.api.authorized(importPath + "/mutations", method: "POST",
                body: SyncHTTP.payload(SyncBatch(mutations: imports)))
            #expect(batch.accepted == 3)
            let committed: SyncOK = try await a.api.authorized(importPath + "/commit", method: "POST", body: Data("{}".utf8))
            #expect(committed.ok)

            try await a.engine.synchronize()
            try await b.engine.synchronize()
            let copy = try b.task(task.id)
            #expect(copy.title == "Original title")
            #expect(copy.folder?.id == folder.id)
            #expect(copy.deadline?.date == deadline)
            #expect(copy.deadline?.timeZoneID == "Europe/Moscow")
            #expect(copy.orderedChecklistItems.map(\.title) == ["First line\nSecond line"])
            a.engine.stop()
            let offline = try Instance(root: root, origin: #require(URL(string: "http://127.0.0.1:55447")),
                                       library: account.libraryId, device: first)
            let offlineTask = try offline.task(task.id)
            offline.service.rename(offlineTask, to: "Edited offline")
            #expect(offlineTask.title == "Edited offline")
            #expect(try offline.repo.pendingOperations().count == 1)
            do {
                try await offline.engine.synchronize()
                Issue.record("The offline endpoint unexpectedly responded")
            } catch let error as URLError {
                #expect(error.code == .cannotConnectToHost)
            }
            #expect(try offline.repo.pendingOperations().count == 1)
            #expect(copy.title == "Original title")
            let pair = Pair(library: account.libraryId, first: first, second: second, task: task.id)
            try JSONEncoder().encode(pair).write(to: pairURL, options: .atomic)

        case "resume":
            let pair = try JSONDecoder().decode(Pair.self, from: Data(contentsOf: pairURL))
            let a = try Instance(root: root, origin: origin, library: pair.library, device: pair.first)
            let b = try Instance(root: root, origin: origin, library: pair.library, device: pair.second)
            #expect(try a.task(pair.task).title == "Edited offline")
            #expect(try a.repo.pendingOperations().count == 1)
            #expect(try b.task(pair.task).title == "Original title")
            try await startAndWait(a.engine)
            try await startAndWait(b.engine)
            #expect(try a.repo.pendingOperations().isEmpty)
            #expect(try b.task(pair.task).title == "Edited offline")
            #expect(try b.task(pair.task).orderedChecklistItems.map(\.title) == ["First line\nSecond line"])

        default:
            Issue.record("Unknown sync pilot stage")
        }
    }

    private func startAndWait(_ engine: SyncEngine) async throws {
        engine.start()
        defer { engine.stop() }
        for _ in 0..<100 {
            if engine.status == .upToDate { return }
            if engine.status == .signIn { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Automatic sync did not finish: \(engine.status)")
    }

    private func login(_ id: String, publicAPI: SyncHTTP, email: String, password: String) async throws -> SyncLogin {
        try await publicAPI.publicRequest("/v1/auth/login", method: "POST",
            body: SyncHTTP.payload(["email": email, "password": password, "deviceId": id, "deviceName": "Pilot Mac"]))
    }
}

@MainActor
struct CloudWorkspacePilotTests {
    private struct Changes: Codable {
        let edited: UUID
        let deleted: UUID
        let created: UUID
        let remote: UUID
    }

    @MainActor
    private final class Device {
        let cloud: CloudWorkspace
        var library: CloudLibrary

        init(root: URL, origin: URL, defaults: UserDefaults) throws {
            let url = root.appending(path: "Planner.store")
            cloud = CloudWorkspace(defaults: defaults, origin: origin, storeURL: url) { scope in
                let name = scope.split(separator: "|").last.map(String.init) ?? "public"
                return SyncPilotTests.TestCredential(url: root.appending(path: "credential-" + name))
            }
            if let resumed = try cloud.resume() {
                library = resumed
            } else {
                let container = try PlannerPersistence.makeContainer(at: url)
                library = CloudLibrary(container: container, service: TaskService(context: container.mainContext))
            }
            cloud.didOpen = { [weak self] in self?.library = $0 }
        }

        func create(_ title: String) throws -> PlannerTask {
            let task = try #require(library.service.createTask(in: .inbox, folders: []))
            library.service.rename(task, to: title)
            return task
        }

        func task(_ id: UUID) throws -> PlannerTask? {
            try library.service.context.fetch(FetchDescriptor<PlannerTask>(predicate: #Predicate { $0.id == id })).first
        }

        var count: Int { get throws { try library.service.context.fetchCount(FetchDescriptor<PlannerTask>()) } }
    }

    @Test func accountSessionKeepsTasksAndReplaysChangesAcrossRestart() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let stage = env["PLANNER_WORKSPACE_TEST_STAGE"] else { return }
        let origin = try #require(env["PLANNER_SYNC_TEST_ORIGIN"].flatMap(URL.init(string:)))
        try #require(origin.host == "127.0.0.1")
        let run = try #require(env["PLANNER_SYNC_TEST_RUN"].flatMap(UUID.init(uuidString:)))
        let firstEmail = try #require(env["PLANNER_SYNC_TEST_EMAIL"])
        let secondEmail = try #require(env["PLANNER_SYNC_TEST_OTHER_EMAIL"])
        let root = try PlannerPersistence.liveStoreURL().deletingLastPathComponent().appending(path: "WorkspacePilot/" + run.syncID)
        let a = try Device(root: root.appending(path: "a"), origin: origin,
                           defaults: #require(UserDefaults(suiteName: "local.planner.sync-pilot.a." + run.syncID)))
        let b = try Device(root: root.appending(path: "b"), origin: origin,
                           defaults: #require(UserDefaults(suiteName: "local.planner.sync-pilot.b." + run.syncID)))
        let state = root.appending(path: "changes.json")

        if stage == "prepare" {
            let remote = try b.create("Created on the second Mac").id
            try await signIn(b, email: firstEmail)
            try await flush(b)
            let edited = try a.create("Created on this Mac").id
            let deleted = try a.create("Delete after signing out").id
            try await signIn(a, email: firstEmail)
            #expect(a.cloud.setup == nil)
            #expect(try a.count == 3)
            #expect(try a.task(remote)?.title == "Created on the second Mac")
            try await flush(a)
            let bEngine = try #require(b.cloud.engine)
            bEngine.wake()
            try await wait { try b.task(edited) != nil && b.task(deleted) != nil }

            let service = a.library.service
            let beforeSignOut = try a.create("Queued before sign-out").id
            await a.cloud.signOut()
            #expect(a.cloud.profile == nil && a.cloud.engine == nil)
            #expect(a.library.service === service)
            let editedTask = try a.task(edited)
            let edit = try #require(editedTask)
            service.rename(edit, to: "Edited while signed out")
            service.toggleCompleted(edit)
            let taskToDelete = try a.task(deleted)
            let remove = try #require(taskToDelete)
            #expect(service.delete(remove))
            let operations = try #require(service.syncRepository).pendingOperations()
            #expect(operations.contains { $0.entityId == deleted.syncID && $0.kind == .delete })
            #expect(operations.contains { $0.entityId == beforeSignOut.syncID && $0.kind == .create })
            #expect(try b.task(edited)?.title == "Created on this Mac")
            #expect(try b.task(deleted) != nil)
            try JSONEncoder().encode(Changes(edited: edited, deleted: deleted, created: beforeSignOut, remote: remote))
                .write(to: state, options: .atomic)
        } else {
            try #require(stage == "resume")
            let changes = try JSONDecoder().decode(Changes.self, from: Data(contentsOf: state))
            let service = a.library.service
            #expect(a.cloud.profile == nil && a.cloud.engine == nil)
            #expect(try a.task(changes.edited)?.title == "Edited while signed out")
            #expect(try a.task(changes.deleted) == nil)
            try await signIn(a, email: firstEmail)
            #expect(a.cloud.setup == nil)
            #expect(a.library.service === service)
            try await flush(a)
            try #require(b.cloud.engine).wake()
            try await wait {
                try b.task(changes.edited)?.title == "Edited while signed out"
                    && b.task(changes.deleted) == nil && b.task(changes.created) != nil
            }
            #expect(try b.task(changes.edited)?.isCompleted == true)

            await a.cloud.signOut()
            try await signIn(a, email: secondEmail)
            #expect(a.cloud.profile == nil && a.cloud.setup?.profile.account.email == secondEmail)
            #expect(a.library.service === service)
            await a.cloud.connect(importLocal: false, activeService: a.library.service)
            #expect(a.cloud.profile?.account.email == secondEmail)
            #expect(try a.count == 0)
            await a.cloud.signOut()
            try await signIn(a, email: firstEmail)
            await a.cloud.connect(importLocal: false, activeService: a.library.service)
            #expect(try a.task(changes.remote) != nil)
            #expect(try a.task(changes.deleted) == nil)

            await a.cloud.signOut()
            try await signIn(a, email: secondEmail)
            await a.cloud.connect(importLocal: true, activeService: a.library.service)
            try await flush(a)
            #expect(try a.count == 3)
            #expect(try a.task(changes.edited)?.isCompleted == true)
            #expect(try a.task(changes.deleted) == nil)
        }
        a.cloud.engine?.stop()
        b.cloud.engine?.stop()
    }

    private func signIn(_ device: Device, email: String) async throws {
        try await device.cloud.signIn(email: email, password: "Pilot-local-fixture-2026",
                                      activeService: device.library.service)
    }

    private func flush(_ device: Device) async throws {
        let engine = try #require(device.cloud.engine)
        try await wait { engine.status == .upToDate && engine.pending == 0 }
    }

    private func wait(_ condition: () throws -> Bool) async throws {
        for _ in 0..<160 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let completed = try condition()
        try #require(completed)
    }
}
