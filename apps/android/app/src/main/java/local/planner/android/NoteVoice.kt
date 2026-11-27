package local.planner.android

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import java.io.File

internal data class VoiceClip(val file: File, val durationMs: Long)

internal fun noteAudioFile(context: Context, workspace: String, noteID: String): File {
    val scope = noteDigest(workspace.toByteArray())
    return File(context.filesDir, "note-audio/$scope/$noteID.m4a")
}

internal data class VoiceRecording(val runningSinceMs: Long?, val accumulatedMs: Long = 0) {
    val paused: Boolean get() = runningSinceMs == null

    fun elapsedAt(nowMs: Long): Long = accumulatedMs + (runningSinceMs?.let { nowMs - it } ?: 0L)
}

internal class NoteVoice(private val context: Context) {
    var clip by mutableStateOf<VoiceClip?>(null)
        private set
    var recording by mutableStateOf<VoiceRecording?>(null)
        private set
    var playing by mutableStateOf(false)
        private set
    var error by mutableStateOf<Int?>(null)
        private set

    private var destination: File? = null
    private var recorder: MediaRecorder? = null
    private var player: MediaPlayer? = null

    fun bind(workspace: String, noteId: String) {
        close()
        val file = noteAudioFile(context, workspace, noteId)
        destination = file
        clip = readClip(file)
    }

    fun permissionDenied() { error = R.string.voice_permission }

    @Suppress("DEPRECATION")
    fun start() {
        val file = destination ?: return
        if (recorder != null || clip != null) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            permissionDenied()
            return
        }
        error = null
        val temporary = temporary(file)
        val input = try {
            check(file.parentFile?.let { it.isDirectory || it.mkdirs() } == true)
            if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else MediaRecorder()
        } catch (_: Exception) {
            error = R.string.voice_start_error
            return
        }
        try {
            input.setAudioSource(MediaRecorder.AudioSource.MIC)
            input.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            input.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            input.setAudioChannels(1)
            input.setAudioEncodingBitRate(64_000)
            input.setAudioSamplingRate(24_000)
            input.setOutputFile(temporary.absolutePath)
            input.setOnInfoListener { current, what, _ ->
                if (recorder === current && (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED ||
                        what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_REACHED)) stop()
            }
            input.setOnErrorListener { current, _, _ -> if (recorder === current) stop() }
            input.prepare()
            input.start()
            recorder = input
            recording = VoiceRecording(runningSinceMs = SystemClock.elapsedRealtime())
        } catch (_: Exception) {
            runCatching { input.release() }
            temporary.delete()
            error = R.string.voice_start_error
        }
    }

    fun togglePause() {
        val input = recorder ?: return
        val session = recording ?: return
        try {
            recording = if (session.paused) {
                input.resume()
                session.copy(runningSinceMs = SystemClock.elapsedRealtime())
            } else {
                input.pause()
                VoiceRecording(runningSinceMs = null, accumulatedMs = session.elapsedAt(SystemClock.elapsedRealtime()))
            }
            error = null
        } catch (_: RuntimeException) {
            error = if (session.paused) R.string.voice_resume_error else R.string.voice_pause_error
        }
    }

    fun stop() {
        val input = recorder ?: return
        val file = requireNotNull(destination)
        val temporary = temporary(file)
        recorder = null
        recording = null
        error = null
        runCatching { input.stop() }
        runCatching { input.release() }
        // The recorder can already have stopped at the Android duration or size limit.
        val saved = readClip(temporary)
        if (saved != null && temporary.renameTo(file)) {
            clip = saved.copy(file = file)
        } else {
            temporary.delete()
            error = R.string.voice_save_error
        }
    }

    fun togglePlayback() {
        if (player != null) {
            stopPlayback()
            return
        }
        val audio = clip ?: return
        error = null
        val playback = MediaPlayer()
        player = playback
        try {
            playback.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            playback.setDataSource(audio.file.absolutePath)
            playback.setOnPreparedListener { current ->
                if (player === current) {
                    if (runCatching { current.start() }.isSuccess) playing = true else playbackFailed()
                }
            }
            playback.setOnCompletionListener { current -> if (player === current) stopPlayback() }
            playback.setOnErrorListener { current, _, _ ->
                if (player === current) playbackFailed()
                true
            }
            playback.prepareAsync()
        } catch (_: Exception) {
            playbackFailed()
        }
    }

    fun remove(): Boolean {
        stopPlayback()
        val file = clip?.file ?: return true
        if (file.delete() || !file.exists()) {
            clip = null
            error = null
            return true
        }
        error = R.string.voice_delete_error
        return false
    }

    fun suspendMedia() {
        stop()
        stopPlayback()
    }

    fun close(discard: Boolean = false) {
        suspendMedia()
        if (discard) remove()
        clip = null
        error = null
        destination = null
    }

    private fun playbackFailed() {
        stopPlayback()
        error = R.string.voice_playback_error
    }

    private fun stopPlayback() {
        val playback = player
        player = null
        playing = false
        runCatching { playback?.release() }
    }

    private fun temporary(file: File) = File(file.parentFile, "${file.nameWithoutExtension}.part.m4a")

    private fun readClip(file: File): VoiceClip? {
        if (file.length() <= 0) return null
        val reader = MediaMetadataRetriever()
        return try {
            reader.setDataSource(file.absolutePath)
            if (reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) != "yes") return null
            val duration = reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
            duration?.takeIf { it > 0 }?.let { VoiceClip(file, it) }
        } catch (_: Exception) {
            null
        } finally {
            runCatching { reader.release() }
        }
    }
}
