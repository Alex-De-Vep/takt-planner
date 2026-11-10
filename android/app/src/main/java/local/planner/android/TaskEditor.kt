package local.planner.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconToggleButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TaskEditor(
    library: Library, task: Entity?, section: String, model: PlannerModel, snackbar: SnackbarHostState, close: () -> Unit,
) {
    val draft = remember { model.openDraft(library, task, section) }
    val deadline = draft.deadline
    val activeLocation = draft.location.takeIf { it in listOf("inbox", "week", "month") ||
        library.folders.any { folder -> folder.id == it } } ?: "inbox"
    var action by rememberSaveable { mutableStateOf<String?>(null) }
    var folderMenu by remember { mutableStateOf(false) }

    val finish = {
        model.closeDraft()
        close()
    }
    val navigateBack = {
        if (!draft.saving) {
            when {
                !draft.dirty -> finish()
                task == null -> action = "discard"
                else -> model.saveTask(draft, finish)
            }
        }
    }
    BackHandler(onBack = navigateBack)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(if (task == null) R.string.new_task else R.string.task_details)) },
                navigationIcon = { ActionIcon(R.drawable.ic_back, R.string.back, onClick = navigateBack) },
                actions = {
                    if (task != null && !draft.saving) ActionIcon(R.drawable.ic_delete, R.string.delete_task) { action = "delete" }
                },
            )
        },
        bottomBar = {
            EditorBottomAction(when {
                task == null -> R.string.save
                task.completed -> R.string.reopen_task
                else -> R.string.task_mark_done
            }, enabled = !draft.saving && (task != null || draft.title.isNotBlank())) {
                model.saveTask(draft, finish, completion = task?.let { !it.completed })
            }
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.TopCenter) {
            Column(
                Modifier.widthIn(max = 720.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Box {
                    TextButton(onClick = { folderMenu = true }, enabled = !draft.saving) {
                        Glyph(R.drawable.ic_folder)
                        Text(sectionName(activeLocation, library), Modifier.padding(start = 8.dp))
                    }
                    DropdownMenu(expanded = folderMenu, onDismissRequest = { folderMenu = false }) {
                        (listOf("inbox", "week", "month") + library.folders.map(Entity::id)).forEach { key ->
                            DropdownMenuItem(text = { Text(sectionName(key, library)) }, onClick = {
                                draft.location = key
                                folderMenu = false
                            })
                        }
                    }
                }
                OutlinedTextField(draft.title, { draft.title = it }, Modifier.fillMaxWidth().focusNewTitle(task == null), singleLine = true,
                    enabled = !draft.saving, label = { Text(stringResource(R.string.task_title)) })
                OutlinedTextField(draft.description, { draft.description = it }, Modifier.fillMaxWidth(), minLines = 3,
                    enabled = !draft.saving, label = { Text(stringResource(R.string.description)) })
                val accent = MaterialTheme.colorScheme.primary
                val inactive = MaterialTheme.colorScheme.onSurfaceVariant
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconToggleButton(draft.focused, { draft.focused = it }, enabled = !draft.saving) {
                        Glyph(
                            if (draft.focused) R.drawable.ic_star else R.drawable.ic_star_outline,
                            stringResource(if (draft.focused) R.string.unstar else R.string.star),
                            if (draft.focused) accent else inactive,
                        )
                    }
                    ActionIcon(R.drawable.ic_calendar, R.string.choose_date, if (deadline != null) accent else inactive,
                        enabled = !draft.saving) { action = "date" }
                    ActionIcon(R.drawable.ic_add_subtask, R.string.add_item, inactive, enabled = !draft.saving) {
                        action = "item"
                    }
                }
                if (deadline != null) {
                    val date = deadline.agendaDate()
                    val time = deadline.instant?.atZone(ZoneId.systemDefault())?.toLocalTime()
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        DeadlineChip(
                            R.drawable.ic_calendar, dateLabel(date), R.string.choose_date, !draft.saving,
                            edit = { action = "date" }, clearLabel = R.string.remove_deadline,
                            clear = { draft.deadline = null },
                        )
                        DeadlineChip(
                            R.drawable.ic_clock, time?.let { timeLabel(it) } ?: stringResource(R.string.add_time),
                            if (time == null) R.string.add_time else R.string.change_time, !draft.saving,
                            edit = { action = "time" }, clearLabel = R.string.remove_time.takeIf { time != null },
                            clear = { draft.deadline = Deadline(date, null, ZoneId.systemDefault()) },
                        )
                    }
                }
                val items = task?.let { library.items(it.id) }.orEmpty()
                if (items.isNotEmpty() || draft.newItems.isNotEmpty()) {
                    Text(stringResource(R.string.checklist), style = MaterialTheme.typography.titleMedium)
                }
                items.forEach { item ->
                    val itemTitle = item.text("title").orEmpty()
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(item.flag("isCompleted"), { model.toggleItem(item) }, Modifier.semantics {
                            contentDescription = itemTitle
                        }, enabled = !draft.saving)
                        Text(itemTitle, Modifier.weight(1f))
                        ActionIcon(R.drawable.ic_edit, R.string.edit_item, enabled = !draft.saving) { action = "item:${item.id}" }
                        ActionIcon(R.drawable.ic_delete, R.string.delete_item, enabled = !draft.saving) { model.remove(item) }
                    }
                }
                draft.newItems.forEachIndexed { index, text ->
                    Row(Modifier.padding(start = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(text, Modifier.weight(1f))
                        ActionIcon(R.drawable.ic_edit, R.string.edit_item, enabled = !draft.saving) { action = "draft:$index" }
                        ActionIcon(R.drawable.ic_delete, R.string.delete_item, enabled = !draft.saving) {
                            draft.newItems = draft.newItems.filterIndexed { i, _ -> i != index }
                        }
                    }
                }
            }
        }
    }

    val dismiss = { action = null }
    when (val dialog = action) {
        "discard" -> Confirm(R.string.discard_title, R.string.discard_hint, R.string.discard, dismiss, finish)
        "delete" -> if (task != null) {
            Confirm(R.string.delete_task, R.string.delete_task_hint, R.string.delete, dismiss) { model.remove(task, finish) }
        }
        "date" -> PickDate(deadline?.agendaDate(), dismiss) { date ->
            val zone = ZoneId.systemDefault()
            val time = deadline?.instant?.atZone(zone)?.toLocalTime()
            draft.deadline = Deadline(date, time?.atDate(date)?.atZone(zone)?.toInstant(), zone)
            dismiss()
        }
        "time" -> if (deadline != null) PickTime(
            deadline.instant?.atZone(ZoneId.systemDefault())?.toLocalTime() ?: LocalTime.of(9, 0), dismiss,
        ) { time ->
            val zone = ZoneId.systemDefault()
            val day = deadline.agendaDate()
            draft.deadline = Deadline(day, day.atTime(time).atZone(zone).toInstant(), zone)
            dismiss()
        }
        "item" -> NameDialog(R.string.add_item, R.string.item_title, "", dismiss) { text ->
            draft.newItems = draft.newItems + text
            dismiss()
        }
        else -> {
            val itemId = dialog?.substringAfter("item:", "")?.takeIf(String::isNotBlank)
            val item = task?.let { library.items(it.id) }?.firstOrNull { it.id == itemId }
            val index = dialog?.substringAfter("draft:", "")?.toIntOrNull()
            if (item != null) NameDialog(R.string.edit_item, R.string.item_title, item.text("title").orEmpty(), dismiss) {
                model.updateItem(item, it, dismiss)
            }
            if (index != null && index in draft.newItems.indices) NameDialog(R.string.edit_item, R.string.item_title, draft.newItems[index], dismiss) {
                draft.newItems = draft.newItems.toMutableList().apply { set(index, it) }
                dismiss()
            }
        }
    }
}

@Composable
internal fun Modifier.focusNewTitle(creating: Boolean): Modifier {
    if (!creating) return this
    val requester = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    var requested by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        if (!requested && requester.requestFocus()) {
            keyboard?.show()
            requested = true
        }
    }
    return focusRequester(requester)
}

@Composable
private fun DeadlineChip(
    icon: Int, text: String, editLabel: Int, enabled: Boolean, edit: () -> Unit, clearLabel: Int?, clear: () -> Unit,
) {
    val label = stringResource(editLabel)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Glyph(icon, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Surface(shape = MaterialTheme.shapes.small, border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(
                    onClick = edit, enabled = enabled,
                    modifier = Modifier.weight(1f, fill = false).semantics { contentDescription = label },
                ) { Text(text) }
                if (clearLabel != null) ActionIcon(R.drawable.ic_close, clearLabel, enabled = enabled, onClick = clear)
            }
        }
    }
}

@Composable
internal fun EditorBottomAction(label: Int, enabled: Boolean, onClick: () -> Unit) {
    Box(Modifier.fillMaxWidth().navigationBarsPadding().imePadding(), contentAlignment = Alignment.Center) {
        Button(
            onClick = onClick, enabled = enabled,
            modifier = Modifier.widthIn(max = 720.dp).fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
        ) { Text(stringResource(label)) }
    }
}

@Composable
internal fun dateLabel(date: LocalDate, style: FormatStyle = FormatStyle.MEDIUM): String = date.format(
    DateTimeFormatter.ofLocalizedDate(style).withLocale(LocalConfiguration.current.locales[0]),
)

@Composable
internal fun timeLabel(time: LocalTime): String {
    val pattern = if (android.text.format.DateFormat.is24HourFormat(LocalContext.current)) "HH:mm" else "h:mm a"
    return time.format(DateTimeFormatter.ofPattern(pattern, LocalConfiguration.current.locales[0]))
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun PickDate(initial: LocalDate?, dismiss: () -> Unit, choose: (LocalDate) -> Unit) {
    val date = initial ?: LocalDate.now()
    val millis = date.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
    val state = rememberDatePickerState(
        initialSelectedDateMillis = millis,
        yearRange = minOf(1900, date.year)..maxOf(2100, date.year),
    )
    DatePickerDialog(
        onDismissRequest = dismiss,
        confirmButton = {
            TextButton(onClick = {
                state.selectedDateMillis?.let { choose(Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate()) }
            }, enabled = state.selectedDateMillis != null) { Text(stringResource(R.string.ok)) }
        },
        dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.cancel)) } },
    ) { DatePicker(state, title = null, headline = null) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun PickTime(time: LocalTime, dismiss: () -> Unit, choose: (LocalTime) -> Unit) {
    val state = rememberTimePickerState(initialHour = time.hour, initialMinute = time.minute,
        is24Hour = android.text.format.DateFormat.is24HourFormat(LocalContext.current))
    AlertDialog(
        onDismissRequest = dismiss, title = { Text(stringResource(R.string.choose_time)) },
        text = { Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { TimePicker(state) } },
        confirmButton = { TextButton(onClick = { choose(LocalTime.of(state.hour, state.minute)) }) { Text(stringResource(R.string.ok)) } },
        dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
internal fun MissingTask(snackbar: SnackbarHostState, close: () -> Unit) {
    BackHandler(onBack = close)
    Scaffold(snackbarHost = { SnackbarHost(snackbar) }) { padding ->
        Column(Modifier.padding(padding).padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            EmptyPanel(R.drawable.ic_list, R.string.task_missing, R.string.task_missing_hint)
            TextButton(onClick = close) { Text(stringResource(R.string.back)) }
        }
    }
}

@Composable
internal fun Confirm(title: Int, hint: Int, label: Int, dismiss: () -> Unit, confirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = dismiss, title = { Text(stringResource(title)) }, text = { Text(stringResource(hint)) },
        confirmButton = { TextButton(onClick = confirm) { Text(stringResource(label)) } },
        dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
internal fun NameDialog(title: Int, label: Int, initial: String, dismiss: () -> Unit, submit: (String) -> Unit) {
    var text by rememberSaveable(initial) { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = dismiss, title = { Text(stringResource(title)) },
        text = { OutlinedTextField(text, { text = it }, singleLine = true, label = { Text(stringResource(label)) }) },
        confirmButton = { TextButton(onClick = { submit(text) }, enabled = text.isNotBlank()) { Text(stringResource(R.string.save)) } },
        dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.cancel)) } },
    )
}
