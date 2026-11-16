import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class NoteVoiceRecording {
    struct Draft {
        let file: URL
        var transcript: String?
        var isCall = false
        var pieces: [URL]?
        var pieceTranscripts: [String?] = []
        var saved = false
    }

    private(set) var drafts: [UUID: Draft] = [:]
    private(set) var recordingID: UUID?
    private(set) var startedAt: Date?
    private(set) var preparing = false
    private(set) var browserCall: NoteBrowserCall?

    var isBusy: Bool { preparing || recordingID != nil || browserCall != nil }
    private(set) var transcribing: Set<UUID> = []
    private(set) var errors: [UUID: String] = [:]
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private let files = RecordingFiles()

    func start(_ noteID: UUID) async {
        guard !isBusy, drafts[noteID] == nil else { return }
        preparing = true
        errors[noteID] = nil
        defer { preparing = false }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            errors[noteID] = "Разрешите доступ к микрофону в системных настройках."
            return
        }
        let file = files.newRecording()
        do {
            try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let recorder = try AVAudioRecorder(url: file, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ])
            // Ограничение держит размер файла ниже лимита загрузки первой версии.
            guard recorder.record(forDuration: 30 * 60) else { throw AssistantFailure(message: "Не удалось начать запись.") }
            self.recorder = recorder
            recordingID = noteID
            startedAt = .now
            drafts[noteID] = Draft(file: file)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30 * 60))
                if self?.drafts[noteID]?.file == file, self?.recordingID == noteID { self?.stop() }
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            errors[noteID] = "Не удалось начать запись."
        }
    }

    func startCall(_ noteID: UUID, russian: Bool) {
        guard !isBusy, drafts[noteID] == nil else { return }
        errors[noteID] = nil
        let file = files.newRecording()
        do {
            try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let call = NoteBrowserCall(noteID: noteID, file: file, russian: russian) { [weak self] hasAudio, error in
                guard let self else { return }
                browserCall = nil
                if hasAudio {
                    drafts[noteID] = Draft(file: file, isCall: true)
                } else {
                    try? FileManager.default.removeItem(at: file)
                }
                errors[noteID] = error
            }
            try call.openChrome()
            browserCall = call
        } catch {
            errors[noteID] = (error as? AssistantFailure)?.message ?? "Не удалось начать запись звонка."
        }
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        recordingID = nil
        startedAt = nil
    }

    func showFile(_ noteID: UUID) {
        guard let file = drafts[noteID]?.file else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func saveCopy(_ noteID: UUID, suggestedName: String) async throws -> Bool {
        guard let file = drafts[noteID]?.file else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = suggestedName.replacingOccurrences(of: "/", with: "-") + ".m4a"
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let destination = panel.url, destination.standardizedFileURL != file.standardizedFileURL else { return false }
        // Диалог подтвердил замену файла. Атомарная запись сохраняет старую копию при сбое.
        try Data(contentsOf: file).write(to: destination, options: .atomic)
        return true
    }

    func discard(_ noteID: UUID) {
        guard recordingID != noteID, !transcribing.contains(noteID) else { return }
        removeFile(noteID)
    }

    private func removeFile(_ noteID: UUID) {
        guard let draft = drafts[noteID] else { return }
        do {
            // Исходник удаляется последним, чтобы оставался доступен при сбое очистки частей.
            for file in (draft.pieces ?? []).filter({ $0 != draft.file }) + [draft.file] {
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            drafts[noteID] = nil
            errors[noteID] = nil
        } catch {
            errors[noteID] = "Не удалось удалить временную запись."
        }
    }

    func transcribe(_ noteID: UUID, store: NoteStore, profile: AssistantGatewayProfile, modelID: String,
                    transport: AssistantGatewayHTTP) async {
        guard var draft = drafts[noteID], recordingID != noteID, !transcribing.contains(noteID) else { return }
        transcribing.insert(noteID)
        errors[noteID] = nil
        defer { transcribing.remove(noteID) }
        do {
            if draft.transcript == nil {
                if draft.isCall {
                    try await transcribeCall(noteID, profile: profile, modelID: modelID, transport: transport)
                } else {
                    draft.transcript = try await transport.transcribe(draft.file, profile: profile, modelID: modelID)
                    drafts[noteID] = draft
                }
            }
            try saveTranscript(noteID, store: store)
        } catch {
            errors[noteID] = (error as? AssistantFailure)?.message ?? "Не удалось расшифровать запись."
        }
    }

    private func transcribeCall(_ noteID: UUID, profile: AssistantGatewayProfile, modelID: String,
                                transport: AssistantGatewayHTTP) async throws {
        guard var draft = drafts[noteID] else { return }
        if draft.pieces == nil {
            let source = draft.file
            let pieces = try await Task.detached(priority: .utility) { try NoteCallAudio.transcriptionPieces(source) }.value
            files.track(pieces)
            draft.pieces = pieces
            draft.pieceTranscripts = Array(repeating: nil, count: pieces.count)
            drafts[noteID] = draft
        }
        guard let pieces = draft.pieces else { return }
        for (index, piece) in pieces.enumerated() where draft.pieceTranscripts[index] == nil {
            let text = try await transport.transcribe(piece, profile: profile, modelID: modelID, allowEmpty: pieces.count > 1)
            draft.pieceTranscripts[index] = text
            drafts[noteID] = draft
        }
        let text = draft.pieceTranscripts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !text.isEmpty else {
            // После пустого ответа всех частей можно выбрать другую модель и повторить.
            draft.pieceTranscripts = Array(repeating: nil, count: pieces.count)
            drafts[noteID] = draft
            throw AssistantFailure(message: "Сервис вернул пустую расшифровку.")
        }
        draft.transcript = text
        drafts[noteID] = draft
    }

    func retrySaving(_ noteID: UUID, store: NoteStore) {
        do { try saveTranscript(noteID, store: store) }
        catch { errors[noteID] = (error as? AssistantFailure)?.message ?? "Не удалось сохранить текст заметки." }
    }

    private func saveTranscript(_ noteID: UUID, store: NoteStore) throws {
        guard var draft = drafts[noteID], let transcript = draft.transcript else { return }
        if !draft.saved {
            try store.applyText(transcript, to: noteID, append: true)
            draft.saved = true
            drafts[noteID] = draft
        }
        removeFile(noteID)
    }

    private final class RecordingFiles {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Takt-Voice-" + UUID().uuidString)
        private var recordings: Set<URL> = []

        func track(_ urls: [URL]) { recordings.formUnion(urls) }

        func newRecording() -> URL {
            let file = directory.appending(path: UUID().uuidString).appendingPathExtension("m4a")
            recordings.insert(file)
            return file
        }

        deinit {
            let manager = FileManager.default
            for file in recordings { try? manager.removeItem(at: file) }
            if (try? manager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try? manager.removeItem(at: directory)
            }
        }
    }
}

struct NoteVoiceControls: View {
    @Environment(\.translations) private var strings
    let note: PlannerNote
    let store: NoteStore
    let voice: NoteVoiceRecording
    let assistant: AssistantService
    let preferences: AppPreferences
    @State private var choosingModel = false
    @State private var confirmation: AssistantTranscriptionSelection?
    @State private var showDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let call = voice.browserCall {
                callControls(call)
            }
            if let recording = voice.recordingID, let startedAt = voice.startedAt {
                HStack {
                    if recording != note.id { Text(strings["Запись в другой заметке"]) }
                    Text(startedAt, style: .timer).monospacedDigit()
                    Button(strings["Остановить"], systemImage: "stop.circle.fill") { voice.stop() }
                }
            }
            if voice.recordingID != note.id, let draft = voice.drafts[note.id] {
                HStack {
                    if voice.transcribing.contains(note.id) {
                        ProgressView().controlSize(.small)
                        Text(strings["Расшифровка…"])
                    } else if draft.saved {
                        Button(strings["Удалить запись"]) { voice.discard(note.id) }
                    } else if draft.transcript != nil {
                        Button(strings["Сохранить текст"]) { voice.retrySaving(note.id, store: store) }
                    } else if note.deletedAt == nil, !store.unreadable {
                        Button(strings["Расшифровать"], action: beginTranscription)
                            .accessibilityIdentifier("note-transcribe")
                    }
                    Button(strings["Показать в Finder"]) { voice.showFile(note.id) }
                    if !voice.transcribing.contains(note.id), !draft.saved {
                        Button(strings["Удалить запись"], role: .destructive) { showDiscard = true }
                    }
                }
            }
            if let error = voice.errors[note.id] {
                Text(strings[error]).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, voice.recordingID != nil || voice.browserCall != nil || voice.drafts[note.id] != nil || voice.errors[note.id] != nil ? 10 : 0)
        .sheet(isPresented: $choosingModel, onDismiss: openConfirmationIfReady) {
            AssistantModelConnections(service: assistant, russian: preferences.language.resolvedCode == "ru",
                                      transcriptionPreferences: preferences)
        }
        .sheet(item: $confirmation) { selection in
            NoteVoiceConfirmation(provider: selection.gateway.name, saveCopy: {
                try await voice.saveCopy(note.id, suggestedName: note.displayTitle.isEmpty ? strings["Запись"] : note.displayTitle)
            }, transcribe: {
                guard let profile = selection.profile(in: assistant.gateways) else {
                    confirmation = nil
                    choosingModel = true
                    return
                }
                confirmation = nil
                Task { await voice.transcribe(note.id, store: store, profile: profile,
                                              modelID: selection.modelID, transport: assistant.gateways.http) }
            }, cancel: { confirmation = nil })
        }
        .alert(strings["Удалить временную запись?"], isPresented: $showDiscard) {
            Button(strings["Удалить запись"], role: .destructive) { voice.discard(note.id) }
            Button(strings["Отмена"], role: .cancel) {}
        }
    }

    private func callControls(_ call: NoteBrowserCall) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if call.noteID != note.id { Text(strings["Запись в другой заметке"]) }
                switch call.phase {
                case .waiting:
                    Text(strings["Выберите вкладку звонка в Chrome."])
                    Button(strings["Отмена"]) { call.stop() }
                case .recording, .paused:
                    Image(systemName: call.phase == .paused ? "pause.circle" : "record.circle")
                        .foregroundStyle(call.phase == .recording ? Color.red : Color.secondary)
                        .accessibilityHidden(true)
                    let seconds = Int(call.duration)
                    Text(String(format: "%02d:%02d", seconds / 60, seconds % 60)).monospacedDigit()
                    Button(strings[call.phase == .paused ? "Продолжить" : "Пауза"]) { call.togglePause() }
                    Button(strings["Остановить"], systemImage: "stop.circle.fill") { call.stop() }
                case .stopping:
                    ProgressView().controlSize(.small)
                    Text(strings["Сохранение записи…"])
                }
            }
            if call.phase == .recording || call.phase == .paused {
                HStack(spacing: 16) {
                    ProgressView(value: Double(call.microphone.squareRoot())) { Text(strings["Микрофон"]) }
                    ProgressView(value: Double(call.tab.squareRoot())) { Text(strings["Звук вкладки"]) }
                }
                .font(.caption)
                .frame(maxWidth: 325)
            }
        }
    }

    private func beginTranscription() {
        assistant.gateways.activate()
        if let selection = preferences.transcriptionModel, selection.profile(in: assistant.gateways) != nil {
            confirmation = selection
        } else {
            choosingModel = true
        }
    }

    private func openConfirmationIfReady() {
        if let selection = preferences.transcriptionModel, selection.profile(in: assistant.gateways) != nil {
            confirmation = selection
        }
    }
}

private struct NoteVoiceConfirmation: View {
    @Environment(\.translations) private var strings
    let provider: String
    let saveCopy: () async throws -> Bool
    let transcribe: () -> Void
    let cancel: () -> Void
    @State private var copying = false
    @State private var savedCopy = false
    @State private var copyFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(strings["Расшифровать запись?"]).font(.headline)
            Text(strings.format("Аудио будет отправлено в %@ для расшифровки. Когда текст сохранится в заметке, Takt удалит временную запись с Mac.", provider))
            if savedCopy { Label(strings["Копия сохранена"], systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            if copyFailed { Text(strings["Не удалось сохранить копию записи."]).foregroundStyle(.secondary) }
            HStack {
                Button(strings["Сохранить копию…"]) {
                    copying = true
                    Task {
                        defer { copying = false }
                        copyFailed = false
                        do {
                            if try await saveCopy() { savedCopy = true }
                        } catch { copyFailed = true }
                    }
                }
                Spacer()
                Button(strings["Отмена"], action: cancel).keyboardShortcut(.cancelAction)
                Button(strings["Расшифровать"], action: transcribe).keyboardShortcut(.defaultAction)
            }
            .disabled(copying)
        }
        .padding(20)
        .frame(width: 470)
    }
}
