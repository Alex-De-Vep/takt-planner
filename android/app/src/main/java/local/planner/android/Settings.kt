package local.planner.android

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
internal fun Settings(
    library: Library, cloud: CloudState, model: PlannerModel,
    calendar: DeviceCalendar, calendarRefresh: Int, calendarSettings: () -> Unit, chatSettings: () -> Unit,
) {
    var signOut by rememberSaveable { mutableStateOf(false) }
    val profile = requireNotNull(library.profile)
    val chat by model.chat.state.collectAsState()
    Column(Modifier.verticalScroll(rememberScrollState())) {
        Heading(stringResource(R.string.settings))
        Column(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            SettingsSection(R.string.settings_interface) { InterfaceSettings() }
            SettingsSection(R.string.settings_account) {
                Text(profile.email, style = MaterialTheme.typography.titleMedium)
                Text(stringResource(R.string.cloud_library_hint), color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (cloud.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                cloud.message?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
                if (library.pending > 0) Text(stringResource(R.string.pending, library.pending))
                if (library.rejected > 0) {
                    Text(stringResource(R.string.rejected, library.rejected), color = MaterialTheme.colorScheme.error)
                }
                Button(onClick = model::refresh, enabled = !cloud.busy) { Text(stringResource(R.string.sync_now)) }
                TextButton(onClick = { signOut = true }, enabled = !cloud.busy) { Text(stringResource(R.string.sign_out)) }
            }
            SettingsSection(R.string.settings_notifications) { ReminderSettings(library) }
            SettingsSection(R.string.settings_calendar) {
                SettingsLink(R.drawable.ic_calendar, R.string.calendars, onClick = calendarSettings)
                CreationCalendarSetting(calendar, calendarRefresh)
            }
            SettingsSection(R.string.chat) {
                SettingsLink(R.drawable.ic_chat, R.string.chat_choose_model,
                    summary = chat.activeModelLabel?.let { stringResource(R.string.chat_current_model, it) }
                        ?: stringResource(R.string.chat_no_models), onClick = chatSettings)
            }
        }
    }
    if (signOut) {
        Confirm(R.string.sign_out, R.string.sign_out_hint, R.string.sign_out, { signOut = false }) {
            signOut = false
            model.logout(profile)
        }
    }
}

@Composable
private fun InterfaceSettings() {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var theme by remember { mutableStateOf(interfaceTheme(context)) }
    var language by remember { mutableStateOf(interfaceLanguage(context)) }
    LaunchedEffect(lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) { language = interfaceLanguage(context) }
    }
    val themeLabels = InterfaceTheme.entries.associateWith { stringResource(it.label) }
    val languageLabels = InterfaceLanguage.entries.associateWith { stringResource(it.label) }
    PreferencePicker(R.string.settings_theme, InterfaceTheme.entries, theme, themeLabels::getValue) {
        theme = it
        setInterfaceTheme(context, it)
    }
    PreferencePicker(R.string.settings_language, InterfaceLanguage.entries, language, languageLabels::getValue) {
        language = it
        setInterfaceLanguage(context, it)
    }
}

@Composable
private fun CreationCalendarSetting(calendar: DeviceCalendar, refresh: Int) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val writable by produceState(emptyList<PhoneCalendar>(), calendar, refresh, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            value = if (calendar.mayRead()) withContext(Dispatchers.IO) {
                runCatching { calendar.calendars().filter(PhoneCalendar::writable) }.getOrDefault(emptyList())
            } else emptyList()
        }
    }
    var preferred by remember(calendar) { mutableStateOf(calendar.preferredCreationCalendar()) }
    val selected = writable.firstOrNull { it.id == preferred }
    val automatic = stringResource(R.string.settings_calendar_automatic)
    PreferencePicker(
        R.string.settings_creation_calendar, listOf(null) + writable, selected, { it?.name ?: automatic },
        detail = { it?.account?.takeIf(String::isNotBlank) }, enabled = writable.isNotEmpty(),
    ) {
        preferred = it?.id
        calendar.setCreationCalendar(preferred)
    }
}

@Composable
private fun PreferenceRow(label: Int, value: String, enabled: Boolean = true, onClick: () -> Unit) {
    TextButton(onClick = onClick, enabled = enabled, modifier = Modifier.fillMaxWidth(),
        shape = RectangleShape, contentPadding = PaddingValues(vertical = 6.dp)) {
        Text(stringResource(label), Modifier.weight(1f).padding(end = 12.dp))
        Text(value, Modifier.weight(0.8f), textAlign = TextAlign.End,
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun <T> PreferencePicker(
    label: Int, choices: List<T>, selected: T, name: (T) -> String,
    detail: (T) -> String? = { null }, enabled: Boolean = true, choose: (T) -> Unit,
) {
    var choosing by rememberSaveable { mutableStateOf(false) }
    PreferenceRow(label, name(selected), enabled) { choosing = true }
    if (choosing && enabled) AlertDialog(
        onDismissRequest = { choosing = false }, title = { Text(stringResource(label)) },
        text = {
            Column(Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState()).selectableGroup()) {
                choices.forEach { option ->
                    Row(
                        Modifier.fillMaxWidth().selectable(option == selected, role = Role.RadioButton) {
                            choosing = false
                            if (option != selected) choose(option)
                        }.padding(vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        RadioButton(selected = option == selected, onClick = null)
                        Column {
                            Text(name(option))
                            detail(option)?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = { choosing = false }) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun SettingsSection(label: Int, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(stringResource(label), Modifier.padding(start = 4.dp).semantics { heading() },
            style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Surface(color = MaterialTheme.colorScheme.surfaceContainerLow, shape = MaterialTheme.shapes.large) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp), content = content)
        }
    }
}

@Composable
private fun SettingsLink(icon: Int, label: Int, summary: String? = null, onClick: () -> Unit) {
    TextButton(onClick = onClick, modifier = Modifier.fillMaxWidth(), contentPadding = PaddingValues(vertical = 8.dp)) {
        Glyph(icon, tint = MaterialTheme.colorScheme.primary)
        Column(Modifier.weight(1f).padding(start = 12.dp)) {
            Text(stringResource(label))
            summary?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}

@Composable
internal fun Folders(library: Library, model: PlannerModel, close: () -> Unit) {
    var action by rememberSaveable { mutableStateOf<String?>(null) }
    val dismiss = { action = null }
    when (val dialog = action) {
        "new" -> NameDialog(R.string.new_folder, R.string.folder_name, "", dismiss) { name ->
            model.folder(name, null, dismiss)
        }
        null -> AlertDialog(
            onDismissRequest = close,
            title = { Text(stringResource(R.string.manage_folders)) },
            text = {
                if (library.folders.isEmpty()) {
                    Text(stringResource(R.string.no_folders))
                } else {
                    FolderOrderEditor(
                        library.folders, { model.reorderFolders(library.workspace, it) },
                        rename = { action = "edit:$it" }, delete = { action = "delete:$it" },
                    )
                }
            },
            confirmButton = { TextButton(onClick = { action = "new" }) { Text(stringResource(R.string.new_folder)) } },
            dismissButton = { TextButton(onClick = close) { Text(stringResource(R.string.close)) } },
        )
        else -> {
            val folder = library.folders.firstOrNull { it.id == dialog.substringAfter(":") }
            if (folder == null) {
                androidx.compose.runtime.LaunchedEffect(dialog) { dismiss() }
            } else if (dialog.startsWith("edit:")) {
                NameDialog(R.string.rename_folder, R.string.folder_name, folder.text("name").orEmpty(), dismiss) {
                    model.folder(it, folder, dismiss)
                }
            } else {
                Confirm(R.string.delete_folder, R.string.delete_folder_hint, R.string.delete, dismiss) {
                    model.remove(folder, dismiss)
                }
            }
        }
    }
}

@Composable
private fun ReminderSettings(library: Library) {
    val context = LocalContext.current
    var enabled by remember { mutableStateOf(DeadlineReminders.enabled(context)) }
    var denied by remember { mutableStateOf(false) }
    var dateOnlyTime by remember { mutableStateOf(DeadlineReminders.dateOnlyTime(context)) }
    var choosingTime by rememberSaveable { mutableStateOf(false) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        denied = !granted
        enabled = granted
        DeadlineReminders.setEnabled(context, library, enabled)
    }
    val label = stringResource(R.string.deadline_notifications)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
        Switch(checked = enabled, onCheckedChange = { requested ->
            if (requested && !DeadlineReminders.permissionGranted(context)) {
                permission.launch(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                enabled = requested
                denied = false
                DeadlineReminders.setEnabled(context, library, enabled)
            }
        }, modifier = Modifier.semantics { contentDescription = label })
    }
    Text(stringResource(if (denied) R.string.notification_denied else R.string.notification_hint),
        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    PreferenceRow(R.string.settings_date_only_time, timeLabel(dateOnlyTime)) { choosingTime = true }
    if (choosingTime) PickTime(dateOnlyTime, { choosingTime = false }) { time ->
        dateOnlyTime = time
        DeadlineReminders.setDateOnlyTime(context, library, time)
        choosingTime = false
    }
}
