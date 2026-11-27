import AppKit
import AVFoundation
import OSLog
import PlannerLocalization
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class NoteVoiceRecording {
    struct Draft: Identifiable {
        let id: UUID
        let noteID: UUID
        let file: URL
        let createdAt: Date
        let duration: TimeInterval
        let isCall: Bool
        var title: String?
        var checkpoint: Checkpoint?
        var hasTranscript: Bool {
            guard let parts = checkpoint?.parts, !parts.isEmpty else { return false }
            return parts.allSatisfy { $0.text != nil || $0.skipped }
        }
        var saved = false

        var checkpointFile: URL { file.appendingPathExtension("transcription.json") }
        var titleFile: URL { file.appendingPathExtension("title") }
    }

    struct Checkpoint: Codable {
        struct Part: Codable, Sendable {
            let index: Int
            let start: AVAudioFramePosition
            let end: AVAudioFramePosition
            var depth = 0
            var text: String?
            var skipped = false

            func interval(sampleRate: Double) -> String {
                "\(Self.timestamp(start, sampleRate))–\(Self.timestamp(end, sampleRate))"
            }

            private static func timestamp(_ frames: AVAudioFramePosition, _ sampleRate: Double) -> String {
                let seconds = Int(Double(frames) / sampleRate)
                if seconds >= 3600 {
                    return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                }
                return String(format: "%02d:%02d", seconds / 60, seconds % 60)
            }
        }

        let sourceID: String
        let sampleRate: Double
        var parts: [Part]
        var remoteCleanupFailed = false

        init(sourceID: String, plan: NoteCallAudio.TranscriptionPlan) {
            self.sourceID = sourceID
            sampleRate = plan.sampleRate
            parts = (0..<plan.count).map { index in
                let start = AVAudioFramePosition(index) * plan.framesPerPart
                return Part(index: index, start: start, end: min(start + plan.framesPerPart, plan.totalFrames))
            }
        }

        func matches(_ plan: NoteCallAudio.TranscriptionPlan) -> Bool {
            guard sampleRate == plan.sampleRate, parts.count <= plan.count * 8 else { return false }
            var nextFrame: AVAudioFramePosition = 0
            for part in parts {
                let index = Int(nextFrame / plan.framesPerPart)
                guard part.start == nextFrame, part.index == index, index < plan.count,
                      part.end > part.start, part.end <= min(plan.totalFrames, (AVAudioFramePosition(index) + 1) * plan.framesPerPart),
                      (0...3).contains(part.depth) else { return false }
                nextFrame = part.end
            }
            return nextFrame == plan.totalFrames
        }
    }

    struct TranscriptPreview: Identifiable {
        let id: UUID
        let noteID: UUID
        let text: String
        let isPartial: Bool
    }

    struct TranscriptionIssue {
        let provider: String
        let part: Int
        let total: Int
        let interval: String
        let stage: String
        let message: String
        let code: String?
        let skipIndex: Int?
    }

    private static let logger = Logger(subsystem: "local.planner.Planner", category: "Transcription")


    private(set) var drafts: [UUID: Draft] = [:]
    private(set) var recordingErrors: [UUID: String] = [:]
    @ObservationIgnored private var recordingFile: URL?
    @ObservationIgnored private var preparingNoteID: UUID?
    @ObservationIgnored private var discardedWhilePreparing = false
    private var microphoneNoteID: UUID?
    private(set) var startedAt: Date?
    private(set) var pausedDuration: TimeInterval = 0
    private(set) var isPaused = false
    private(set) var preparing = false
    private(set) var browserCall: NoteBrowserCall?

    var isBusy: Bool { preparing || microphoneNoteID != nil || browserCall != nil }
    var activeNoteID: UUID? { microphoneNoteID ?? browserCall?.noteID }

    func drafts(for noteID: UUID) -> [Draft] {
        drafts.values.filter { $0.noteID == noteID }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    private(set) var transcriptPreviews: [TranscriptPreview] = []
    private(set) var transcribing: Set<UUID> = []
    private(set) var transcriptionProgress: [UUID: (part: Int, total: Int)] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var transcriptionIssues: [UUID: TranscriptionIssue] = [:]
    @ObservationIgnored private var recorder: (any NoteMicrophoneInput)?
    @ObservationIgnored private var recorderDelegate: MicrophoneDelegate?
    @ObservationIgnored private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.temporaryDirectory.appending(path: "Takt-Voice-" + UUID().uuidString)
    }

    func restoreDrafts(for notes: [PlannerNote]) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        for file in files where file.pathExtension == "m4a" {
            let components = file.deletingPathExtension().lastPathComponent.split(separator: ".")
            guard components.count == 3, let noteID = UUID(uuidString: String(components[0])),
                  let note = notesByID[noteID], file != recordingFile, file != browserCall?.file,
                  components[1] == "voice" || components[1] == "call",
                  var draft = makeDraft(file: file, noteID: noteID, isCall: components[1] == "call"),
                  drafts[draft.id] == nil else { continue }
            draft.saved = note.hasVoiceTranscript(draft.id)
            if !draft.saved, let data = try? Data(contentsOf: draft.checkpointFile),
               let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: data),
               let plan = try? NoteCallAudio.TranscriptionPlan(file), checkpoint.matches(plan) {
                draft.checkpoint = checkpoint
                if draft.hasTranscript && checkpoint.remoteCleanupFailed {
                    errors[draft.id] = "Не удалось удалить загруженный файл из GigaChat."
                }
            }
            drafts[draft.id] = draft
        }
    }

    private func makeDraft(file: URL, noteID: UUID, isCall: Bool) -> Draft? {
        guard let id = UUID(uuidString: file.deletingPathExtension().pathExtension),
              let audio = try? AVAudioFile(forReading: file), audio.length > 0 else { return nil }
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { return nil }
        let createdAt = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        var draft = Draft(id: id, noteID: noteID, file: file, createdAt: createdAt, duration: duration, isCall: isCall)
        draft.title = try? String(contentsOf: draft.titleFile, encoding: .utf8)
        return draft
    }

    func start(_ noteID: UUID) async {
        guard !isBusy else { return }
        preparing = true
        preparingNoteID = noteID
        discardedWhilePreparing = false
        recordingErrors[noteID] = nil
        defer {
            preparing = false
            preparingNoteID = nil
            discardedWhilePreparing = false
        }
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
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard !discardedWhilePreparing else { return }
            guard granted else {
                recordingErrors[noteID] = "Разрешите доступ к микрофону в системных настройках."
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
                    guard let self, microphoneNoteID == noteID, recordingFile == file else { return }
                    finishMicrophone()
                    if !successful { recordingErrors[noteID] = "Не удалось сохранить запись." }
                }
            }
            input.delegate = delegate
            try begin(input, noteID: noteID, file: file)
            recorderDelegate = delegate
        } catch {
            try? FileManager.default.removeItem(at: file)
            recordingErrors[noteID] = "Не удалось начать запись."
        }
    }

    private func begin(_ input: any NoteMicrophoneInput, noteID: UUID, file: URL) throws {
        guard input.record() else { throw AssistantFailure(message: "Не удалось начать запись.") }
        recorder = input
        microphoneNoteID = noteID
        startedAt = .now
        pausedDuration = 0
        isPaused = false
        recordingFile = file
    }

    func togglePause() {
        guard let recorder, let microphoneNoteID else { return }
        if isPaused {
            guard recorder.record() else {
                recordingErrors[microphoneNoteID] = "Не удалось продолжить запись."
                return
            }
            startedAt = Date.now.addingTimeInterval(-pausedDuration)
            isPaused = false
            recordingErrors[microphoneNoteID] = nil
        } else {
            pausedDuration = recorder.currentTime
            recorder.pause()
            isPaused = true
        }
    }

    func startCall(_ noteID: UUID, russian: Bool) {
        guard !isBusy else { return }
        recordingErrors[noteID] = nil
        let file = newRecording(noteID, kind: "call")
        do {
            try prepareDirectory()
            let call = NoteBrowserCall(noteID: noteID, file: file, russian: russian) { [weak self] hasAudio, error in
                guard let self else { return }
                browserCall = nil
                if hasAudio, let draft = makeDraft(file: file, noteID: noteID, isCall: true) {
                    drafts[draft.id] = draft
                    recordingErrors[noteID] = error
                } else {
                    try? FileManager.default.removeItem(at: file)
                    recordingErrors[noteID] = error ?? (hasAudio ? "Не удалось сохранить запись." : nil)
                }
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
            recordingErrors[noteID] = (error as? AssistantFailure)?.message ?? "Не удалось начать запись звонка."
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
        guard let noteID = microphoneNoteID, let file = recordingFile else { return }
        recorder = nil
        recorderDelegate = nil
        microphoneNoteID = nil
        recordingFile = nil
        startedAt = nil
        isPaused = false
        if let draft = makeDraft(file: file, noteID: noteID, isCall: false) {
            drafts[draft.id] = draft
        } else {
            try? FileManager.default.removeItem(at: file)
            recordingErrors[noteID] = "Не удалось сохранить запись."
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

    func rename(_ recordingID: UUID, to title: String) throws {
        guard var draft = drafts[recordingID] else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            if FileManager.default.fileExists(atPath: draft.titleFile.path) {
                try FileManager.default.removeItem(at: draft.titleFile)
            }
            draft.title = nil
        } else {
            try Data(title.utf8).write(to: draft.titleFile, options: .atomic)
            draft.title = title
        }
        drafts[recordingID] = draft
    }

    func showFile(_ recordingID: UUID) {
        guard let file = drafts[recordingID]?.file else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func saveCopy(_ recordingID: UUID, suggestedName: String) async throws -> Bool {
        guard let file = drafts[recordingID]?.file else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = suggestedName.replacingOccurrences(of: "/", with: "-") + ".m4a"
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let destination = panel.url, destination.standardizedFileURL != file.standardizedFileURL else { return false }
        // Диалог подтвердил замену файла. Атомарная запись сохраняет старую копию при сбое.
        try Data(contentsOf: file, options: .alwaysMapped).write(to: destination, options: .atomic)
        return true
    }

    func discard(_ recordingID: UUID) {
        guard !transcribing.contains(recordingID) else { return }
        removeFile(recordingID)
    }

    func discardAll(for noteID: UUID) {
        if preparingNoteID == noteID { discardedWhilePreparing = true }
        if microphoneNoteID == noteID { stop() }
        if browserCall?.noteID == noteID { browserCall?.finishForTermination() }
        for draft in drafts(for: noteID) { discard(draft.id) }
        recordingErrors[noteID] = nil
    }

    private func removeFile(_ recordingID: UUID) {
        guard let draft = drafts[recordingID] else { return }
        do {
            if FileManager.default.fileExists(atPath: draft.file.path) {
                try FileManager.default.removeItem(at: draft.file)
            }
            removeCheckpoint(draft)
            try? FileManager.default.removeItem(at: draft.titleFile)
            dismissTranscript(recordingID)
            drafts[recordingID] = nil
            errors[recordingID] = nil
            transcriptionIssues[recordingID] = nil
        } catch {
            errors[recordingID] = "Не удалось удалить запись."
        }
    }

    private func removeCheckpoint(_ draft: Draft) {
        try? FileManager.default.removeItem(at: draft.checkpointFile)
    }

    private func saveCheckpoint(_ checkpoint: Checkpoint, for recordingID: UUID) throws {
        guard let file = drafts[recordingID]?.checkpointFile else { return }
        do {
            try JSONEncoder().encode(checkpoint).write(to: file, options: .atomic)
            drafts[recordingID]?.checkpoint = checkpoint
        } catch {
            throw AssistantFailure(message: "Не удалось сохранить прогресс расшифровки.")
        }
    }

    func skipFailedPart(_ recordingID: UUID) -> Bool {
        guard !transcribing.contains(recordingID), let index = transcriptionIssues[recordingID]?.skipIndex,
              var checkpoint = drafts[recordingID]?.checkpoint,
              checkpoint.parts.indices.contains(index), checkpoint.parts[index].text == nil else { return false }
        checkpoint.parts[index].skipped = true
        do {
            try saveCheckpoint(checkpoint, for: recordingID)
            transcriptionIssues[recordingID] = nil
            errors[recordingID] = nil
            return true
        } catch {
            errors[recordingID] = "Не удалось сохранить прогресс расшифровки."
            return false
        }
    }

    func transcribe(_ recordingID: UUID, store: NoteStore, profile: AssistantGatewayProfile, modelID: String,
                    transport: AssistantGatewayHTTP, strings: Translations = .init(language: .russian)) async {
        guard let draft = drafts[recordingID], !draft.saved, !transcribing.contains(recordingID),
              store.notes.contains(where: { $0.id == draft.noteID && $0.deletedAt == nil }) else { return }
        transcribing.insert(recordingID)
        errors[recordingID] = nil
        transcriptionIssues[recordingID] = nil
        defer {
            transcribing.remove(recordingID)
            transcriptionProgress[recordingID] = nil
            if store.notes.contains(where: { $0.id == draft.noteID && $0.isPurged }) { discard(recordingID) }
        }
        do {
            if !draft.hasTranscript {
                try await transcribeRecording(recordingID, profile: profile, modelID: modelID, transport: transport)
            }
            if store.notes.contains(where: { $0.id == draft.noteID && $0.deletedAt == nil }) {
                presentTranscript(recordingID, strings: strings)
            }
        } catch is CancellationError {
            return
        } catch {
            if transcriptionIssues[recordingID] == nil {
                errors[recordingID] = (error as? AssistantFailure)?.message ?? "Не удалось расшифровать запись."
            }
        }
    }

    private func transcribeRecording(_ recordingID: UUID, profile: AssistantGatewayProfile, modelID: String,
                                     transport: AssistantGatewayHTTP) async throws {
        guard let draft = drafts[recordingID] else { return }
        let plan: NoteCallAudio.TranscriptionPlan
        do { plan = try NoteCallAudio.TranscriptionPlan(draft.file) }
        catch { throw AssistantFailure(message: "Не удалось подготовить запись к расшифровке.") }
        let sourceID = profile.id.uuidString + ":" + modelID
        var checkpoint = draft.checkpoint ?? Checkpoint(sourceID: sourceID, plan: plan)
        if checkpoint.sourceID != sourceID || !checkpoint.matches(plan) {
            checkpoint = Checkpoint(sourceID: sourceID, plan: plan)
        }

        // Validate that progress can be written before sending any new audio.
        try saveCheckpoint(checkpoint, for: recordingID)

        var index = 0
        while index < checkpoint.parts.count {
            try Task.checkCancellation()
            let part = checkpoint.parts[index]
            if part.text != nil || part.skipped {
                index += 1
                continue
            }
            transcriptionProgress[recordingID] = (part.index + 1, plan.count)
            let interval = part.interval(sampleRate: plan.sampleRate)
            let piece: URL
            do {
                let preparation = Task.detached(priority: .utility) { try plan.preparePart(from: part.start, to: part.end) }
                piece = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                transcriptionIssues[recordingID] = TranscriptionIssue(provider: profile.gateway.name, part: part.index + 1,
                    total: plan.count, interval: interval, stage: "Подготовка записи",
                    message: "Не удалось подготовить запись к расшифровке.", code: nil, skipIndex: index)
                throw error
            }
            defer { if piece != plan.source { try? FileManager.default.removeItem(at: piece) } }

            do {
                let result = try await recognize(piece, part: part.index + 1, total: plan.count, interval: interval,
                                                 profile: profile, modelID: modelID, transport: transport)
                checkpoint.parts[index].text = result.text
                checkpoint.remoteCleanupFailed = checkpoint.remoteCleanupFailed || result.remoteCleanupFailed
                index += 1
            } catch let failure as AssistantGatewayHTTP.AudioFailure {
                checkpoint.remoteCleanupFailed = checkpoint.remoteCleanupFailed || failure.remoteCleanupFailed
                let frames = part.end - part.start
                if failure.canSplit, part.depth < 3, Double(frames) / plan.sampleRate >= 10 {
                    let middle = part.start + frames / 2
                    checkpoint.parts.replaceSubrange(index...index, with: [
                        .init(index: part.index, start: part.start, end: middle, depth: part.depth + 1),
                        .init(index: part.index, start: middle, end: part.end, depth: part.depth + 1)
                    ])
                } else {
                    transcriptionIssues[recordingID] = TranscriptionIssue(provider: profile.gateway.name, part: part.index + 1,
                        total: plan.count, interval: interval, stage: failure.stage.rawValue, message: failure.message,
                        code: failure.code, skipIndex: failure.canSkip ? index : nil)
                    try saveCheckpoint(checkpoint, for: recordingID)
                    throw failure
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                transcriptionIssues[recordingID] = TranscriptionIssue(provider: profile.gateway.name, part: part.index + 1,
                    total: plan.count, interval: interval, stage: "Распознавание речи",
                    message: (error as? AssistantFailure)?.message ?? "Не удалось расшифровать запись.", code: nil, skipIndex: nil)
                throw error
            }
            try saveCheckpoint(checkpoint, for: recordingID)
        }

        if checkpoint.remoteCleanupFailed { errors[recordingID] = "Не удалось удалить загруженный файл из GigaChat." }
    }

    private func recognize(_ piece: URL, part: Int, total: Int, interval: String,
                           profile: AssistantGatewayProfile, modelID: String,
                           transport: AssistantGatewayHTTP) async throws -> AssistantGatewayHTTP.AudioTranscript {
        var attempt = 1
        var cleanupFailed = false
        while true {
            try Task.checkCancellation()
            Self.logger.info("\(profile.gateway.name, privacy: .public) \(part)/\(total) \(interval, privacy: .public) attempt \(attempt)")
            do {
                var result = try await transport.transcribe(piece, profile: profile, modelID: modelID, allowEmpty: true)
                result.remoteCleanupFailed = result.remoteCleanupFailed || cleanupFailed
                if result.remoteCleanupFailed { Self.logger.warning("GigaChat transcription cleanup failed") }
                return result
            } catch var failure as AssistantGatewayHTTP.AudioFailure {
                cleanupFailed = cleanupFailed || failure.remoteCleanupFailed
                failure.remoteCleanupFailed = cleanupFailed
                Self.logger.warning("\(profile.gateway.name, privacy: .public) \(part)/\(total) \(interval, privacy: .public) \(failure.stage.rawValue, privacy: .public) \(failure.code, privacy: .public)")
                if failure.remoteCleanupFailed { Self.logger.warning("GigaChat transcription cleanup failed") }
                let delay = max(Double(attempt), failure.retryAfter ?? 0)
                guard failure.canRetry, attempt < 3, delay <= 30 else { throw failure }
                try await Task.sleep(for: .seconds(delay))
                attempt += 1
            }
        }
    }

    func presentTranscript(_ recordingID: UUID, strings: Translations) {
        guard let draft = drafts[recordingID], !draft.saved, draft.hasTranscript, let checkpoint = draft.checkpoint,
              !transcriptPreviews.contains(where: { $0.id == recordingID }) else { return }
        let text = checkpoint.parts.map { part in
            if let text = part.text, !text.isEmpty { return text }
            let label = strings[part.skipped ? "Фрагмент пропущен" : "Пустая расшифровка"]
            return "[\(label) · \(part.interval(sampleRate: checkpoint.sampleRate))]"
        }.joined(separator: "\n\n")
        transcriptPreviews.append(.init(id: recordingID, noteID: draft.noteID, text: text,
                                        isPartial: checkpoint.parts.contains(where: \.skipped)))
    }

    func dismissTranscript(_ recordingID: UUID) {
        transcriptPreviews.removeAll { $0.id == recordingID }
    }

    func insertTranscript(_ recordingID: UUID, store: NoteStore) throws {
        guard let preview = transcriptPreviews.first(where: { $0.id == recordingID }),
              var draft = drafts[recordingID], !draft.saved else { throw AssistantFailure(message: "Запись недоступна.") }
        try store.applyText(preview.text, to: draft.noteID, append: true, voiceTranscriptID: recordingID)
        removeCheckpoint(draft)
        draft.saved = true
        draft.checkpoint = nil
        drafts[recordingID] = draft
        dismissTranscript(recordingID)
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

    var body: some View {
        let drafts = voice.drafts(for: note.id)
        let active = voice.activeNoteID == note.id
        let error = voice.recordingErrors[note.id]
        if active || !drafts.isEmpty || error != nil {
            VStack(alignment: .leading, spacing: 10) {
                if active {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(strings[voice.browserCall == nil ? "Голосовая запись" : "Запись звонка"], systemImage: "waveform")
                            .font(.headline)
                        NoteActiveRecordingControls(voice: voice, compact: false)
                    }
                    .recordingCardStyle()
                }
                if let error {
                    Text(strings[error]).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if drafts.count > 1 {
                    ScrollView {
                        VStack(spacing: 8) { recordingCards(drafts) }
                    }
                    .frame(height: min(232, CGFloat(drafts.count) * 100))
                } else {
                    recordingCards(drafts)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
        }
    }

    private func recordingCards(_ drafts: [NoteVoiceRecording.Draft]) -> some View {
        ForEach(drafts) { draft in
            NoteRecordingCard(draft: draft, note: note, store: store, voice: voice, assistant: assistant, preferences: preferences)
        }
    }
}

struct NoteActiveRecordingControls: View {
    @Environment(\.translations) private var strings
    let voice: NoteVoiceRecording
    let compact: Bool

    var body: some View {
        if let call = voice.browserCall {
            switch call.phase {
            case .waiting:
                HStack {
                    if compact {
                        Button(strings["Отмена"], systemImage: "xmark") { call.stop() }
                            .labelStyle(.iconOnly)
                            .help(strings[call.waitingMessage])
                    } else {
                        Text(strings[call.waitingMessage])
                        Spacer()
                        Button(strings["Отмена"]) { call.stop() }
                    }
                }
            case .recording, .paused:
                controls(paused: call.phase == .paused, pause: call.togglePause, finish: call.stop) {
                    Text(Self.formattedDuration(call.duration))
                }
                if !compact {
                    HStack(spacing: 16) {
                        levelMeter("Микрофон", level: call.microphone)
                        levelMeter("Вкладка", level: call.tabLevel)
                    }
                    .frame(maxWidth: 440, alignment: .leading)
                    switch call.microphoneState {
                    case .pending:
                        Text(strings["Ожидаем разрешения на микрофон в Chrome."]).font(.caption)
                    case .unavailable:
                        Text(strings["Микрофон недоступен. Его можно включить на странице записи в Chrome."]).font(.caption)
                    case .available: EmptyView()
                    }
                }
            case .stopping:
                pending("Сохранение записи…")
            }
        } else if let startedAt = voice.startedAt {
            controls(paused: voice.isPaused, pause: voice.togglePause, finish: voice.stop) {
                if voice.isPaused {
                    Text(Self.formattedDuration(voice.pausedDuration))
                } else {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(Self.formattedDuration(context.date.timeIntervalSince(startedAt)))
                    }
                }
            }
        } else if voice.preparing {
            pending("Подготовка записи")
        }
    }

    private func levelMeter(_ title: String, level: Float) -> some View {
        ProgressView(value: Double(level.squareRoot())) { Text(strings[title]) }
            .progressViewStyle(.linear)
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pending(_ title: String) -> some View {
        HStack {
            ProgressView().controlSize(.small)
            if !compact { Text(strings[title]) }
        }
        .accessibilityLabel(strings[title])
        .help(strings[title])
    }

    private func controls<TimerLabel: View>(
        paused: Bool, pause: @escaping () -> Void, finish: @escaping () -> Void,
        @ViewBuilder timer: () -> TimerLabel
    ) -> some View {
        HStack(spacing: compact ? 5 : 10) {
            let toggleTitle = strings[paused ? "Продолжить" : "Пауза"]
            Button(toggleTitle, systemImage: paused ? "play.fill" : "pause.fill", action: pause)
                .labelStyle(.iconOnly)
                .help(toggleTitle)
                .accessibilityIdentifier(compact ? "toolbar-toggle-recording" : "note-toggle-recording")
            Button(strings["Завершить запись"], systemImage: "stop.fill", action: finish)
                .labelStyle(.iconOnly)
                .tint(.red)
                .help(strings["Завершить запись"])
                .accessibilityIdentifier(compact ? "toolbar-finish-recording" : "note-finish-recording")
            if !compact {
                Spacer(minLength: 0)
                Image(systemName: paused ? "pause.circle" : "record.circle")
                    .foregroundStyle(paused ? Color.secondary : Color.red)
                    .accessibilityHidden(true)
            }
            timer()
                .font(compact ? .subheadline.monospacedDigit() : .title3.monospacedDigit())
                .fixedSize()
                .accessibilityIdentifier(compact ? "toolbar-recording-timer" : "note-recording-timer")
        }
        .buttonStyle(.bordered)
        .controlSize(compact ? .small : .large)
    }

    static func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(max(0, duration))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct NoteRecordingCard: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.translations) private var strings
    let draft: NoteVoiceRecording.Draft
    let note: PlannerNote
    let store: NoteStore
    let voice: NoteVoiceRecording
    let assistant: AssistantService
    let preferences: AppPreferences
    @State private var choosingModel = false
    @State private var confirmation: AssistantTranscriptionSelection?
    @State private var showDiscard = false
    @State private var editingTitle = false
    @State private var titleInput = ""
    @State private var titleSaveFailed = false
    @FocusState private var titleFocused: Bool

    private var defaultTitle: String { strings[draft.isCall ? "Запись звонка" : "Голосовая запись"] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            recordingHeading
            if titleSaveFailed {
                Text(strings["Не удалось сохранить название записи."]).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { draftActions }
                VStack(alignment: .leading, spacing: 10) { draftActions }
            }
            if let issue = voice.transcriptionIssues[draft.id] {
                VStack(alignment: .leading, spacing: 5) {
                    Text(strings.format("%@ · часть %d из %d · %@", issue.provider, issue.part, issue.total, issue.interval))
                        .font(.subheadline.weight(.semibold))
                    let code = issue.code.map { " (\($0))" } ?? ""
                    Text("\(strings[issue.stage]) · \(strings[issue.message])\(code)")
                    if draft.checkpoint?.remoteCleanupFailed == true {
                        Text(strings["Не удалось удалить загруженный файл из GigaChat."])
                    }
                }
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            if let error = voice.errors[draft.id] {
                Text(strings[error]).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .recordingCardStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("note-audio-recording")
        .sheet(isPresented: $choosingModel, onDismiss: openConfirmationIfReady) {
            VStack(alignment: .leading, spacing: 14) {
                Text(strings["Выберите модель для расшифровки"]).font(.headline)
                AssistantSpeechModelMenu(service: assistant, preferences: preferences)
                HStack {
                    Button(strings["Настроить список моделей…"]) {
                        choosingModel = false
                        preferences.assistantSettingsRequest = UUID()
                        openSettings()
                    }
                    Spacer()
                    Button(strings["Готово"]) { choosingModel = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 410)
            .onAppear { assistant.gateways.loadSpeechCatalogs() }
        }
        .sheet(item: $confirmation) { selection in
            NoteVoiceConfirmation(provider: selection.gateway.name, saveCopy: {
                let name = draft.title ?? (note.displayTitle.isEmpty ? strings["Запись"] : note.displayTitle)
                return try await voice.saveCopy(draft.id, suggestedName: name)
            }, transcribe: {
                guard let profile = selection.profile(in: assistant.gateways) else {
                    confirmation = nil
                    choosingModel = true
                    return
                }
                confirmation = nil
                Task { await voice.transcribe(draft.id, store: store, profile: profile,
                                              modelID: selection.modelID, transport: assistant.gateways.http, strings: strings) }
            }, cancel: { confirmation = nil })
        }
        .alert(strings["Удалить запись?"], isPresented: $showDiscard) {
            Button(strings["Удалить запись"], role: .destructive) { voice.discard(draft.id) }
            Button(strings["Отмена"], role: .cancel) {}
        }
    }

    private var recordingHeading: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform").accessibilityHidden(true)
            if editingTitle {
                TextField(defaultTitle, text: $titleInput)
                    .accessibilityLabel(strings["Название записи"])
                    .accessibilityIdentifier("note-recording-title-input")
                    .focused($titleFocused)
                    .onSubmit(saveTitle)
                    .onExitCommand {
                        editingTitle = false
                        titleSaveFailed = false
                    }
                Button(strings["Сохранить название"], systemImage: "checkmark", action: saveTitle)
                    .labelStyle(.iconOnly)
                    .help(strings["Сохранить название"])
                    .accessibilityIdentifier("note-recording-save-title")
            } else {
                Text(draft.title ?? defaultTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("note-recording-title")
                Button(strings["Редактировать название записи"], systemImage: "pencil") {
                    titleInput = draft.title ?? defaultTitle
                    editingTitle = true
                    titleFocused = true
                }
                .labelStyle(.iconOnly)
                .help(strings["Редактировать название записи"])
                .accessibilityIdentifier("note-recording-edit-title")
                .disabled(note.deletedAt != nil || store.unreadable)
            }
            Text(NoteActiveRecordingControls.formattedDuration(draft.duration))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityIdentifier("note-recording-duration")
        }
        .font(.headline)
        .buttonStyle(.borderless)
    }

    private func saveTitle() {
        do {
            try voice.rename(draft.id, to: titleInput)
            editingTitle = false
            titleSaveFailed = false
        } catch {
            titleSaveFailed = true
        }
    }

    @ViewBuilder private var draftActions: some View {
        if voice.transcribing.contains(draft.id) {
            ProgressView().controlSize(.small)
            if let progress = voice.transcriptionProgress[draft.id] {
                Text(strings.format("Расшифровка: часть %d из %d", progress.part, progress.total))
            } else { Text(strings["Расшифровка…"]) }
        } else if draft.saved {
            Label(strings["Расшифровка сохранена"], systemImage: "checkmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if note.deletedAt == nil, !store.unreadable {
            if draft.hasTranscript {
                Button(strings["Открыть расшифровку"]) { voice.presentTranscript(draft.id, strings: strings) }
                    .accessibilityIdentifier("note-review-transcript")
            } else {
                let hasProgress = draft.checkpoint?.parts.contains(where: { $0.text != nil || $0.skipped }) == true
                Button(strings[voice.transcriptionIssues[draft.id] != nil || hasProgress ? "Продолжить расшифровку" : "Расшифровать"],
                       action: beginTranscription)
                    .accessibilityIdentifier("note-transcribe")
                if voice.transcriptionIssues[draft.id]?.skipIndex != nil {
                    Button(strings["Пропустить фрагмент"]) {
                        guard voice.skipFailedPart(draft.id) else { return }
                        if voice.drafts[draft.id]?.hasTranscript == true {
                            voice.presentTranscript(draft.id, strings: strings)
                        } else { beginTranscription() }
                    }
                }
            }
        }
        Button(strings["Показать в Finder"]) { voice.showFile(draft.id) }
            .accessibilityIdentifier("note-show-recording")
        if !voice.transcribing.contains(draft.id) {
            Button(strings["Удалить запись"], role: .destructive) { showDiscard = true }
                .accessibilityIdentifier("note-discard-recording")
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

private extension View {
    func recordingCardStyle() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct NoteTranscriptSheet: View {
    @Environment(\.translations) private var strings
    let preview: NoteVoiceRecording.TranscriptPreview
    let noteTitle: String
    let canInsert: Bool
    let insert: () throws -> Void
    let close: () -> Void
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(strings["Расшифровка записи"]).font(.title2.bold())
            Text(noteTitle).font(.subheadline).foregroundStyle(.secondary)
            if preview.isPartial {
                Label(strings["В расшифровке есть пропущенные фрагменты. Запись сохранена."], systemImage: "exclamationmark.triangle")
            }
            ScrollView {
                Text(verbatim: preview.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            if let error = canInsert ? saveError : "Заметка недоступна." {
                Text(strings[error]).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(strings["Закрыть"], action: close).keyboardShortcut(.cancelAction)
                Button(strings["Вставить в заметку"]) {
                    do { try insert() }
                    catch { saveError = (error as? AssistantFailure)?.message ?? error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction).disabled(!canInsert)
                .accessibilityIdentifier("note-insert-transcript")
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 560, minHeight: 300, idealHeight: 420)
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
            Text(strings.format("Аудио будет отправлено в %@ для расшифровки. Запись останется в заметке на этом Mac.", provider))
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
