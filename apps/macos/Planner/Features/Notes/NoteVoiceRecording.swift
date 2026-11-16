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
        var transcriptionSource: String?
        var remoteCleanupFailed = false
        var saved = false

        var id: UUID? { UUID(uuidString: file.deletingPathExtension().pathExtension) }
    }

    private(set) var drafts: [UUID: Draft] = [:]
    private(set) var recordingID: UUID?
    private(set) var startedAt: Date?
    private(set) var pausedDuration: TimeInterval = 0
    private(set) var isPaused = false
    private(set) var preparing = false
    private(set) var browserCall: NoteBrowserCall?

    var isBusy: Bool { preparing || recordingID != nil || browserCall != nil }
    private(set) var transcribing: Set<UUID> = []
    private(set) var errors: [UUID: String] = [:]
    @ObservationIgnored private var recorder: (any NoteMicrophoneInput)?
    @ObservationIgnored private var recorderDelegate: MicrophoneDelegate?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let scratch = ScratchFiles()

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.temporaryDirectory.appending(path: "Takt-Voice-" + UUID().uuidString)
    }

    func restoreDrafts(for notes: [PlannerNote]) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        for file in files where file.pathExtension == "m4a" {
            let components = file.deletingPathExtension().lastPathComponent.split(separator: ".")
            guard components.count == 3, let noteID = UUID(uuidString: String(components[0])),
                  let note = notesByID[noteID], drafts[noteID] == nil,
                  components[1] == "voice" || components[1] == "call",
                  let audio = try? AVAudioFile(forReading: file), audio.length > 0 else { continue }
            var draft = Draft(file: file, isCall: components[1] == "call")
            draft.saved = draft.id != nil && draft.id == note.lastVoiceTranscriptID
            drafts[noteID] = draft
        }
    }

    func start(_ noteID: UUID) async {
        guard !isBusy, drafts[noteID] == nil else { return }
        preparing = true
        errors[noteID] = nil
        defer { preparing = false }
        let file = newRecording(noteID, kind: "voice")
        do {
            #if DEBUG
            if Self.usesTestAudio {
                try prepareDirectory()
                let input = try TestMicrophoneInput(file: file)
                try begin(input, noteID: noteID, file: file)
                return
            }
            #endif
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                errors[noteID] = "Разрешите доступ к микрофону в системных настройках."
                return
            }
            try prepareDirectory()
            let input = try AVAudioRecorder(url: file, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ])
            let delegate = MicrophoneDelegate { [weak self] successful in
                Task { @MainActor [weak self] in
                    guard let self, recordingID == noteID, drafts[noteID]?.file == file else { return }
                    finishMicrophone()
                    if !successful { errors[noteID] = "Не удалось сохранить запись." }
                }
            }
            input.delegate = delegate
            try begin(input, noteID: noteID, file: file)
            recorderDelegate = delegate
        } catch {
            try? FileManager.default.removeItem(at: file)
            errors[noteID] = "Не удалось начать запись."
        }
    }

    private func begin(_ input: any NoteMicrophoneInput, noteID: UUID, file: URL) throws {
        guard input.record() else { throw AssistantFailure(message: "Не удалось начать запись.") }
        recorder = input
        recordingID = noteID
        startedAt = .now
        pausedDuration = 0
        isPaused = false
        drafts[noteID] = Draft(file: file)
    }

    func togglePause() {
        guard let recorder, let recordingID else { return }
        if isPaused {
            guard recorder.record() else {
                errors[recordingID] = "Не удалось продолжить запись."
                return
            }
            startedAt = Date.now.addingTimeInterval(-pausedDuration)
            isPaused = false
            errors[recordingID] = nil
        } else {
            pausedDuration = recorder.currentTime
            recorder.pause()
            isPaused = true
        }
    }

    func startCall(_ noteID: UUID, russian: Bool) {
        guard !isBusy, drafts[noteID] == nil else { return }
        errors[noteID] = nil
        let file = newRecording(noteID, kind: "call")
        do {
            try prepareDirectory()
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
            #if DEBUG
            if Self.usesTestAudio {
                try call.startTestCapture()
                browserCall = call
                return
            }
            #endif
            try call.openChrome()
            browserCall = call
        } catch {
            errors[noteID] = (error as? AssistantFailure)?.message ?? "Не удалось начать запись звонка."
        }
    }

    func stop() {
        guard let recorder else { return }
        recorder.stop()
        finishMicrophone()
    }

    func finishForTermination() {
        stop()
        browserCall?.finishForTermination()
    }

    private func finishMicrophone() {
        guard let noteID = recordingID, let file = drafts[noteID]?.file else { return }
        recorder = nil
        recorderDelegate = nil
        recordingID = nil
        startedAt = nil
        isPaused = false
        guard let audio = try? AVAudioFile(forReading: file), audio.length > 0 else {
            drafts[noteID] = nil
            try? FileManager.default.removeItem(at: file)
            errors[noteID] = "Не удалось сохранить запись."
            return
        }
    }

    #if DEBUG
    private static var usesTestAudio: Bool {
        PlannerPersistence.testID != nil && ProcessInfo.processInfo.environment["PLANNER_UI_TEST_VOICE"] == "1"
    }
    #endif

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func newRecording(_ noteID: UUID, kind: String) -> URL {
        // Имя сохраняет связь с заметкой даже после завершения процесса.
        directory.appending(path: "\(noteID.uuidString).\(kind).\(UUID().uuidString).m4a")
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
        guard let draft = drafts[noteID], !draft.saved, recordingID != noteID, !transcribing.contains(noteID) else { return }
        transcribing.insert(noteID)
        errors[noteID] = nil
        defer { transcribing.remove(noteID) }
        do {
            if draft.transcript == nil {
                try await transcribeRecording(noteID, profile: profile, modelID: modelID, transport: transport)
            }
            try saveTranscript(noteID, store: store)
        } catch {
            errors[noteID] = (error as? AssistantFailure)?.message ?? "Не удалось расшифровать запись."
        }
    }

    private func transcribeRecording(_ noteID: UUID, profile: AssistantGatewayProfile, modelID: String,
                                transport: AssistantGatewayHTTP) async throws {
        guard var draft = drafts[noteID] else { return }
        if draft.pieces == nil {
            let source = draft.file
            let workingDirectory = scratch.directory
            let pieces = try await Task.detached(priority: .utility) {
                try NoteCallAudio.transcriptionPieces(source, outputDirectory: workingDirectory)
            }.value
            draft.pieces = pieces
            draft.pieceTranscripts = Array(repeating: nil, count: pieces.count)
            drafts[noteID] = draft
        }
        guard let pieces = draft.pieces else { return }
        let sourceID = profile.id.uuidString + ":" + modelID
        if draft.transcriptionSource != sourceID {
            draft.transcriptionSource = sourceID
            draft.pieceTranscripts = Array(repeating: nil, count: pieces.count)
            drafts[noteID] = draft
        }
        for (index, piece) in pieces.enumerated() where draft.pieceTranscripts[index] == nil {
            let result = try await transport.transcribe(piece, profile: profile, modelID: modelID, allowEmpty: pieces.count > 1)
            draft.pieceTranscripts[index] = result.text
            draft.remoteCleanupFailed = draft.remoteCleanupFailed || result.remoteCleanupFailed
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
            try store.applyText(transcript, to: noteID, append: true, voiceTranscriptID: draft.id)
            draft.saved = true
            drafts[noteID] = draft
        }
        removeFile(noteID)
        if draft.remoteCleanupFailed, errors[noteID] == nil {
            errors[noteID] = "Не удалось удалить загруженный файл из GigaChat."
        }
    }

    // Части для загрузки можно пересоздать из локального оригинала.
    private final class ScratchFiles {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Takt-Voice-Parts-" + UUID().uuidString)

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private final class MicrophoneDelegate: NSObject, AVAudioRecorderDelegate {
        let finished: @Sendable (Bool) -> Void

        init(finished: @escaping @Sendable (Bool) -> Void) { self.finished = finished }

        func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) { finished(flag) }
        func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) { finished(false) }
    }
}

private protocol NoteMicrophoneInput: AnyObject {
    var currentTime: TimeInterval { get }
    func record() -> Bool
    func pause()
    func stop()
}

extension AVAudioRecorder: NoteMicrophoneInput {}

#if DEBUG
/// Тест клика создаёт аудиофайл с тоном, не открывая физический микрофон.
private final class TestMicrophoneInput: NoteMicrophoneInput {
    private var startedAt: Date?
    private var duration: TimeInterval = 0

    init(file: URL) throws {
        let writer = try NoteCallAudio(url: file)
        _ = try writer.append(NoteRecordingTestAudio.tone())
        writer.close()
    }

    var currentTime: TimeInterval { duration + (startedAt.map { Date.now.timeIntervalSince($0) } ?? 0) }

    func record() -> Bool {
        startedAt = .now
        return true
    }

    func pause() {
        duration = currentTime
        startedAt = nil
    }

    func stop() { pause() }
}
enum NoteRecordingTestAudio {
    static func tone() -> Data {
        var tone = Data()
        for index in 0..<NoteCallAudio.sampleRate {
            let sample = Int16(8_000 * sin(Double(index) * 440 * 2 * .pi / Double(NoteCallAudio.sampleRate)))
            let bytes = [UInt8(truncatingIfNeeded: sample), UInt8(truncatingIfNeeded: sample >> 8)]
            tone.append(contentsOf: bytes + bytes)
        }
        return tone
    }
}

#endif

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
        if voice.browserCall != nil || voice.recordingID != nil || voice.drafts[note.id] != nil || voice.errors[note.id] != nil {
            card
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let call = voice.browserCall { callControls(call) }
            if let recording = voice.recordingID, let startedAt = voice.startedAt {
                activeRecording(title: recording == note.id ? "Голосовая запись" : "Запись в другой заметке",
                                paused: voice.isPaused, pause: voice.togglePause, finish: voice.stop) {
                    if voice.isPaused {
                        Text(formattedDuration(voice.pausedDuration))
                    } else {
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text(formattedDuration(context.date.timeIntervalSince(startedAt)))
                        }
                    }
                }
            }
            if voice.recordingID != note.id, let draft = voice.drafts[note.id] {
                Label(strings[draft.isCall ? "Запись звонка" : "Голосовая запись"], systemImage: "waveform")
                    .font(.headline)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { draftActions(draft) }
                    VStack(alignment: .leading, spacing: 10) { draftActions(draft) }
                }
            }
            if let error = voice.errors[note.id] {
                Text(strings[error]).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $choosingModel, onDismiss: openConfirmationIfReady) {
            AssistantModelConnections(service: assistant, russian: preferences.language.resolvedCode == "ru",
                                      preferences: preferences, purpose: .transcription)
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

    @ViewBuilder
    private func draftActions(_ draft: NoteVoiceRecording.Draft) -> some View {
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
            .accessibilityIdentifier("note-show-recording")
        if !voice.transcribing.contains(note.id), !draft.saved {
            Button(strings["Удалить запись"], role: .destructive) { showDiscard = true }
                .accessibilityIdentifier("note-discard-recording")
        }
    }

    private func activeRecording<TimerLabel: View>(
        title: String, paused: Bool, pause: @escaping () -> Void, finish: @escaping () -> Void,
        @ViewBuilder timer: () -> TimerLabel
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(strings[title], systemImage: "waveform").font(.headline)
            HStack(spacing: 10) {
                Image(systemName: paused ? "pause.circle" : "record.circle")
                    .foregroundStyle(paused ? Color.secondary : Color.red)
                    .accessibilityHidden(true)
                timer().font(.title3.monospacedDigit()).accessibilityIdentifier("note-recording-timer")
                Spacer(minLength: 0)
                let toggleTitle = strings[paused ? "Продолжить" : "Пауза"]
                Button(toggleTitle, systemImage: paused ? "play.fill" : "pause.fill", action: pause)
                    .labelStyle(.iconOnly)
                    .help(toggleTitle)
                    .accessibilityIdentifier("note-toggle-recording")
                Button(strings["Завершить запись"], systemImage: "stop.fill", action: finish)
                    .labelStyle(.iconOnly)
                    .tint(.red)
                    .help(strings["Завершить запись"])
                    .accessibilityIdentifier("note-finish-recording")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func callControls(_ call: NoteBrowserCall) -> some View {
        switch call.phase {
        case .waiting:
            HStack {
                Text(strings["Выберите вкладку звонка в Chrome."])
                Spacer()
                Button(strings["Отмена"]) { call.stop() }
            }
        case .recording, .paused:
            activeRecording(title: call.noteID == note.id ? "Запись звонка" : "Запись в другой заметке",
                            paused: call.phase == .paused, pause: call.togglePause, finish: call.stop) {
                Text(formattedDuration(call.duration))
            }
            ProgressView(value: Double(call.microphone.squareRoot())) { Text(strings["Микрофон"]) }
                .font(.caption)
                .frame(maxWidth: 325)
        case .stopping:
            HStack {
                ProgressView().controlSize(.small)
                Text(strings["Сохранение записи…"])
            }
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(max(0, duration))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
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
