import AppKit
import Observation

@MainActor @Observable
final class NoteBrowserCall {
    enum Phase: String {
        case waiting, recording, paused, stopping
    }

    enum MicrophoneState: String { case pending, available, unavailable }

    private(set) var waitingMessage = "Выберите вкладку звонка в Chrome."
    private(set) var microphoneState = MicrophoneState.pending
    private(set) var tabLevel: Float = 0
    let noteID: UUID
    let file: URL
    private(set) var phase = Phase.waiting
    private(set) var microphone: Float = 0
    private(set) var duration: TimeInterval = 0

    @ObservationIgnored private let token = UUID().uuidString
    @ObservationIgnored private let russian: Bool
    @ObservationIgnored private let onFinish: (Bool, String?) -> Void
    @ObservationIgnored private var bridge: NoteCallBridge?
    @ObservationIgnored private var audio: NoteCallAudio?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var deadline = ContinuousClock.now + .seconds(180)
    @ObservationIgnored private var lastContact = ContinuousClock.now
    @ObservationIgnored private var nextChunk = 0
    @ObservationIgnored private var writtenFrames = 0
    @ObservationIgnored private var keepTail = false
    @ObservationIgnored private var finished = false

    init(noteID: UUID, file: URL, russian: Bool, onFinish: @escaping (Bool, String?) -> Void) {
        self.noteID = noteID
        self.file = file
        self.russian = russian
        self.onFinish = onFinish
    }

    func openChrome() throws {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            throw AssistantFailure(message: "Установите Google Chrome для записи звонка.")
        }
        let bridge = try NoteCallBridge { [weak self] request in
            self?.respond(to: request) ?? .init(status: "410 Gone")
        }
        self.bridge = bridge
        bridge.start(ready: { [weak self] port in
            guard let self, !finished, let url = URL(string: "http://127.0.0.1:\(port)/\(token)/") else { return }
            Task {
                do {
                    _ = try await NSWorkspace.shared.open([url], withApplicationAt: chrome,
                                                          configuration: NSWorkspace.OpenConfiguration())
                } catch { self.finish("Не удалось открыть страницу записи в Chrome.") }
            }
        }, failed: { [weak self] in self?.finish("Соединение с Chrome прервалось.") })
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.checkConnection()
            }
        }
    }

    func togglePause() {
        switch phase {
        case .recording:
            phase = .paused
            microphone = 0
            tabLevel = 0
        case .paused: phase = .recording
        default: break
        }
    }

    func stop() {
        switch phase {
        case .waiting: finish()
        case .recording, .paused:
            keepTail = phase == .recording
            phase = .stopping
            deadline = .now + .seconds(5)
            if bridge == nil { finish() }
        case .stopping: break
        }
    }

    func finishForTermination() { finish() }

    private func checkConnection() {
        switch phase {
        case .waiting where .now >= deadline: finish("Время выбора вкладки истекло.")
        case .stopping where .now >= deadline: finish()
        case .recording where .now - lastContact > .seconds(15),
             .paused where .now - lastContact > .seconds(15):
            finish("Соединение с Chrome прервалось.")
        default: break
        }
    }

    private func respond(to request: NoteCallRequest) -> NoteCallBridge.Response {
        guard !finished, request.path.hasPrefix("/" + token + "/") else { return .init(status: "404 Not Found") }
        let route = String(request.path.dropFirst(token.count + 2))
        if request.method == "GET" {
            switch route {
            case "": return resource("note-call", ext: "html", type: "text/html; charset=utf-8")
            case "capture.js": return resource("note-call-capture", ext: "js", type: "text/javascript; charset=utf-8")
            case "processor.js": return resource("note-call-processor", ext: "js", type: "text/javascript; charset=utf-8")
            case "state" where request.headers["x-takt-call"] == "1":
                lastContact = .now
                if phase == .waiting { deadline = .now + .seconds(180) }
                return stateResponse()
            default: return .init(status: "404 Not Found")
            }
        }
        lastContact = .now
        do {
            switch route {
            case "setup" where phase == .waiting:
                switch String(decoding: request.body, as: UTF8.self) {
                case "chooseTab": waitingMessage = "Выберите вкладку встречи в Chrome и подтвердите доступ."
                case "sourceUnavailable": waitingMessage = "Chrome не смог начать захват выбранной вкладки. Откройте вкладку встречи и выберите её ещё раз."
                case "tabAudio": waitingMessage = "Выберите вкладку встречи и включите передачу звука вкладки."
                case "audioSetup": waitingMessage = "Chrome не смог подготовить звук. Повторите выбор вкладки."
                default: return .init(status: "400 Bad Request")
                }
                deadline = .now + .seconds(180)
            case "begin" where phase == .waiting && request.body.isEmpty:
                try beginAudio()
            case "chunk" where phase != .waiting:
                guard let sequence = request.headers["x-takt-chunk"].flatMap(Int.init), sequence >= 0,
                      !request.body.isEmpty, request.body.count.isMultiple(of: 4) else {
                    return .init(status: "400 Bad Request")
                }
                if sequence < nextChunk { return stateResponse() }
                guard sequence == nextChunk else { return .init(status: "409 Conflict") }
                nextChunk += 1
                if let state = request.headers["x-takt-microphone"].flatMap(MicrophoneState.init(rawValue:)) {
                    microphoneState = state
                }
                try appendAudio(request.body)
            case "finish" where phase != .waiting && request.body.isEmpty:
                finish()
                return .init(body: Data("finished".utf8))
            case "failed" where phase != .waiting && request.body.isEmpty:
                finish("Соединение с Chrome прервалось.")
                return .init(body: Data("finished".utf8))
            default: return .init(status: "409 Conflict")
            }
            return stateResponse()
        } catch {
            finish(phase == .waiting ? "Не удалось начать запись звонка." : "Не удалось сохранить звук звонка.")
            return .init(status: "500 Internal Server Error")
        }
    }

    private func beginAudio() throws {
        audio = try NoteCallAudio(url: file)
        phase = .recording
    }

    private func appendAudio(_ data: Data) throws {
        guard phase == .recording || (phase == .stopping && keepTail), let audio else { return }
        let result = try audio.append(data)
        microphone = result.microphone
        tabLevel = result.tab
        writtenFrames += result.frames
        duration = Double(writtenFrames) / Double(NoteCallAudio.sampleRate)
    }

    #if DEBUG
    /// UI-тест использует тот же файл и состояния, что и Chrome, с сигналом вместо вкладки.
    func startTestCapture(packet: Data = NoteRecordingTestAudio.tone()) throws {
        try beginAudio()
        microphoneState = .available
        try appendAudio(packet)
    }
    #endif

    private func stateResponse() -> NoteCallBridge.Response { .init(body: Data(phase.rawValue.utf8)) }

    private func resource(_ name: String, ext: String, type: String) -> NoteCallBridge.Response {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else { return .init(status: "404 Not Found") }
        if ext == "html" {
            let html = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "@@LANG@@", with: russian ? "ru" : "en")
            return .init(type: type, body: Data(html.utf8))
        }
        return .init(type: type, body: data)
    }

    private func finish(_ error: String? = nil) {
        guard !finished else { return }
        finished = true
        watchdog?.cancel()
        audio?.close()
        audio = nil
        if let bridge {
            // Даём ответу о завершении уйти в Chrome перед закрытием сокета.
            Task { try? await Task.sleep(for: .milliseconds(400)); bridge.close() }
        }
        bridge = nil
        onFinish(writtenFrames > 0, error)
    }
}
