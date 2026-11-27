package local.planner.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

@Composable
internal fun ChatHistoryBar(chat: ChatState, controller: ChatController, enabled: Boolean, clearFocus: () -> Unit) {
    var showing by rememberSaveable { mutableStateOf(false) }
    var confirming by rememberSaveable { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TextButton(onClick = { clearFocus(); showing = true }, enabled = enabled) {
            Glyph(R.drawable.ic_clock, size = 18.dp, tint = LocalContentColor.current)
            Text(stringResource(R.string.chat_history), Modifier.padding(start = 8.dp))
        }
        Spacer(Modifier.weight(1f))
        ActionIcon(R.drawable.ic_edit, R.string.chat_new_thread, enabled = enabled) {
            clearFocus()
            controller.newThread()
        }
    }
    if (showing) AlertDialog(
        onDismissRequest = { showing = false },
        title = { Text(stringResource(R.string.chat_history)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                LazyColumn(Modifier.heightIn(max = 380.dp).selectableGroup()) {
                    items(chat.threads, key = ChatThreadSummary::id) { thread ->
                        val current = thread.id == chat.threadId
                        Row(
                            Modifier.fillMaxWidth().selectable(current, role = Role.RadioButton, enabled = enabled) {
                                showing = false
                                if (!current) controller.openThread(thread.id)
                            }.padding(vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            RadioButton(selected = current, onClick = null)
                            Text(thread.title ?: stringResource(R.string.chat_new_thread),
                                maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = { showing = false }) { Text(stringResource(R.string.close)) } },
        dismissButton = {
            TextButton(onClick = { showing = false; confirming = true }, enabled = enabled) {
                Text(stringResource(R.string.chat_clear_history), color = MaterialTheme.colorScheme.error)
            }
        },
    )
    if (confirming) {
        Confirm(R.string.chat_clear_history_title, R.string.chat_clear_history_hint, R.string.chat_clear_history,
            dismiss = { confirming = false },
            confirm = {
                confirming = false
                controller.newThread(clear = true)
            },
        )
    }
}
