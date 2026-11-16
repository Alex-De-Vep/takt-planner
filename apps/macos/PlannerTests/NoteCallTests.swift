import AVFoundation
import Testing
@testable import Planner

struct NoteCallTests {
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
        let parts = try NoteCallAudio.transcriptionPieces(file, framesPerPiece: 12_000)
        #expect(parts.count == 2)
        let readers = try parts.map { try AVAudioFile(forReading: $0) }
        #expect(readers.allSatisfy { $0.length == 12_000 && $0.processingFormat.channelCount == 2 })
    }

    @MainActor @Test func restoresOnlyPlayableDraftsFromTheSameLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appending(path: "Notes.json")
        let id: UUID
        let source: URL
        let recordingID = UUID()
        do {
            let store = NoteStore(url: library)
            id = try #require(store.create(folder: "test"))
            let recordings = directory.appending(path: "NoteRecordings")
            try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
            source = recordings.appending(path: "\(id).call.\(recordingID).m4a")
            let audio = try NoteCallAudio(url: source)
            _ = try audio.append(Data(repeating: 0, count: 24_000 * 4))
            audio.close()
            let emptyNote = try #require(store.create(folder: "test"))
            try Data().write(to: recordings.appending(path: "\(emptyNote).voice.\(UUID()).m4a"))
        }

        let reopened = NoteStore(url: library)
        #expect(reopened.voice.drafts.count == 1)
        #expect(reopened.voice.drafts[id]?.file == source)
        #expect(reopened.voice.drafts[id]?.isCall == true)
        #expect(reopened.voice.drafts[id]?.saved == false)
        try reopened.applyText("Расшифровка", to: id, append: true, voiceTranscriptID: recordingID)

        let saved = NoteStore(url: library)
        #expect(saved.voice.drafts[id]?.saved == true)
        try saved.applyText("Расшифровка", to: id, append: true, voiceTranscriptID: recordingID)
        #expect(saved.notes.first(where: { $0.id == id })?.text == "Расшифровка")
        saved.voice.discard(id)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(NoteStore(url: library).voice.drafts.isEmpty)
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
        let parts = try NoteCallAudio.transcriptionPieces(file, outputDirectory: directory.appending(path: "parts"),
                                                          framesPerPiece: 12_000)
        #expect(parts.count == 2)
        for part in parts {
            let reader = try AVAudioFile(forReading: part)
            #expect(reader.fileFormat.channelCount == 1)
            #expect(reader.length == 12_000)
        }
    }
}
