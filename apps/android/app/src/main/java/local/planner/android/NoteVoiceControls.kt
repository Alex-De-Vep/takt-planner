package local.planner.android

import android.os.SystemClock
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
internal fun NoteVoiceControls(draft: NoteDraft, model: PlannerModel, editable: Boolean) {
    val voice = model.noteVoice
    val chat by model.chat.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var delete by rememberSaveable { mutableStateOf(false) }
    var choosing by rememberSaveable { mutableStateOf(false) }
    var managingModels by rememberSaveable { mutableStateOf(false) }
    var confirm by rememberSaveable { mutableStateOf(false) }
    var exportName by rememberSaveable { mutableStateOf<String?>(null) }
    var exportError by rememberSaveable { mutableStateOf(false) }
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("audio/mp4")) { uri ->
        val file = voice.clip?.file?.takeIf { it.name == exportName }
        exportName = null
        if (uri != null && file != null) scope.launch {
            exportError = false
            try {
                withContext(Dispatchers.IO) {
                    val output = requireNotNull(context.contentResolver.openOutputStream(uri))
                    output.use { target -> file.inputStream().use { it.copyTo(target) } }
                }
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                exportError = true
            }
        }
    }
    val clip = voice.clip
    val recording = voice.recording
    val selection = chat.transcription
    val issue = draft.transcriptionIssue

    val colors = MaterialTheme.colorScheme
    if (clip != null || recording != null || voice.error != null || issue != null || exportError) {
        Surface(
            modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
            shape = RoundedCornerShape(16.dp),
            color = colors.primaryContainer,
            contentColor = colors.onPrimaryContainer,
        ) {
            Column(
                Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                if (recording != null) {
                    ActiveVoiceRecording(recording, voice::togglePause, voice::stop)
                } else {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Glyph(R.drawable.ic_waveform, tint = colors.primary, size = 20.dp)
                        Text(stringResource(R.string.voice_recording), Modifier.weight(1f),
                            style = MaterialTheme.typography.titleSmall)
                        if (clip != null) {
                            Text(voiceDuration(clip.durationMs), style = MaterialTheme.typography.labelLarge,
                                fontFamily = FontFamily.Monospace)
                        }
                    }
                    if (clip != null) {
                        Row(
                            Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            TextButton(
                                onClick = {
                                    if (selection == null) {
                                        model.chat.clearMessage()
                                        choosing = true
                                    } else confirm = true
                                },
                                modifier = Modifier.weight(1f, fill = false),
                                enabled = !draft.saving && !draft.transcribing,
                                contentPadding = PaddingValues(end = 8.dp),
                            ) {
                                val label = if (draft.transcriptionAttempt?.completed?.isNotEmpty() == true &&
                                    draft.transcriptionAttempt?.selection == selection) R.string.voice_transcribe_continue
                                    else R.string.voice_transcribe
                                Text(stringResource(label))
                            }
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                ActionIcon(
                                    if (voice.playing) R.drawable.ic_stop else R.drawable.ic_play,
                                    if (voice.playing) R.string.voice_stop else R.string.voice_listen,
                                    tint = colors.primary,
                                    onClick = voice::togglePlayback,
                                )
                                val fileName = stringResource(R.string.voice_recording_filename)
                                ActionIcon(R.drawable.ic_download, R.string.voice_save_copy, tint = colors.primary) {
                                    exportName = clip.file.name
                                    export.launch(fileName)
                                }
                                ActionIcon(R.drawable.ic_delete, R.string.voice_delete, tint = colors.primary,
                                    enabled = !draft.transcribing && !draft.saving) { delete = true }
                            }
                        }
                    }
                }
                if (draft.transcribing) {
                    val part = draft.transcriptionPart
                    val status = if (part == null) stringResource(R.string.voice_transcribing)
                        else stringResource(R.string.voice_transcribing_part, part)
                    Text(status, style = MaterialTheme.typography.bodySmall)
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                }
                voice.error?.let { Text(stringResource(it), color = colors.error) }
                issue?.let {
                    val message = stringResource(it.messageId)
                    val status = it.part?.let { part -> stringResource(R.string.voice_transcript_part_failure, part, message) }
                    Text(status ?: message, Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                        style = MaterialTheme.typography.bodySmall,
                        color = if (it.messageId == R.string.voice_transcript_empty) colors.onPrimaryContainer else colors.error)
                }
                if (draft.transcriptionCleanupFailed) {
                    Text(stringResource(R.string.voice_remote_cleanup_error), color = colors.error,
                        style = MaterialTheme.typography.bodySmall)
                }
                if (exportError) Text(stringResource(R.string.voice_copy_error), color = MaterialTheme.colorScheme.error)
            }
        }
    }

    if (delete) {
        Confirm(R.string.voice_delete, R.string.voice_delete_hint, R.string.delete, { delete = false }) {
            delete = false
            if (voice.remove()) {
                draft.transcript = null
                draft.transcriptionIssue = null
                draft.transcriptionCleanupFailed = false
                draft.transcriptionAttempt = null
            }
        }
    }
    if (choosing) {
        TranscriptionModelDialog(model.chat, manage = {
            choosing = false
            managingModels = true
        }, chosen = { confirm = true }) { choosing = false }
    }
    if (managingModels) {
        ChatConnectionDialog(model.chat) {
            managingModels = false
            choosing = true
        }
    }
    if (confirm && selection != null && clip != null) {
        AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text(stringResource(R.string.voice_transcribe)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.voice_transcribe_send, selection.provider.label))
                    Text(selection.label, style = MaterialTheme.typography.titleSmall)
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    confirm = false
                    model.transcribeNote(draft, selection)
                }) { Text(stringResource(R.string.voice_transcribe)) }
            },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
    draft.transcript?.let { text ->
        AlertDialog(
            onDismissRequest = { draft.transcript = null },
            title = { Text(stringResource(R.string.voice_transcript)) },
            text = {
                SelectionContainer {
                    Text(text, Modifier.verticalScroll(rememberScrollState()))
                }
            },
            confirmButton = {
                if (editable) TextButton(onClick = {
                    draft.text = if (draft.text.isBlank()) text else draft.text + "\n\n" + text
                    draft.transcript = null
                }) { Text(stringResource(R.string.voice_insert)) }
            },
            dismissButton = {
                TextButton(onClick = { draft.transcript = null }) { Text(stringResource(R.string.close)) }
            },
        )
    }
}

@Composable
private fun ActiveVoiceRecording(recording: VoiceRecording, togglePause: () -> Unit, stop: () -> Unit) {
    val elapsed by produceState(recording.elapsedAt(SystemClock.elapsedRealtime()), recording) {
        while (true) {
            value = recording.elapsedAt(SystemClock.elapsedRealtime())
            if (recording.paused) break
            delay(250)
        }
    }
    val colors = MaterialTheme.colorScheme
    val buttonColors = IconButtonDefaults.filledTonalIconButtonColors(containerColor = colors.surface)
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Glyph(R.drawable.ic_waveform, tint = colors.primary, size = 20.dp)
        Column(Modifier.weight(1f).padding(start = 4.dp)) {
            Text(voiceDuration(elapsed), style = MaterialTheme.typography.titleLarge, fontFamily = FontFamily.Monospace)
            Text(
                stringResource(if (recording.paused) R.string.voice_paused else R.string.voice_in_progress),
                style = MaterialTheme.typography.labelMedium,
            )
        }
        FilledTonalIconButton(onClick = togglePause, colors = buttonColors) {
            Glyph(
                if (recording.paused) R.drawable.ic_play else R.drawable.ic_pause,
                stringResource(if (recording.paused) R.string.voice_resume else R.string.voice_pause),
                tint = colors.primary,
            )
        }
        FilledTonalIconButton(onClick = stop, colors = buttonColors) {
            Glyph(R.drawable.ic_stop, stringResource(R.string.voice_finish_recording), tint = colors.error)
        }
    }
}

private fun voiceDuration(millis: Long): String {
    val seconds = millis / 1000
    return "${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}"
}
