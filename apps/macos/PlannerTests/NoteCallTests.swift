import AVFoundation
import Testing
@testable import Planner

struct NoteCallTests {
    #if DEBUG
    @MainActor @Test(arguments: [true, false])
    func callMetersShowOnlyTheChannelWithAudio(microphone: Bool) throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        let call = NoteBrowserCall(noteID: UUID(), file: file, russian: true) { _, _ in }
        let frame: [UInt8] = microphone ? [0, 32, 0, 0] : [0, 0, 0, 32]
        try call.startTestCapture(packet: Data(frame))
        #expect(call.microphone == (microphone ? 0.25 : 0))
        #expect(call.tabLevel == (microphone ? 0 : 0.25))
        call.togglePause()
        #expect(call.phase == .paused && call.microphone == 0 && call.tabLevel == 0)
        call.stop()
    }
    #endif

    @Test func waitsForTheWholeAudioPacketAndChecksItsOrigin() throws {
        let header = "POST /session/chunk HTTP/1.1\r\nHost: 127.0.0.1:5060\r\nOrigin: http://127.0.0.1:5060\r\nX-Takt-Call: 1\r\nContent-Length: 4\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(contentsOf: [1, 2])
        guard case .waiting = NoteCallRequest.parse(packet) else {
            Issue.record("A partial packet must wait for its remaining audio.")
            return
        }
        packet.append(contentsOf: [3, 4])
        guard case .ready(let request) = NoteCallRequest.parse(packet) else {
            Issue.record("A complete packet must include exactly its declared audio.")
            return
        }
        #expect(request.body == Data([1, 2, 3, 4]))
        #expect(request.isAuthorized(port: 5060))
        #expect(!request.isAuthorized(port: 5061))

        var crossOrigin = Data(header.replacingOccurrences(of: "Origin: http://127.0.0.1:5060",
                                                         with: "Origin: https://example.com").utf8)
        crossOrigin.append(request.body)
        guard case .ready(let foreign) = NoteCallRequest.parse(crossOrigin) else {
            Issue.record("The parser should leave origin validation to the listener.")
            return
        }
        #expect(!foreign.isAuthorized(port: 5060))
    }

    @Test func preservesBothChannelsAndSplitsACompletedRecording() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "call.m4a")
        let writer = try NoteCallAudio(url: file)
        var bytes = Data()
        for index in 0..<24_000 {
            let mic = Int16(8_000 * sin(Double(index) * 440 * 2 * .pi / 24_000))
            let tab = Int16(19_000 * sin(Double(index) * 880 * 2 * .pi / 24_000))
            bytes.append(contentsOf: [UInt8(truncatingIfNeeded: mic), UInt8(truncatingIfNeeded: mic >> 8),
                                      UInt8(truncatingIfNeeded: tab), UInt8(truncatingIfNeeded: tab >> 8)])
        }
        let levels = try writer.append(bytes)
        #expect(levels.frames == 24_000)
        #expect(levels.tab > levels.microphone)
        writer.close()

        let source = try AVAudioFile(forReading: file)
        #expect(source.processingFormat.channelCount == 2)
        #expect(source.length == 24_000)
        let plan = try NoteCallAudio.TranscriptionPlan(file, framesPerPart: 12_000)
        let parts = try (0..<plan.count).map { try plan.preparePart(at: $0) }
        defer { for part in parts { try? FileManager.default.removeItem(at: part) } }
        #expect(parts.count == 2)
        let readers = try parts.map { try AVAudioFile(forReading: $0) }
        #expect(readers.allSatisfy { $0.length == 12_000 && $0.processingFormat.channelCount == 2 })
    }

    @MainActor @Test func restoresMultipleRecordingsAndRemembersEachSavedTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appending(path: "Notes.json")
        let recordings = directory.appending(path: "NoteRecordings")
        let id: UUID
        let firstID = UUID()
        let secondID = UUID()
        let first: URL
        let second: URL
        do {
            let store = NoteStore(url: library)
            id = try #require(store.create(folder: "test"))
            try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
            first = recordings.appending(path: "\(id).call.\(firstID).m4a")
            second = recordings.appending(path: "\(id).voice.\(secondID).m4a")
            for url in [first, second] {
                let audio = try NoteCallAudio(url: url)
                _ = try audio.append(Data(repeating: 0, count: 24_000 * 4))
                audio.close()
            }
            let emptyNote = try #require(store.create(folder: "test"))
            try Data().write(to: recordings.appending(path: "\(emptyNote).voice.\(UUID()).m4a"))
            store.update(id) { $0.lastVoiceTranscriptID = firstID }
            _ = store.flush()
        }

        let reopened = NoteStore(url: library)
        #expect(Set(reopened.voice.drafts(for: id).map(\.id)) == [firstID, secondID])
        #expect(reopened.voice.drafts.count == 2)
        #expect(reopened.voice.drafts[firstID]?.file == first)
        #expect(reopened.voice.drafts[firstID]?.isCall == true)
        #expect(reopened.voice.drafts[firstID]?.duration == 1)
        #expect(reopened.voice.drafts[firstID]?.saved == true)
        #expect(reopened.voice.drafts[secondID]?.saved == false)
        try reopened.voice.rename(firstID, to: " Planning call ")
        #expect(reopened.voice.drafts[firstID]?.title == "Planning call")
        #expect(reopened.voice.drafts[secondID]?.title == nil)
        try reopened.applyText("Second transcript", to: id, append: true, voiceTranscriptID: secondID)

        let saved = NoteStore(url: library)
        #expect(saved.voice.drafts[firstID]?.saved == true)
        #expect(saved.voice.drafts[secondID]?.saved == true)
        #expect(saved.voice.drafts[firstID]?.title == "Planning call")
        try saved.applyText("Duplicate first transcript", to: id, append: true, voiceTranscriptID: firstID)
        try saved.applyText("Duplicate second transcript", to: id, append: true, voiceTranscriptID: secondID)
        let note = try #require(saved.notes.first(where: { $0.id == id }))
        #expect(note.text == "Second transcript")
        let syncedData = try NoteStore.wireData(note)
        let synced = try JSONDecoder().decode(PlannerNote.self, from: syncedData)
        #expect(synced.appliedVoiceTranscriptIDs == nil)
        #expect(synced.lastVoiceTranscriptID == nil)

        let titleFile = try #require(saved.voice.drafts[firstID]?.titleFile)
        saved.voice.discard(firstID)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: titleFile.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(NoteStore(url: library).voice.drafts(for: id).map(\.id) == [secondID])
    }

    @Test func splitsMonoWithoutAddingASecondChannel() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "voice.m4a")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
        buffer.frameLength = 24_000
        let samples = try #require(buffer.floatChannelData?.pointee)
        for index in 0..<24_000 { samples[index] = sin(Float(index) * 0.1) * 0.2 }
        do {
            let writer = try AVAudioFile(forWriting: file, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1
            ])
            try writer.write(from: buffer)
        }
        let plan = try NoteCallAudio.TranscriptionPlan(file, framesPerPart: 10_000)
        let parts = try (0..<plan.count).map { try plan.preparePart(at: $0) }
        defer { for part in parts { try? FileManager.default.removeItem(at: part) } }
        #expect(parts.count == 3)
        let readers = try parts.map { try AVAudioFile(forReading: $0) }
        #expect(readers.allSatisfy { $0.fileFormat.channelCount == 1 })
        #expect(readers.map(\.length) == [10_000, 10_000, 4_000])
        #expect(try AVAudioFile(forReading: file).length == 24_000)
    }
}
