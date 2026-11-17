import Foundation
import Observation

@MainActor @Observable
final class SyncEngine {
    enum Status: Equatable { case waiting, syncing, upToDate, signIn, failed(String) }

    private struct Work: OptionSet {
        let rawValue: Int
        static let tasks = Work(rawValue: 1)
        static let notes = Work(rawValue: 2)
        static let all: Work = [.tasks, .notes]
    }

    var status: Status = .waiting
    private(set) var pending = 0
    let repository: SyncRepository
    private let api: SyncHTTP
    private let notes: NoteStore?
    private var timer: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var running = false
    private var queued: Work = []
    private var runAt: Date?
    private var noteLimit: Int?
    private var noteEvents: Task<Void, Never>?
    private var noteStreamReady = false
    private var stopped = false
    private var blockedUntil = Date.distantPast
    private var transientFailures = 0

    init(repository: SyncRepository, api: SyncHTTP, notes: NoteStore? = nil) {
        self.repository = repository
        self.api = api
        self.notes = notes
        pending = (try? repository.counts().pending) ?? 0
    }

    func start() {
        guard timer == nil, !stopped else { return }
        // New notes can be created before the first configuration request finishes.
        notes?.awaitingCloudNoteFormat = true
        wake()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.wakeTasks()
            }
        }
    }

    func stop() {
        stopped = true
        notes?.syncEnabled = false
        notes?.awaitingCloudNoteFormat = false
        notes?.sharedFormatLimit = nil
        noteEvents?.cancel()
        noteEvents = nil
        noteStreamReady = false
        timer?.cancel()
        scheduled?.cancel()
        timer = nil
        scheduled = nil
    }

    func wake(after delay: Duration = .zero) {
        enqueue(.all, after: delay)
    }

    func wakeTasks(after delay: Duration = .zero) {
        enqueue(noteStreamReady ? .tasks : .all, after: delay)
    }

    func wakeNotes(after delay: Duration = .zero) {
        enqueue(.notes, after: delay)
    }

    private func enqueue(_ work: Work, after delay: Duration) {
        guard !stopped else { return }
        if work.contains(.tasks) { pending = (try? repository.counts().pending) ?? pending }
        let parts = delay.components
        let requested = Date.now.addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        runAt = min(runAt ?? requested, requested)
        queued.formUnion(work)
        schedule()
    }

    private func schedule() {
        guard !stopped, !running, let runAt else { return }
        let delay = max(0, max(runAt, blockedUntil).timeIntervalSinceNow)
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.run()
        }
    }

    private func run() async {
        guard !stopped, !running else { return }
        let work = queued
        queued = []
        runAt = nil
        running = true
        status = .syncing
        defer {
            running = false
            scheduled = nil
            schedule()
        }
        do {
            if work.contains(.tasks) || (work.contains(.notes) && notes != nil && noteLimit == nil) {
                try await synchronize(includeNotes: work.contains(.notes))
            } else if work.contains(.notes) {
                try await syncNotes()
            }
            transientFailures = 0
            let counts = try repository.counts()
            pending = counts.pending
            status = counts.failed > 0 ? .failed("Часть изменений отклонена сервером.") :
                (counts.pending == 0 ? .upToDate : .waiting)
            if counts.pending > counts.failed { enqueue(.tasks, after: .seconds(2)) }
        } catch is CancellationError {
            return
        } catch SyncProblem.signInRequired {
            status = .signIn
        } catch let failure as SyncHTTPFailure where failure.status == 429 {
            blockedUntil = .now.addingTimeInterval(Double(max(1, failure.problem.retryAfterSeconds ?? 60)))
            enqueue(work, after: .zero)
            status = .waiting
        } catch let error as URLError {
            scheduleBackoff()
            enqueue(work, after: .zero)
            status = [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut].contains(error.code)
                ? .waiting : .failed(error.localizedDescription)
        } catch let failure as SyncHTTPFailure where failure.status < 500 {
            status = .failed(failure.localizedDescription)
        } catch SyncProblem.oversizedMutation {
            status = .failed(SyncProblem.oversizedMutation.localizedDescription)
        } catch SyncProblem.incompatibleProtocol {
            status = .failed(SyncProblem.incompatibleProtocol.localizedDescription)
        } catch {
            scheduleBackoff()
            enqueue(work, after: .zero)
            status = .failed(error.localizedDescription)
        }
    }

    private func scheduleBackoff() {
        transientFailures = min(transientFailures + 1, 7)
        blockedUntil = .now.addingTimeInterval(min(300, pow(2, Double(transientFailures))) + Double.random(in: 0...1))
    }

    /// Используется и рабочим расписанием, и приёмкой на двух независимых хранилищах.
    func synchronize(includeNotes: Bool = true) async throws {
        let config: SyncConfig = try await api.publicRequest("/v1/config")
        try checkActive()
        guard config.protocolVersion == 1 else { throw SyncProblem.incompatibleProtocol }
        noteLimit = config.limits.maxNoteBytes
        notes?.syncEnabled = noteLimit != nil
        notes?.sharedFormatLimit = (config.limits.maxNoteFormatVersion ?? 0) >= SharedNoteText.currentVersion
            ? config.limits.maxNoteBytes : nil
        notes?.awaitingCloudNoteFormat = false
        if timer != nil {
            configureNoteEvents(enabled: notes != nil && noteLimit != nil && config.limits.noteEventsVersion == 1)
        }
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
        if includeNotes { try await syncNotes() }
    }

    private func syncNotes() async throws {
        guard let notes, let noteLimit else { return }
        let retry = try await NoteSync(store: notes, api: api).synchronize(maxBytes: noteLimit, checkActive: checkActive)
        if retry { enqueue(.notes, after: .seconds(2)) }
    }

    private func configureNoteEvents(enabled: Bool) {
        guard enabled else {
            noteEvents?.cancel()
            noteEvents = nil
            noteStreamReady = false
            return
        }
        guard noteEvents == nil else { return }

        let api = self.api
        noteEvents = Task { [weak self] in
            var backoff = 1
            while !Task.isCancelled {
                let started = ContinuousClock.now
                var retryAfter = 0
                do {
                    try await api.watchNoteEvents { [weak self] event in
                        await self?.receiveNoteEvent(event)
                    }
                } catch let failure as SyncHTTPFailure {
                    retryAfter = failure.problem.retryAfterSeconds ?? 0
                } catch SyncProblem.signInRequired {
                    if !Task.isCancelled {
                        self?.noteStreamReady = false
                        self?.noteEvents = nil
                        self?.status = .signIn
                    }
                    return
                } catch {
                    // The periodic sync covers any changes until the subscription is back.
                }

                guard !Task.isCancelled else { return }
                self?.noteStreamReady = false
                if ContinuousClock.now - started >= .seconds(30) { backoff = 1 }
                do { try await Task.sleep(for: .seconds(max(backoff, retryAfter))) } catch { return }
                backoff = min(backoff * 2, 60)
            }
        }
    }

    private func receiveNoteEvent(_ event: NoteStreamEvent) {
        guard !stopped, !Task.isCancelled else { return }
        switch event {
        case .ready where !noteStreamReady:
            noteStreamReady = true
            wakeNotes()
        case .changed where noteStreamReady:
            wakeNotes(after: .milliseconds(250))
        default:
            break
        }
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
