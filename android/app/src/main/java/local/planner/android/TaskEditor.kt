package local.planner.android

import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.CalendarContract
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
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
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.google.gson.JsonParser
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TaskEditor(
    library: Library, task: Entity?, section: String, model: PlannerModel, snackbar: SnackbarHostState, close: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val baseline by rememberSaveable { mutableStateOf(task?.let { json.toJson(it) }) }
    val original = remember(baseline) { baseline?.let { json.fromJson(it, Entity::class.java) } }
    val originalLocation by rememberSaveable {
        mutableStateOf(task?.let(library::location) ?: section.takeUnless { it in listOf("today", "all") } ?: "inbox")
    }
    val originalFocus by rememberSaveable { mutableStateOf(task?.focused ?: (section == "today")) }
    var title by rememberSaveable { mutableStateOf(original?.text("title").orEmpty()) }
    var description by rememberSaveable { mutableStateOf(original?.text("description").orEmpty()) }
    var location by rememberSaveable { mutableStateOf(originalLocation) }
    var focused by rememberSaveable { mutableStateOf(originalFocus) }
    var deadlineWire by rememberSaveable { mutableStateOf(original?.deadline?.wire()?.toString()) }
    val deadline = remember(deadlineWire) { deadlineWire?.let { Deadline.read(JsonParser.parseString(it)) } }
    val activeLocation = location.takeIf { it in listOf("inbox", "week", "month") ||
        library.folders.any { folder -> folder.id == it } } ?: "inbox"
    var newItems by rememberSaveable { mutableStateOf(arrayListOf<String>()) }
    var action by rememberSaveable { mutableStateOf<String?>(null) }
    var folderMenu by remember { mutableStateOf(false) }

    val dirty = title != original?.text("title").orEmpty() || description != original?.text("description").orEmpty() ||
        location != originalLocation || focused != originalFocus || deadline != original?.deadline || newItems.isNotEmpty()
    val navigateBack = { if (dirty) action = "discard" else close() }
    BackHandler(onBack = navigateBack)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(if (task == null) R.string.new_task else R.string.task_details)) },
                navigationIcon = { ActionIcon(R.drawable.ic_back, R.string.back, onClick = navigateBack) },
                actions = {
                    if (task != null) ActionIcon(R.drawable.ic_delete, R.string.delete_task) { action = "delete" }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).imePadding(), contentAlignment = Alignment.TopCenter) {
            Column(
                Modifier.widthIn(max = 720.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                OutlinedTextField(title, { title = it }, Modifier.fillMaxWidth(), singleLine = true,
                    label = { Text(stringResource(R.string.task_title)) })
                OutlinedTextField(description, { description = it }, Modifier.fillMaxWidth(), minLines = 3,
                    label = { Text(stringResource(R.string.description)) })
                Box {
                    TextButton(onClick = { folderMenu = true }) {
                        Glyph(R.drawable.ic_folder)
                        Text(sectionName(activeLocation, library), Modifier.padding(start = 8.dp))
                    }
                    DropdownMenu(expanded = folderMenu, onDismissRequest = { folderMenu = false }) {
                        (listOf("inbox", "week", "month") + library.folders.map(Entity::id)).forEach { key ->
                            DropdownMenuItem(text = { Text(sectionName(key, library)) }, onClick = {
                                location = key
                                folderMenu = false
                            })
                        }
                    }
                }
                val focusLabel = stringResource(R.string.show_in_today)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(focused, { focused = it }, Modifier.semantics {
                        contentDescription = focusLabel
                    })
                    Text(focusLabel)
                }
                HorizontalDivider()
                Text(stringResource(R.string.deadline), style = MaterialTheme.typography.titleMedium)
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = { action = "date" }) {
                        Glyph(R.drawable.ic_calendar)
                        Text(deadline?.let(::deadlineLabel) ?: stringResource(R.string.choose_date), Modifier.padding(start = 8.dp))
                    }
                    if (deadline != null) {
                        ActionIcon(R.drawable.ic_close, R.string.remove_deadline) { deadlineWire = null }
                    }
                }
                if (deadline != null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        TextButton(onClick = { action = "time" }) {
                            Text(stringResource(if (deadline.instant == null) R.string.add_time else R.string.change_time))
                        }
                        if (deadline.instant != null) {
                            TextButton(onClick = {
                                deadlineWire = Deadline(deadline.agendaDate(), null, ZoneId.systemDefault()).wire().toString()
                            }) { Text(stringResource(R.string.remove_time)) }
                        }
                    }
                }
                if (task != null) {
                    TextButton(onClick = {
                        val calendar = Intent(Intent.ACTION_INSERT, CalendarContract.Events.CONTENT_URI)
                            .putExtra(CalendarContract.Events.TITLE, title)
                            .putExtra(CalendarContract.Events.DESCRIPTION, description)
                        deadline?.instant?.let {
                            calendar.putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, it.toEpochMilli())
                            calendar.putExtra(CalendarContract.EXTRA_EVENT_END_TIME, it.plusSeconds(1800).toEpochMilli())
                        }
                        try {
                            context.startActivity(calendar)
                        } catch (_: ActivityNotFoundException) {
                            scope.launch { snackbar.showSnackbar(context.getString(R.string.calendar_unavailable)) }
                        }
                    }) { Text(stringResource(R.string.add_calendar_event)) }
                }
                HorizontalDivider()
                Text(stringResource(R.string.checklist), style = MaterialTheme.typography.titleMedium)
                task?.let { current ->
                    library.items(current.id).forEach { item ->
                        val itemTitle = item.text("title").orEmpty()
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(item.flag("isCompleted"), { model.toggleItem(item) }, Modifier.semantics {
                                contentDescription = itemTitle
                            })
                            Text(itemTitle, Modifier.weight(1f))
                            ActionIcon(R.drawable.ic_edit, R.string.edit_item) { action = "item:${item.id}" }
                            ActionIcon(R.drawable.ic_delete, R.string.delete_item) { model.remove(item) }
                        }
                    }
                }
                newItems.forEachIndexed { index, text ->
                    Row(Modifier.padding(start = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(text, Modifier.weight(1f))
                        ActionIcon(R.drawable.ic_edit, R.string.edit_item) { action = "draft:$index" }
                        ActionIcon(R.drawable.ic_delete, R.string.delete_item) {
                            newItems = ArrayList(newItems.filterIndexed { i, _ -> i != index })
                        }
                    }
                }
                TextButton(onClick = { action = "item" }) {
                    Glyph(R.drawable.ic_add)
                    Text(stringResource(R.string.add_item), Modifier.padding(start = 8.dp))
                }
                Button(
                    onClick = { model.saveTask(original, originalLocation, title, description, activeLocation, focused, deadline, newItems, close) },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = title.isNotBlank() || task != null,
                ) { Text(stringResource(R.string.save)) }
            }
        }
    }

    val dismiss = { action = null }
    when (val dialog = action) {
        "discard" -> Confirm(R.string.discard_title, R.string.discard_hint, R.string.discard, dismiss, close)
        "delete" -> if (task != null) {
            Confirm(R.string.delete_task, R.string.delete_task_hint, R.string.delete, dismiss) { model.remove(task, close) }
        }
        "date" -> PickDate(deadline?.agendaDate(), dismiss) { date ->
            val zone = ZoneId.systemDefault()
            val time = deadline?.instant?.atZone(zone)?.toLocalTime()
            deadlineWire = Deadline(date, time?.atDate(date)?.atZone(zone)?.toInstant(), zone).wire().toString()
            dismiss()
        }
        "time" -> if (deadline != null) PickTime(deadline, dismiss) { time ->
            val zone = ZoneId.systemDefault()
            val day = deadline.agendaDate()
            deadlineWire = Deadline(day, day.atTime(time).atZone(zone).toInstant(), zone).wire().toString()
            dismiss()
        }
        "item" -> NameDialog(R.string.add_item, R.string.item_title, "", dismiss) { text ->
            newItems = ArrayList(newItems + text)
            dismiss()
        }
        else -> {
            val itemId = dialog?.substringAfter("item:", "")?.takeIf(String::isNotBlank)
            val item = task?.let { library.items(it.id) }?.firstOrNull { it.id == itemId }
            val index = dialog?.substringAfter("draft:", "")?.toIntOrNull()
            if (item != null) NameDialog(R.string.edit_item, R.string.item_title, item.text("title").orEmpty(), dismiss) {
                model.updateItem(item, it, dismiss)
            }
            if (index != null && index in newItems.indices) NameDialog(R.string.edit_item, R.string.item_title, newItems[index], dismiss) {
                newItems = ArrayList(newItems).apply { set(index, it) }
                dismiss()
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PickDate(initial: LocalDate?, dismiss: () -> Unit, choose: (LocalDate) -> Unit) {
    val millis = (initial ?: LocalDate.now()).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
    val state = rememberDatePickerState(initialSelectedDateMillis = millis)
    DatePickerDialog(
        onDismissRequest = dismiss,
        confirmButton = {
            TextButton(onClick = {
                state.selectedDateMillis?.let { choose(Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate()) }
            }, enabled = state.selectedDateMillis != null) { Text(stringResource(R.string.ok)) }
        },
        dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.cancel)) } },
    ) { DatePicker(state, title = null, headline = null, showModeToggle = false) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PickTime(deadline: Deadline, dismiss: () -> Unit, choose: (LocalTime) -> Unit) {
    val time = deadline.instant?.atZone(ZoneId.systemDefault())?.toLocalTime() ?: LocalTime.of(9, 0)
    val state = rememberTimePickerState(initialHour = time.hour, initialMinute = time.minute,
        is24Hour = android.text.format.DateFormat.is24HourFormat(androidx.compose.ui.platform.LocalContext.current))
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
