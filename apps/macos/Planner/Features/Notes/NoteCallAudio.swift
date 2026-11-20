import AVFoundation

/// Два канала на одном такте браузера: микрофон слева, звук вкладки справа.
final class NoteCallAudio {
    static let sampleRate = 24_000
    static let framesPerPiece = AVAudioFramePosition(sampleRate * 5 * 60)
    private var writer: AVAudioFile?
    private let buffer: AVAudioPCMBuffer

    init(url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: Self.settings(channels: 2))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000) else {
            throw AssistantFailure(message: "Не удалось начать запись звонка.")
        }
        writer = file
        self.buffer = buffer
    }

    /// Возвращает уровни до сжатия и число записанных сэмплов для таймера.
    func append(_ data: Data) throws -> (microphone: Float, tab: Float, frames: Int) {
        let frames = data.count / 4
        guard let writer, let channels = buffer.floatChannelData,
              frames > 0, frames <= buffer.frameCapacity, data.count.isMultiple(of: 4) else {
            throw AssistantFailure(message: "Не удалось сохранить звук звонка.")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        var microphone: Float = 0
        var tab: Float = 0
        data.withUnsafeBytes { bytes in
            for i in 0..<frames {
                let offset = i * 4
                let left = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32_768
                let right = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 2, as: Int16.self))) / 32_768
                channels[0][i] = left
                channels[1][i] = right
                microphone = max(microphone, abs(left))
                tab = max(tab, abs(right))
            }
        }
        try writer.write(from: buffer)
        return (microphone, tab, frames)
    }

    func close() { writer = nil }

    /// План строится по исходному файлу. Одновременно на диске нужен только один фрагмент.
    struct TranscriptionPlan: Sendable {
        let source: URL
        let totalFrames: AVAudioFramePosition
        let framesPerPart: AVAudioFramePosition
        var count: Int { Int((totalFrames - 1) / framesPerPart + 1) }

        init(_ source: URL, framesPerPart: AVAudioFramePosition = NoteCallAudio.framesPerPiece) throws {
            let reader = try AVAudioFile(forReading: source)
            guard reader.length > 0, framesPerPart > 0 else {
                throw AssistantFailure(message: "Не удалось подготовить запись к расшифровке.")
            }
            self.source = source
            totalFrames = reader.length
            self.framesPerPart = framesPerPart
        }

        func preparePart(at index: Int) throws -> URL {
            try Task.checkCancellation()
            if count == 1 { return source }
            let reader = try AVAudioFile(forReading: source)
            let start = AVAudioFramePosition(index) * framesPerPart
            let end = min(totalFrames, start + framesPerPart)
            let format = reader.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
                throw AssistantFailure(message: "Не удалось подготовить запись к расшифровке.")
            }
            let url = FileManager.default.temporaryDirectory.appending(path: "Takt-Voice-Part-" + UUID().uuidString + ".m4a")
            do {
                reader.framePosition = start
                var settings = NoteCallAudio.settings(channels: Int(format.channelCount))
                settings[AVSampleRateKey] = format.sampleRate
                let writer = try AVAudioFile(forWriting: url, settings: settings)
                while reader.framePosition < end {
                    try Task.checkCancellation()
                    try reader.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, end - reader.framePosition)))
                    guard buffer.frameLength > 0 else {
                        throw AssistantFailure(message: "Не удалось подготовить запись к расшифровке.")
                    }
                    try writer.write(from: buffer)
                }
                return url
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
    }

    static func transcriptionWAV(_ source: URL) throws -> URL {
        let reader = try AVAudioFile(forReading: source)
        let format = reader.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw AssistantFailure(message: "Не удалось подготовить запись к расшифровке.")
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
        do {
            let writer = try AVAudioFile(forWriting: destination, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16
            ])
            while reader.framePosition < reader.length {
                try Task.checkCancellation()
                try reader.read(into: buffer)
                guard buffer.frameLength > 0 else {
                    throw AssistantFailure(message: "Не удалось подготовить запись к расшифровке.")
                }
                try writer.write(from: buffer)
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func settings(channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 64_000 : 96_000
        ]
    }
}
