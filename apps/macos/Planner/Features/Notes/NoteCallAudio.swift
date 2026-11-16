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

    /// Отдельные короткие запросы позволяют повторить сбойный отрезок длинного звонка.
    static func transcriptionPieces(_ source: URL, framesPerPiece: AVAudioFramePosition = framesPerPiece) throws -> [URL] {
        let reader = try AVAudioFile(forReading: source)
        if reader.length <= framesPerPiece { return [source] }
        guard framesPerPiece > 0, let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 8192) else {
            throw AssistantFailure(message: "Не удалось подготовить запись к расшифровке.")
        }
        var files: [URL] = []
        do {
            while reader.framePosition < reader.length {
                try Task.checkCancellation()
                let url = source.deletingLastPathComponent().appending(path: UUID().uuidString + ".m4a")
                files.append(url)
                let writer = try AVAudioFile(forWriting: url, settings: settings(channels: 2))
                let end = min(reader.length, reader.framePosition + framesPerPiece)
                while reader.framePosition < end {
                    try reader.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, end - reader.framePosition)))
                    guard buffer.frameLength > 0 else {
                        throw AssistantFailure(message: "Не удалось подготовить запись к расшифровке.")
                    }
                    try writer.write(from: buffer)
                }
            }
            return files
        } catch {
            for file in files { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }

    private static func settings(channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 96_000
        ]
    }
}
