import Foundation
import Observation

@MainActor @Observable
final class SyncEngine {
    enum Status: Equatable { case waiting, syncing, upToDate, signIn, failed(String) }

    var status: Status = .waiting
    private(set) var pending = 0
    let repository: SyncRepository
    private let api: SyncHTTP
    private var timer: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var running = false
    private var stopped = false
    private var blockedUntil = Date.distantPast
    private var transientFailures = 0

    init(repository: SyncRepository, api: SyncHTTP) {
        self.repository = repository
        self.api = api
        pending = (try? repository.counts().pending) ?? 0
    }

    func start() {
        guard timer == nil, !stopped else { return }
        wake()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.wake()
            }
        }
    }

    func stop() {
        stopped = true
        timer?.cancel()
        scheduled?.cancel()
        timer = nil
        scheduled = nil
    }

    func wake(after delay: Duration = .zero) {
        pending = (try? repository.counts().pending) ?? pending
        guard !stopped else { return }
        if running { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.run()
        }
    }

    private func run() async {
        guard !stopped, !running, Date() >= blockedUntil else { return }
        running = true
        status = .syncing
        defer { running = false }
        do {
            try await synchronize()
            transientFailures = 0
            let counts = try repository.counts()
            pending = counts.pending
            status = counts.failed > 0 ? .failed("Часть изменений отклонена сервером.") :
                (counts.pending == 0 ? .upToDate : .waiting)
            if counts.pending > counts.failed { Task { [weak self] in self?.wake(after: .seconds(2)) } }
        } catch is CancellationError {
            return
        } catch SyncProblem.signInRequired {
            status = .signIn
        } catch let failure as SyncHTTPFailure where failure.status == 429 {
            blockedUntil = .now.addingTimeInterval(Double(max(1, failure.problem.retryAfterSeconds ?? 60)))
            status = .waiting
        } catch let error as URLError {
            scheduleBackoff()
            status = [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut].contains(error.code)
                ? .waiting : .failed(error.localizedDescription)
        } catch {
            scheduleBackoff()
            status = .failed(error.localizedDescription)
        }
    }

    private func scheduleBackoff() {
        transientFailures = min(transientFailures + 1, 7)
        blockedUntil = .now.addingTimeInterval(min(300, pow(2, Double(transientFailures))) + Double.random(in: 0...1))
    }

    /// Используется и рабочим расписанием, и приёмкой на двух независимых хранилищах.
    func synchronize() async throws {
        let config: SyncConfig = try await api.publicRequest("/v1/config")
        try checkActive()
        guard config.protocolVersion == 1 else { throw SyncProblem.incompatibleProtocol }
        if let server = SyncWire.date(config.serverTime) {
            repository.serverClockOffset = server.timeIntervalSinceNow
        }

        try await pull()
        let batches = try SyncWire.batches(repository.pendingOperations(), limits: config.limits)
        for batch in batches {
            try checkActive()
            // Удаление, полученное между проходами, может убрать ожидающие операции.
            let available = Set(try repository.pendingOperations().map(\.operationId))
            let send = batch.filter { available.contains($0.operationId) }
            guard !send.isEmpty else { continue }
            let result: SyncMutationResults = try await api.authorized("/v1/sync/mutations", method: "POST",
                                                                      body: SyncHTTP.payload(SyncBatch(mutations: send)))
            try checkActive()
            try repository.accept(result, sent: send)
        }
        try await pull()
    }

    private func pull() async throws {
        guard repository.cursor != nil else { try await snapshot(); return }
        do {
            while let cursor = repository.cursor {
                let page: SyncChanges = try await api.authorized("/v1/sync/changes?cursor=" + cursor)
                try checkActive()
                try repository.applyChanges(page)
                if !page.hasMore { break }
            }
        } catch let error as SyncHTTPFailure where ["cursor_expired", "invalid_cursor"].contains(error.problem.code) {
            try await snapshot()
        }
    }

    private func snapshot() async throws {
        let value: SyncSnapshot = try await api.authorized("/v1/sync/snapshot")
        try checkActive()
        try repository.applySnapshot(value)
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        if stopped { throw CancellationError() }
    }
}
