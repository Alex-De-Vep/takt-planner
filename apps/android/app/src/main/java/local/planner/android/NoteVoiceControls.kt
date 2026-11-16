package local.planner.android

import android.os.SystemClock
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

@Composable
internal fun NoteVoiceControls(draft: NoteDraft, model: PlannerModel, editable: Boolean) {
    val voice = model.noteVoice
    var delete by rememberSaveable { mutableStateOf(false) }
    var transcribe by rememberSaveable { mutableStateOf(false) }
    voice.startedAt?.let { startedAt ->
        val elapsed by produceState(0L, startedAt) {
            while (true) {
                value = SystemClock.elapsedRealtime() - startedAt
                delay(250)
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.voice_timer, voiceDuration(elapsed)), Modifier.weight(1f),
                color = MaterialTheme.colorScheme.error)
            TextButton(onClick = voice::stop) { Text(stringResource(R.string.voice_stop)) }
        }
    }
    voice.clip?.let { clip ->
        Text(stringResource(R.string.voice_clip, voiceDuration(clip.durationMs)), style = MaterialTheme.typography.titleSmall)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            TextButton(onClick = voice::togglePlayback) {
                Text(stringResource(if (voice.playing) R.string.voice_stop else R.string.voice_listen))
            }
            TextButton(onClick = { transcribe = true }, enabled = !draft.transcribing && !draft.saving) {
                Text(stringResource(R.string.voice_transcribe))
            }
            ActionIcon(R.drawable.ic_delete, R.string.voice_delete, enabled = !draft.transcribing && !draft.saving) { delete = true }
        }
    }
    if (draft.transcribing) {
        Text(stringResource(R.string.voice_transcribing))
        LinearProgressIndicator(Modifier.fillMaxWidth())
    }
    val error = voice.error ?: draft.transcriptionError
    error?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }

    if (delete) {
        Confirm(R.string.voice_delete, R.string.voice_delete_hint, R.string.delete, { delete = false }) {
            delete = false
            if (voice.remove()) {
                draft.transcript = null
                draft.transcriptionError = null
            }
        }
    }
    if (transcribe) {
        val chat by model.chat.state.collectAsState()
        TranscriptionDialog(chat.profiles.keys.filter { it in transcriptionModels }, { transcribe = false }) { provider, name ->
            transcribe = false
            model.transcribeNote(draft, provider, name)
        }
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
                    draft.text = if (draft.text.isBlank()) text else draft.text.trimEnd() + "\n\n" + text
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
private fun TranscriptionDialog(
    providers: List<GatewayProvider>, close: () -> Unit, submit: (GatewayProvider, String) -> Unit,
) {
    var selected by rememberSaveable { mutableStateOf<GatewayProvider?>(null) }
    val provider = selected?.takeIf { it in providers } ?: providers.firstOrNull()
    var menu by remember { mutableStateOf(false) }
    var model by rememberSaveable(provider) { mutableStateOf(transcriptionModels[provider].orEmpty()) }
    AlertDialog(
        onDismissRequest = close,
        title = { Text(stringResource(R.string.voice_transcribe)) },
        text = {
            if (provider == null) {
                Text(stringResource(R.string.voice_transcribe_connect))
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.voice_transcribe_send, provider.label))
                    Box {
                        TextButton(onClick = { menu = true }, enabled = providers.size > 1) { Text(provider.label) }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            providers.forEach { entry ->
                                DropdownMenuItem(text = { Text(entry.label) }, onClick = { selected = entry; menu = false })
                            }
                        }
                    }
                    PlannerTextField(model, { model = it }, Modifier.fillMaxWidth().padding(top = 4.dp),
                        placeholder = R.string.voice_model, singleLine = true)
                }
            }
        },
        confirmButton = {
            if (provider != null) {
                TextButton(onClick = { submit(provider, model.trim()) }, enabled = validTranscriptionModel(model.trim())) {
                    Text(stringResource(R.string.voice_transcribe))
                }
            }
        },
        dismissButton = { TextButton(onClick = close) { Text(stringResource(R.string.cancel)) } },
    )
}

private fun voiceDuration(millis: Long): String {
    val seconds = millis / 1000
    return "${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}"
}
