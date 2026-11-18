package local.planner.android

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal const val VOICE_WAVE_MAX_BYTES = 48L * 1024 * 1024
private const val WAV_HEADER_SIZE = 44
private const val CODEC_WAIT_US = 10_000L

internal fun makeVoiceWave(source: File, directory: File?): File {
    val target = File.createTempFile("takt-voice-", ".wav", directory)
    val extractor = MediaExtractor()
    try {
        extractor.setDataSource(source.absolutePath)
        val track = (0 until extractor.trackCount).first {
            extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
        }
        val inputFormat = extractor.getTrackFormat(track)
        val mime = requireNotNull(inputFormat.getString(MediaFormat.KEY_MIME))
        extractor.selectTrack(track)
        val decoder = MediaCodec.createDecoderByType(mime)
        try {
            decoder.configure(inputFormat, null, null, 0)
            decoder.start()
            RandomAccessFile(target, "rw").use { output -> decodeWave(extractor, decoder, output) }
        } finally {
            decoder.release()
        }
        return target
    } catch (failure: Exception) {
        target.delete()
        throw failure
    } finally {
        extractor.release()
    }
}

private fun decodeWave(extractor: MediaExtractor, codec: MediaCodec, output: RandomAccessFile) {
    output.seek(WAV_HEADER_SIZE.toLong())
    val info = MediaCodec.BufferInfo()
    val buffer = ByteArray(8192)
    var inputDone = false
    var outputDone = false
    var lastProgress = SystemClock.elapsedRealtime()
    while (!outputDone) {
        var progressed = false
        if (!inputDone) {
            val index = codec.dequeueInputBuffer(CODEC_WAIT_US)
            if (index >= 0) {
                val input = requireNotNull(codec.getInputBuffer(index))
                input.clear()
                val count = extractor.readSampleData(input, 0)
                inputDone = count < 0
                if (inputDone) {
                    codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                } else {
                    codec.queueInputBuffer(index, 0, count, extractor.sampleTime, 0)
                    extractor.advance()
                }
                progressed = true
            }
        }
        val index = codec.dequeueOutputBuffer(info, CODEC_WAIT_US)
        if (index >= 0) {
            if (info.size > 0) {
                check(output.filePointer + info.size <= VOICE_WAVE_MAX_BYTES)
                val pcm = requireNotNull(codec.getOutputBuffer(index))
                pcm.position(info.offset)
                pcm.limit(info.offset + info.size)
                while (pcm.hasRemaining()) {
                    val count = minOf(pcm.remaining(), buffer.size)
                    pcm.get(buffer, 0, count)
                    output.write(buffer, 0, count)
                }
            }
            outputDone = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
            codec.releaseOutputBuffer(index, false)
            progressed = true
        }
        if (progressed || index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) lastProgress = SystemClock.elapsedRealtime()
        check(SystemClock.elapsedRealtime() - lastProgress < 5_000)
    }
    val format = codec.outputFormat
    check(!format.containsKey(MediaFormat.KEY_PCM_ENCODING) ||
        format.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_16BIT)
    val length = (output.filePointer - WAV_HEADER_SIZE).toInt()
    val channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
    val rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
    check(length > 0 && channels in 1..2 && rate in 8_000..96_000)
    output.seek(0)
    output.write(pcmWaveHeader(length, channels, rate))
}

internal fun pcmWaveHeader(bytes: Int, channels: Int, rate: Int): ByteArray {
    val frameSize = channels * 2
    return ByteBuffer.allocate(WAV_HEADER_SIZE).order(ByteOrder.LITTLE_ENDIAN).apply {
        put("RIFF".toByteArray())
        putInt(bytes + 36)
        put("WAVEfmt ".toByteArray())
        putInt(16)
        putShort(1)
        putShort(channels.toShort())
        putInt(rate)
        putInt(rate * frameSize)
        putShort(frameSize.toShort())
        putShort(16)
        put("data".toByteArray())
        putInt(bytes)
    }.array()
}
