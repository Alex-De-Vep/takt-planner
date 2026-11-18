package local.planner.android

import android.os.SystemClock
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
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
    val startedAt = voice.startedAt
    val selection = chat.transcription
    val error = voice.error ?: draft.transcriptionError

    if (clip != null || startedAt != null || error != null || exportError) {
        Surface(
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            shape = RoundedCornerShape(12.dp),
            color = MaterialTheme.colorScheme.surfaceContainerLow,
        ) {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Glyph(R.drawable.ic_waveform, tint = MaterialTheme.colorScheme.primary)
                    Text(stringResource(R.string.voice_recording), Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                    if (clip != null) Text(voiceDuration(clip.durationMs), fontFamily = FontFamily.Monospace)
                }
                if (startedAt != null) {
                    val elapsed by produceState(0L, startedAt) {
                        while (true) {
                            value = SystemClock.elapsedRealtime() - startedAt
                            delay(250)
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(voiceDuration(elapsed), Modifier.weight(1f), color = MaterialTheme.colorScheme.error,
                            fontFamily = FontFamily.Monospace)
                        TextButton(onClick = voice::stop) { Text(stringResource(R.string.voice_stop)) }
                    }
                } else if (clip != null) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        TextButton(onClick = voice::togglePlayback) {
                            Text(stringResource(if (voice.playing) R.string.voice_stop else R.string.voice_listen))
                        }
                        TextButton(onClick = {
                            if (selection == null) {
                                model.chat.clearCandidate()
                                choosing = true
                            } else confirm = true
                        }, enabled = !draft.saving && !draft.transcribing) {
                            Text(stringResource(R.string.voice_transcribe))
                        }
                        val fileName = stringResource(R.string.voice_recording_filename)
                        TextButton(onClick = {
                            exportName = clip.file.name
                            export.launch(fileName)
                        }) { Text(stringResource(R.string.voice_save_copy)) }
                        ActionIcon(R.drawable.ic_delete, R.string.voice_delete, enabled = !draft.transcribing && !draft.saving) {
                            delete = true
                        }
                    }
                }
                if (draft.transcribing) {
                    Text(stringResource(R.string.voice_transcribing), style = MaterialTheme.typography.bodySmall)
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                }
                error?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
                if (exportError) Text(stringResource(R.string.voice_copy_error), color = MaterialTheme.colorScheme.error)
            }
        }
    }

    if (delete) {
        Confirm(R.string.voice_delete, R.string.voice_delete_hint, R.string.delete, { delete = false }) {
            delete = false
            if (voice.remove()) {
                draft.transcript = null
                draft.transcriptionError = null
            }
        }
    }
    if (choosing) {
        TranscriptionConnectionDialog(model.chat, chosen = { confirm = true }) { choosing = false }
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

private fun voiceDuration(millis: Long): String {
    val seconds = millis / 1000
    return "${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}"
}
