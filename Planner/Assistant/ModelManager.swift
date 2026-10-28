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

/// Загрузка не зависит от видимости панели. Прогресс относится к байтам, проверка — отдельное состояние.
@MainActor @Observable
final class ModelManager {
    enum State: Equatable { case absent, downloading, verifying, preparing, ready, failed, disabled }
    var state: State = .absent
    var received: Int64 = 0
    var total: Int64 = 0
    var error: String?
    var accepted = false
    private let defaults: UserDefaults
    var enabled: Bool { didSet { defaults.set(enabled, forKey: "assistantEnabled") } }
    let backend: any LocalAIBackend
    let directory: URL
    var displayName: String { ((manifestOverride ?? (try? ModelManifest.bundled()))?.id.components(separatedBy: "/").last ?? "Qwen3.5-2B-4bit").replacingOccurrences(of: "-4bit", with: " · 4-bit") }
    var modelURL: URL { URL(string: "https://huggingface.co/" + ((manifestOverride ?? (try? ModelManifest.bundled()))?.id ?? "mlx-community/Qwen3.5-2B-4bit"))! }
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var downloader: (any ModelFileDownloading)?
    @ObservationIgnored private let downloaderFactory: @Sendable () -> any ModelFileDownloading
    private let manifestOverride: ModelManifest?
    private var generation = UUID()
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored var cancelGeneration: (() -> Void)?
    private var pressureRequested = false
    var inUse = false
    var busy: Bool { [.downloading, .verifying, .preparing].contains(state) }
    var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }

    init(backend: any LocalAIBackend = MLXAssistantBackend(), directory: URL = AssistantPaths.model, defaults: UserDefaults = .standard, manifest: ModelManifest? = nil, downloaderFactory: @escaping @Sendable () -> any ModelFileDownloading = { ModelDownload() }) {
        self.backend = backend; self.directory = directory; self.defaults = defaults
        self.manifestOverride = manifest; self.downloaderFactory = downloaderFactory
        enabled = defaults.bool(forKey: "assistantEnabled")
        accepted = FileManager.default.fileExists(atPath: directory.appending(path: "accepted.json").path)
        total = manifest?.bytes ?? (try? ModelManifest.bundled().bytes) ?? 1_750_000_000
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, state == .ready else { return }
                pressureRequested = true
                if inUse { cancelGeneration?() } else { releaseIfNeeded() }
            }
        }
        source.resume(); pressureSource = source
    }
    func releaseIfNeeded() {
        guard pressureRequested, !inUse else { return }
        pressureRequested = false; state = .failed
        error = "Модель выгружена из-за нехватки памяти. Закройте лишние приложения и включите помощника снова."
        Task { await backend.unload() }
    }
    func restoreIfInstalled() {
        guard state == .absent, accepted, enabled,
              FileManager.default.fileExists(atPath: directory.appending(path: "ready.json").path) else { return }
        install()
    }
    func install() {
        guard !busy, state != .ready else { return }
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
                    let valid = try await Task.detached { try Self.valid(target, file: file) }.value
                    if valid { received += file.bytes; continue }
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
                    guard try await Task.detached(operation: { try Self.valid(target, file: file) }).value else {
                        try? FileManager.default.removeItem(at: target)
                        throw AssistantFailure(message: "Проверка модели не пройдена. Повторите загрузку.")
                    }
                    received = base + file.bytes
                }
                try Task.checkCancellation()
                try Data(manifest.revision.utf8).write(to: directory.appending(path: "ready.json"), options: .atomic)
                state = .preparing
                try await backend.prepare(directory: directory)
                try Task.checkCancellation()
                guard generation == token else { return }
                state = .ready
            } catch {
                guard generation == token else { return }
                if Task.isCancelled { state = .absent }
                else { self.error = error.localizedDescription; state = .failed }
            }
            downloader = nil; job = nil
        }
    }
    func cancel() {
        let preparing = state == .preparing
        generation = UUID(); job?.cancel(); job = nil; downloader?.cancel(); downloader = nil; state = .absent
        if preparing { Task { await backend.unload() } }
    }
    func disable() async { enabled = false; cancel(); state = .preparing; await backend.unload(); state = .disabled }
    func remove() async {
        enabled = false; cancel(); state = .verifying; await backend.unload()
        do { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }; accepted = false; state = .absent }
        catch { self.error = error.localizedDescription; state = .failed }
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
