package local.planner.android

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

internal const val VOICE_PART_MAX_BYTES = 8L * 1024 * 1024
private const val PART_DURATION_US = 15L * 60 * 1_000_000
private const val MP4_METADATA_BYTES = 512 * 1024
private const val WAVE_PADDING_BYTES = 64 * 1024

internal suspend fun forEachVoicePart(
    clip: VoiceClip,
    directory: File,
    convertToWave: Boolean,
    visit: suspend (number: Int, file: File, split: Boolean) -> Unit,
) {
    prepareVoiceAudio { check(clip.durationMs > 0 && clip.file.isFile && clip.file.canRead() && clip.file.length() > 0) }
    if (!convertToWave && fitsVoicePart(clip, PART_DURATION_US)) {
        visit(1, clip.file, false)
        return
    }
    val extractor = prepareVoiceAudio { MediaExtractor() }
    try {
        val track = prepareVoiceAudio {
            extractor.setDataSource(clip.file.absolutePath)
            (0 until extractor.trackCount).first {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME) == MediaFormat.MIMETYPE_AUDIO_AAC
            }
        }
        val format = prepareVoiceAudio { extractor.getTrackFormat(track) }
        val durationUs = if (convertToWave) prepareVoiceAudio { wavePartDurationUs(format) } else PART_DURATION_US
        if (fitsVoicePart(clip, durationUs)) {
            visit(1, clip.file, false)
            return
        }
        prepareVoiceAudio { extractor.selectTrack(track) }
        val buffer = ByteBuffer.allocateDirect(64 * 1024)
        var number = 0
        while (extractor.sampleTrackIndex >= 0) {
            currentCoroutineContext().ensureActive()
            val part = prepareVoiceAudio { File.createTempFile("takt-voice-part-", ".m4a", directory) }
            try {
                prepareVoiceAudio {
                    writeVoicePart(extractor, format, buffer, part, durationUs)
                    check(part.length() in 1..VOICE_PART_MAX_BYTES)
                }
                visit(++number, part, true)
            } finally {
                part.delete()
            }
        }
        prepareVoiceAudio { check(number > 0) }
    } finally {
        extractor.release()
    }
}

internal inline fun <T> prepareVoiceAudio(prepare: () -> T): T = try {
    prepare()
} catch (failure: Exception) {
    if (failure is CancellationException) throw failure
    throw VoiceTranscriptionFailure(R.string.voice_transcript_unreadable, failure)
}

private fun fitsVoicePart(clip: VoiceClip, durationUs: Long): Boolean =
    clip.durationMs <= durationUs / 1_000 && clip.file.length() <= VOICE_PART_MAX_BYTES

private fun wavePartDurationUs(format: MediaFormat): Long {
    val bytesPerSecond = format.getInteger(MediaFormat.KEY_SAMPLE_RATE).toLong() *
        format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) * 2
    require(bytesPerSecond > 0)
    return minOf(PART_DURATION_US, (VOICE_WAVE_MAX_BYTES - WAVE_PADDING_BYTES) * 1_000_000 / bytesPerSecond)
}

private suspend fun writeVoicePart(
    extractor: MediaExtractor, format: MediaFormat, buffer: ByteBuffer, file: File, durationUs: Long,
) {
    val muxer = MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    try {
        val track = muxer.addTrack(format)
        muxer.start()
        val start = extractor.sampleTime
        val info = MediaCodec.BufferInfo()
        val coroutine = currentCoroutineContext()
        var written = 0L
        while (extractor.sampleTrackIndex >= 0) {
            coroutine.ensureActive()
            val timeUs = extractor.sampleTime - start
            if (timeUs >= durationUs) break
            buffer.clear()
            val size = extractor.readSampleData(buffer, 0)
            check(size in 1..buffer.capacity())
            if (written + size > VOICE_PART_MAX_BYTES - MP4_METADATA_BYTES) break
            info.set(0, size, timeUs, MediaCodec.BUFFER_FLAG_KEY_FRAME)
            muxer.writeSampleData(track, buffer, info)
            written += size
            extractor.advance()
        }
        check(written > 0)
        muxer.stop()
    } finally {
        muxer.release()
    }
}
