import Foundation
import Testing
@testable import Planner

/// Проверяем отсутствие резидентной модели до запроса и все пути освобождения без настоящих весов.
@MainActor struct AssistantMemoryTests {
    @Test func installedModelAndOpeningChatDoNotLoadWeights() async throws {
        let backend = MemoryTestBackend()
        let fixture = try InstalledModelFixture(backend: backend); defer { fixture.clean() }
        let model = fixture.manager
        model.restoreIfInstalled(); model.restoreIfInstalled()
        #expect(model.canChat && model.state == .installed)
        #expect(await backend.prepares == 0)
        try await model.beginUse()
        #expect(model.inUse && model.state == .ready)
        #expect(await backend.prepares == 1)
        await model.endUse()
        #expect(await backend.trims == 1)
        await model.unloadNow()
        #expect(model.state == .installed && model.canChat)
    }
    @Test func installationOnlyVerifiesFilesAndDoesNotPrepareModel() async throws {
        let backend = MemoryTestBackend()
        let fixture = try InstalledModelFixture(backend: backend); defer { fixture.clean() }
        let model = fixture.manager
        model.install()
        while model.busy { await Task.yield() }
        #expect(model.state == .installed && model.canChat)
        #expect(await backend.prepares == 0)
        await model.disable()
    }
    @Test func idleDeadlineWaitsForResponseAndResetsAfterNextRequest() async throws {
        let backend = MemoryTestBackend()
        let fixture = try InstalledModelFixture(backend: backend); defer { fixture.clean() }
        let model = fixture.manager
        #expect(model.idleSeconds == 120)
        try await model.beginUse()
        await model.checkIdle(at: Date.now.addingTimeInterval(1000))
        #expect(model.state == .ready && model.inUse)
        await model.endUse()
        await model.checkIdle(at: Date.now.addingTimeInterval(119))
        #expect(model.state == .ready)
        try await model.beginUse()
        await model.checkIdle(at: Date.now.addingTimeInterval(1000))
        #expect(await backend.unloads == 0)
        await model.endUse()
        await model.checkIdle(at: Date.now.addingTimeInterval(121))
        #expect(model.state == .installed && model.canChat && model.releaseReason == .idle)
        #expect(await backend.prepares == 1)
        try await model.beginUse()
        #expect(await backend.prepares == 2)
        await model.endUse(); await model.unloadNow()
    }
    @Test func immediateAndNeverPoliciesPersistAndCanBeChangedWhileResident() async throws {
        let backend = MemoryTestBackend()
        let fixture = try InstalledModelFixture(backend: backend); defer { fixture.clean() }
        let model = fixture.manager
        model.idleSeconds = -1
        try await model.beginUse(); await model.endUse()
        await model.checkIdle(at: Date.now.addingTimeInterval(100000))
        #expect(model.state == .ready)
        model.idleSeconds = 0
        for _ in 0..<100 where model.state != .installed { try await Task.sleep(for: .milliseconds(1)) }
        #expect(model.state == .installed)
        try await model.beginUse(); await model.endUse()
        #expect(model.state == .installed && !model.inUse)
        model.idleSeconds = 180
        let reopened = ModelManager(backend: backend, directory: fixture.directory, defaults: fixture.defaults)
        #expect(reopened.idleSeconds == 180 && reopened.state == .installed)
        model.idleSeconds = .infinity
        #expect(model.idleSeconds == 120)
        await model.disable()
    }
    @Test func realIdleTimerReleasesWithoutClosingChat() async throws {
        let backend = MemoryTestBackend()
        let fixture = try InstalledModelFixture(backend: backend); defer { fixture.clean() }
        let model = fixture.manager
        model.idleSeconds = 0.01
        try await model.beginUse(); await model.endUse()
        for _ in 0..<100 where model.state != .installed { try await Task.sleep(for: .milliseconds(1)) }
        #expect(model.state == .installed && model.canChat)
        #expect(await backend.unloads == 1)
    }
    @Test func requestWaitsForManualUnloadBeforePreparingAgain() async throws {
        let backend = MemoryTestBackend(unloadDelay: true)
        let fixture = try InstalledModelFixture(backend: backend); defer { fixture.clean() }
        let model = fixture.manager
        try await model.beginUse(); await model.endUse()
        let release = Task { await model.unloadNow() }
        while model.state != .unloading { await Task.yield() }
        try await model.beginUse()
        await release.value
        #expect(model.state == .ready && model.inUse)
        #expect(await backend.prepares == 2)
        #expect(await backend.overlap == false)
        await model.endUse(); await model.unloadNow()
    }
    @Test func changedFilesAreReverifiedAndNeverDownloadedOnSend() async throws {
        let backend = MemoryTestBackend()
        let fixture = try InstalledModelFixture(backend: backend); defer { fixture.clean() }
        let model = fixture.manager
        try await model.beginUse(); await model.endUse(); await model.unloadNow()
        try Data("abd".utf8).write(to: fixture.directory.appending(path: "test.bin"), options: .atomic)
        do { try await model.beginUse(); Issue.record("Изменённые веса приняты") } catch {}
        #expect(!model.canChat && !model.inUse && model.state == .failed)
        #expect(await backend.prepares == 1)
    }
    @Test func pressureOverridesKeepResidentAndWaitsForActiveRequest() async throws {
        let backend = MemoryTestBackend()
        let fixture = try InstalledModelFixture(backend: backend); defer { fixture.clean() }
        let model = fixture.manager
        model.idleSeconds = -1
        var cancellations = 0
        model.cancelGeneration = { cancellations += 1 }
        try await model.beginUse()
        model.handleMemoryPressure()
        #expect(cancellations == 1 && model.inUse)
        #expect(await backend.unloads == 0)
        await model.endUse()
        #expect(model.state == .installed && model.canChat && model.releaseReason == .pressure)
        #expect(await backend.unloads == 1)
    }
    @Test func disablingDuringLoadWaitsForCancellationAndKeepsConversation() async throws {
        let backend = MemoryTestBackend(prepareDelay: true)
        let fixture = try InstalledModelFixture(backend: backend); defer { fixture.clean() }
        let store = AssistantStore(url: fixture.directory.appending(path: "conversation.json"))
        let service = AssistantService(model: fixture.manager, store: store)
        let context = AssistantContext(now: .now, timeZoneID: "Europe/Moscow", language: "ru",
            folders: [AssistantFolder(id: "inbox", name: "Входящие")], calendars: [], defaultFolderID: "inbox",
            defaultCalendarID: nil, taskID: nil, taskTitle: nil, durationMinutes: 60, reminderMinutes: nil)
        service.send("Проверка", context: context)
        while await backend.prepares == 0 { await Task.yield() }
        service.send("Повторный клик", context: context)
        await service.disableModel()
        #expect(!service.generating && !fixture.manager.inUse && fixture.manager.state == .disabled)
        #expect(service.current?.messages.count == 1 && service.current?.messages.first?.text == "Проверка")
        #expect(try store.load().threads.first?.messages.first?.text == "Проверка")
        #expect(await backend.prepares == 1)
    }
    @Test func cancellationDuringLoadingLeavesChatAvailableAndReleasesModel() async throws {
        let backend = MemoryTestBackend(prepareDelay: true)
        let fixture = try InstalledModelFixture(backend: backend); defer { fixture.clean() }
        let model = fixture.manager
        let load = Task { try await model.beginUse() }
        while await backend.prepares == 0 { await Task.yield() }
        load.cancel()
        do { try await load.value; Issue.record("Отмена не обработана") } catch {}
        #expect(model.canChat && !model.inUse && model.state == .installed)
        #expect(await backend.unloads == 1)
    }
}

actor MemoryTestBackend: LocalAIBackend {
    var prepares = 0
    var unloads = 0
    var trims = 0
    var unloading = false
    var overlap = false
    let prepareDelay: Bool
    let unloadDelay: Bool
    init(prepareDelay: Bool = false, unloadDelay: Bool = false) {
        self.prepareDelay = prepareDelay; self.unloadDelay = unloadDelay
    }
    func prepare(directory: URL) async throws {
        prepares += 1
        if unloading { overlap = true }
        if prepareDelay { try await Task.sleep(for: .seconds(60)) }
    }
    func unload() async {
        unloads += 1; unloading = true
        if unloadDelay { try? await Task.sleep(for: .milliseconds(20)) }
        unloading = false
    }
    func releaseTransientMemory() async { trims += 1 }
    func respond(instructions: String, prompt: String) async throws -> String { "{\"message\":\"ok\",\"actions\":[]}" }
}
