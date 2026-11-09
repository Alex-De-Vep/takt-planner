import Foundation
import CryptoKit
import Observation

struct ModelManifest: Decodable, Sendable {
    struct File: Decodable, Sendable { let name: String; let bytes: Int64; let sha256: String }
    let id: String
    let revision: String
    let files: [File]
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource: "ModelManifest", withExtension: "json") else {
            throw AssistantFailure(message: "Не найден список файлов модели.")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

/// Файлы модели и её присутствие в RAM независимы: открытие чата не загружает веса.
@MainActor @Observable
final class ModelManager {
    enum State: Equatable { case absent, downloading, verifying, installed, preparing, ready, unloading, failed, disabled }
    enum ReleaseReason { case idle, manual, pressure }
    var state: State = .absent
    var received: Int64 = 0
    var total: Int64 = 0
    var error: String?
    var accepted = false
    private(set) var installed = false
    private(set) var releaseReason: ReleaseReason?
    private let defaults: UserDefaults
    var enabled: Bool { didSet { defaults.set(enabled, forKey: "assistantEnabled") } }
    /// -1 — до выхода, 0 — сразу после ответа; остальное — секунды простоя.
    var idleSeconds: Double {
        didSet {
            let normalized = idleSeconds.isFinite ? (idleSeconds < 0 ? -1 : min(idleSeconds, 3600)) : 120
            if idleSeconds != normalized { idleSeconds = normalized }
            defaults.set(idleSeconds, forKey: "assistantIdleSeconds")
            scheduleIdleRelease()
        }
    }
    let backend: any LocalAIBackend
    let directory: URL
    var displayName: String { ((manifestOverride ?? (try? ModelManifest.bundled()))?.id.components(separatedBy: "/").last ?? "Qwen3.5-4B-4bit").replacingOccurrences(of: "-4bit", with: " · 4-bit") }
    var modelURL: URL { URL(string: "https://huggingface.co/" + ((manifestOverride ?? (try? ModelManifest.bundled()))?.id ?? "mlx-community/Qwen3.5-4B-4bit"))! }
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var idleJob: Task<Void, Never>?
    @ObservationIgnored private var unloadJob: Task<Void, Never>?
    @ObservationIgnored private var downloader: (any ModelFileDownloading)?
    @ObservationIgnored private let downloaderFactory: @Sendable () -> any ModelFileDownloading
    private let manifestOverride: ModelManifest?
    private var generation = UUID()
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored var cancelGeneration: (() -> Void)?
    private var pressureRequested = false
    private var finishedAt: Date?
    private(set) var inUse = false
    var busy: Bool { [.downloading, .verifying, .preparing, .unloading].contains(state) }
    var canChat: Bool { enabled && installed && job == nil }
    var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }

    // SHA-256 не повторяем при каждом пробуждении. Изменение атрибутов файла сбрасывает проверку.
    private struct FileStamp: Equatable {
        let size: UInt64
        let modified: Date
        let changed: Date
        let inode: UInt64
    }
    private var verified: [String: FileStamp] = [:]
    private func stamp(_ url: URL) throws -> FileStamp {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        let values = try url.resourceValues(forKeys: [.attributeModificationDateKey])
        guard let size = a[.size] as? NSNumber, let date = a[.modificationDate] as? Date,
              let changed = values.attributeModificationDate, let inode = a[.systemFileNumber] as? NSNumber else {
            throw AssistantFailure(message: "Не удалось проверить файлы модели. Повторите загрузку.")
        }
        return FileStamp(size: size.uint64Value, modified: date, changed: changed, inode: inode.uint64Value)
    }
    private func verify(_ file: ModelManifest.File) async throws -> Bool {
        let url = directory.appending(path: file.name)
        guard let before = try? stamp(url) else { return false }
        if verified[file.name] == before { return true }
        let valid = try await Task.detached { try Self.valid(url, file: file) }.value
        try Task.checkCancellation()
        guard valid, let after = try? stamp(url), before == after else { return false }
        verified[file.name] = after
        return true
    }
    init(backend: any LocalAIBackend = MLXAssistantBackend(), directory: URL = AssistantPaths.model, defaults: UserDefaults = .standard, manifest: ModelManifest? = nil, downloaderFactory: @escaping @Sendable () -> any ModelFileDownloading = { ModelDownload() }) {
        self.backend = backend; self.directory = directory; self.defaults = defaults
        self.manifestOverride = manifest; self.downloaderFactory = downloaderFactory
        enabled = defaults.bool(forKey: "assistantEnabled")
        idleSeconds = defaults.object(forKey: "assistantIdleSeconds") == nil ? 120 : defaults.double(forKey: "assistantIdleSeconds")
        if !idleSeconds.isFinite { idleSeconds = 120 }
        else { idleSeconds = idleSeconds < 0 ? -1 : min(idleSeconds, 3600) }
        accepted = FileManager.default.fileExists(atPath: directory.appending(path: "accepted.json").path)
        installed = accepted && FileManager.default.fileExists(atPath: directory.appending(path: "ready.json").path)
        state = installed ? (enabled ? .installed : .disabled) : .absent
        total = manifest?.bytes ?? (try? ModelManifest.bundled().bytes) ?? 3_061_129_077
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.handleMemoryPressure() }
        }
        source.resume(); pressureSource = source
    }
    func handleMemoryPressure() {
        guard inUse || state == .ready else { return }
        pressureRequested = true
        if inUse { cancelGeneration?() }
        else { startUnloading(reason: .pressure) }
    }
    /// Восстановление панели меняет только состояние интерфейса; тяжёлая загрузка ждёт сообщения.
    func restoreIfInstalled() {
        guard enabled, installed, state == .absent else { return }
        state = .installed
    }
    func install() {
        guard !busy, !inUse, state != .ready else { return }
        accepted = true; enabled = true; error = nil; state = .verifying
        let token = UUID(); generation = token
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let manifest = try manifestOverride ?? ModelManifest.bundled()
                total = manifest.bytes; received = 0
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(manifest.revision.utf8).write(to: directory.appending(path: "accepted.json"), options: .atomic)
                let free = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? Int64.max
                let existing = manifest.files.reduce(Int64(0)) { sum, f in
                    sum + ((try? directory.appending(path: f.name).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
                }
                guard free > max(0, manifest.bytes - existing) + 512_000_000 else { throw AssistantFailure(message: "Недостаточно места для модели.") }
                for file in manifest.files {
                    try Task.checkCancellation()
                    let target = directory.appending(path: file.name)
                    if try await verify(file) { received += file.bytes; continue }
                    state = .downloading
                    let base = received
                    let transfer = downloaderFactory(); downloader = transfer
                    let url = URL(string: "https://huggingface.co/\(manifest.id)/resolve/\(manifest.revision)/\(file.name)")!
                    try await transfer.download(url: url, to: target) { [weak self] bytes in
                        Task { @MainActor [weak self] in
                            guard let self, generation == token else { return }
                            received = base + min(file.bytes, bytes)
                        }
                    }
                    state = .verifying
                    guard try await verify(file) else {
                        try? FileManager.default.removeItem(at: target)
                        throw AssistantFailure(message: "Проверка модели не пройдена. Повторите загрузку.")
                    }
                    received = base + file.bytes
                }
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                try Data(manifest.revision.utf8).write(to: directory.appending(path: "ready.json"), options: .atomic)
                installed = true; state = .installed
            } catch {
                guard generation == token else { return }
                if Task.isCancelled { state = installed ? .installed : .absent }
                else { self.error = error.localizedDescription; state = .failed }
            }
            downloader = nil; job = nil
        }
    }
    /// Резервирование охватывает проверку и подготовку: таймер не выгружает начавшийся запрос.
    func beginUse() async throws {
        guard !inUse, canChat else { throw AssistantFailure(message: "Сначала загрузите модель.") }
        inUse = true; idleJob?.cancel(); idleJob = nil; error = nil; releaseReason = nil
        do {
            if let unloadJob { await unloadJob.value }
            try Task.checkCancellation()
            if state != .ready {
                state = .verifying
                let manifest = try manifestOverride ?? ModelManifest.bundled()
                for file in manifest.files {
                    guard try await verify(file) else {
                        installed = false
                        throw AssistantFailure(message: "Проверка модели не пройдена. Повторите загрузку.")
                    }
                }
                try Task.checkCancellation()
                state = .preparing
                try await backend.prepare(directory: directory)
                try Task.checkCancellation()
                if pressureRequested { throw CancellationError() }
                state = .ready
            }
        } catch {
            await backend.unload()
            inUse = false
            state = installed ? .installed : .failed
            if pressureRequested { releaseReason = .pressure }
            pressureRequested = false
            throw error
        }
    }
    func endUse() async {
        guard inUse else { return }
        // Сессия завершилась: её KV-кеш и временные буферы больше не нужны.
        await backend.releaseTransientMemory()
        inUse = false; finishedAt = .now
        if pressureRequested { startUnloading(reason: .pressure) }
        else if idleSeconds == 0 { startUnloading(reason: .idle) }
        else { scheduleIdleRelease() }
        if let unloadJob { await unloadJob.value }
    }
    private func scheduleIdleRelease() {
        idleJob?.cancel(); idleJob = nil
        guard state == .ready, !inUse, idleSeconds >= 0, let finishedAt else { return }
        let remaining = max(0, idleSeconds - Date.now.timeIntervalSince(finishedAt))
        idleJob = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            await checkIdle()
        }
    }
    /// Отдельная точка проверки позволяет тестировать дедлайн без ожидания реальных минут.
    func checkIdle(at date: Date = .now) async {
        guard state == .ready, !inUse, idleSeconds >= 0, let finishedAt,
              date.timeIntervalSince(finishedAt) >= idleSeconds else { return }
        startUnloading(reason: .idle)
        if let unloadJob { await unloadJob.value }
    }
    private func startUnloading(reason: ReleaseReason) {
        guard !inUse, unloadJob == nil else { return }
        idleJob?.cancel(); idleJob = nil
        state = .unloading; releaseReason = reason; pressureRequested = false
        // Пробуждение ждёт окончания этой же операции: загрузка и выгрузка не пересекаются.
        unloadJob = Task { [self] in
            await backend.unload()
            state = installed ? (enabled ? .installed : .disabled) : .absent
            unloadJob = nil
        }
    }
    func unloadNow() async {
        guard !inUse, state == .ready || state == .unloading else { return }
        if unloadJob == nil { startUnloading(reason: .manual) }
        if let unloadJob { await unloadJob.value }
    }
    func cancel() {
        generation = UUID(); job?.cancel(); job = nil; downloader?.cancel(); downloader = nil
        state = installed ? (enabled ? .installed : .disabled) : .absent
    }
    func disable() async {
        guard !inUse else { return }
        enabled = false; cancel(); idleJob?.cancel(); idleJob = nil
        if let unloadJob { await unloadJob.value }
        await backend.unload(); state = .disabled
    }
    func remove() async {
        guard !inUse else { return }
        await disable(); state = .verifying
        do {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            installed = false; verified = [:]; accepted = false; state = .absent
        } catch { self.error = error.localizedDescription; state = .failed }
    }
    nonisolated static func valid(_ url: URL, file: ModelManifest.File) throws -> Bool {
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.bytes) else { return false }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }
}

/// URLSession сохраняет resumeData; завершённый файл атомарно переносится из временного каталога.
protocol ModelFileDownloading: Sendable {
    func download(url: URL, to target: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
    func cancel()
}
final class ModelDownload: NSObject, URLSessionDownloadDelegate, ModelFileDownloading, @unchecked Sendable {
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var target: URL!
    private var progress: (@Sendable (Int64) -> Void)?
    private let lock = NSLock()
    func download(url: URL, to target: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); defer { lock.unlock() }
                self.continuation = continuation; self.target = target; self.progress = progress
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForResource = 24 * 3600
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let resumeURL = target.appendingPathExtension("resume")
                if let data = try? Data(contentsOf: resumeURL) { task = session.downloadTask(withResumeData: data) }
                else { task = session.downloadTask(with: url) }
                if Task.isCancelled { task?.cancel() } else { task?.resume() }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() { lock.lock(); let task = task; lock.unlock(); task?.cancel() }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress?(totalBytesWritten)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                throw AssistantFailure(message: "Не удалось скачать модель. Проверьте соединение и повторите.")
            }
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: location, to: target)
            try? FileManager.default.removeItem(at: target.appendingPathExtension("resume"))
            finish(nil)
        } catch { finish(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? resume.write(to: target.appendingPathExtension("resume"), options: .atomic)
            } else { try? FileManager.default.removeItem(at: target.appendingPathExtension("resume")) }
            finish(error)
        }
    }
    private func finish(_ error: Error?) {
        lock.lock(); let continuation = continuation; self.continuation = nil; lock.unlock()
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        session?.finishTasksAndInvalidate()
    }
}
