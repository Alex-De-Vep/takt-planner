package local.planner.android

import android.Manifest
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.FormatStyle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private data class CalendarPage(
    val calendars: List<PhoneCalendar>, val events: List<PhoneEvent>,
)

@Composable
internal fun CalendarScreen(
    calendar: DeviceCalendar, date: LocalDate, selectDate: (LocalDate) -> Unit,
    open: (EventRequest) -> Unit, filters: () -> Unit, refresh: Int,
) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val zone = ZoneId.systemDefault()
    var datePicker by rememberSaveable { mutableStateOf(false) }
    var revision by remember { mutableIntStateOf(0) }
    var canRead by remember { mutableStateOf(calendar.mayRead()) }
    val requestRead = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        canRead = calendar.mayRead()
        revision++
    }
    DisposableEffect(lifecycle, calendar) {
        val watcher = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                canRead = calendar.mayRead()
                revision++
            }
        }
        lifecycle.addObserver(watcher)
        onDispose { lifecycle.removeObserver(watcher) }
    }
    DisposableEffect(canRead, calendar) {
        val resolver = context.contentResolver
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) { revision++ }
        }
        val registered = canRead && runCatching {
            resolver.registerContentObserver(CalendarContract.CONTENT_URI, true, observer)
        }.isSuccess
        onDispose { if (registered) resolver.unregisterContentObserver(observer) }
    }
    val page by produceState<Result<CalendarPage>?>(null, date, canRead, revision, refresh, zone) {
        value = if (canRead) withContext(Dispatchers.IO) {
            runCatching {
                val calendars = calendar.calendars()
                val selected = calendar.selection(calendars)
                CalendarPage(calendars, calendar.events(date, date.plusDays(7), zone, selected))
            }
        } else null
    }

    Heading(stringResource(R.string.events)) {
        ActionIcon(R.drawable.ic_settings, R.string.calendars, onClick = filters)
    }
    if (!canRead) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            EmptyPanel(R.drawable.ic_calendar, R.string.connect_calendar, R.string.calendar_read_hint)
            Button(onClick = { requestRead.launch(Manifest.permission.READ_CALENDAR) }) {
                Text(stringResource(R.string.connect_calendar))
            }
        }
        return
    }
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween) {
        TextButton(onClick = { selectDate(date.minusDays(7)) }) { Text(stringResource(R.string.previous_week)) }
        FilledTonalButton(onClick = { datePicker = true }) { Text(dateLabel(date)) }
        TextButton(onClick = { selectDate(date.plusDays(7)) }) { Text(stringResource(R.string.next_week)) }
    }
    if (datePicker) PickDate(date, { datePicker = false }) { selectDate(it); datePicker = false }
    val loaded = page
    if (loaded?.isFailure == true) {
        Column(Modifier.padding(20.dp)) {
            Text(stringResource(R.string.calendar_read_error))
            TextButton(onClick = { revision++ }) { Text(stringResource(R.string.retry)) }
        }
    }
    val data = loaded?.getOrNull()
    if (data != null) {
        LazyColumn(contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 88.dp)) {
            val days = (0L..6L).map(date::plusDays)
            val hasEvents = days.any { day -> data.events.any { it.occursOn(day, zone) } }
            if (!hasEvents) item {
                EmptyPanel(R.drawable.ic_calendar, R.string.no_events, R.string.no_events_hint)
            }
            days.forEach { day ->
                val entries = data.events.filter { it.occursOn(day, zone) }
                    .sortedWith(compareBy({ !it.allDay }, { it.start }))
                if (entries.isNotEmpty()) item(key = day.toString()) {
                    SectionLabel(dateLabel(day, FormatStyle.FULL))
                    entries.forEach { entry ->
                        Row(Modifier.fillMaxWidth().clickable { open(EventRequest(event = entry)) }
                            .padding(vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text(
                                if (entry.allDay) stringResource(R.string.all_day)
                                else timeLabel(entry.startsIn(zone).toLocalTime()),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.primary,
                            )
                            Column(Modifier.weight(1f)) {
                                Text(entry.title.ifBlank { stringResource(R.string.untitled_event) },
                                    style = MaterialTheme.typography.titleMedium)
                                data.calendars.firstOrNull { it.id == entry.calendarId }?.let {
                                    Text(it.name, style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    }
                }
            }
        }
    }
}

@Composable
internal fun CalendarChooser(calendar: DeviceCalendar, done: () -> Unit) {
    var canRead by remember { mutableStateOf(calendar.mayRead()) }
    val request = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        canRead = calendar.mayRead()
    }
    val calendars by produceState(emptyList<PhoneCalendar>(), canRead) {
        value = if (canRead) withContext(Dispatchers.IO) { runCatching { calendar.calendars() }.getOrDefault(emptyList()) }
            else emptyList()
    }
    var selected by remember(calendars) { mutableStateOf(calendar.selection(calendars)) }
    AlertDialog(
        onDismissRequest = done, title = { Text(stringResource(R.string.calendars)) },
        text = {
            Column(Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState())) {
                if (!canRead) {
                    Text(stringResource(R.string.calendar_read_hint))
                    TextButton(onClick = { request.launch(Manifest.permission.READ_CALENDAR) }) {
                        Text(stringResource(R.string.connect_calendar))
                    }
                } else if (calendars.isEmpty()) {
                    Text(stringResource(R.string.no_calendars))
                }
                calendars.forEach { item ->
                    val toggle = { selected = if (item.id in selected) selected - item.id else selected + item.id }
                    Row(Modifier.fillMaxWidth().clickable(onClick = toggle), verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(item.id in selected, onCheckedChange = { toggle() })
                        Column {
                            Text(item.name)
                            if (item.account.isNotBlank()) Text(item.account, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { calendar.select(selected); done() }, enabled = calendars.isNotEmpty()) {
                Text(stringResource(R.string.save))
            }
        },
        dismissButton = { TextButton(onClick = done) { Text(stringResource(R.string.close)) } },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun EventEditor(request: EventRequest, calendar: DeviceCalendar, dismiss: () -> Unit, saved: () -> Unit) {
    val original = request.event
    val readOnly = original != null && !original.editable
    val zone = original?.zoneId?.let { runCatching { ZoneId.of(it) }.getOrNull() } ?: ZoneId.systemDefault()
    val proposed = request.suggestedStart?.let { Instant.ofEpochMilli(it).atZone(zone).toLocalDateTime() }
        ?: LocalDateTime.now(zone).withSecond(0).withNano(0).plusHours(1).withMinute(0)
    var title by rememberSaveable { mutableStateOf(original?.title.orEmpty()) }
    var description by rememberSaveable { mutableStateOf(original?.description.orEmpty()) }
    var location by rememberSaveable { mutableStateOf(original?.location.orEmpty()) }
    var allDay by rememberSaveable { mutableStateOf(original?.allDay ?: false) }
    var startText by rememberSaveable { mutableStateOf((original?.startsIn(zone) ?: proposed).toString()) }
    var endText by rememberSaveable {
        val end = original?.endsIn(zone) ?: proposed.plusHours(1)
        mutableStateOf((if (original?.allDay == true) end.minusDays(1) else end).toString())
    }
    val start = LocalDateTime.parse(startText)
    val end = LocalDateTime.parse(endText)
    var selected by rememberSaveable { mutableStateOf(original?.calendarId) }
    var menu by remember { mutableStateOf(false) }
    var picker by rememberSaveable { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by rememberSaveable { mutableStateOf<Int?>(null) }
    var canRead by remember { mutableStateOf(calendar.mayRead()) }
    val requestRead = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        canRead = calendar.mayRead()
    }
    val calendars by produceState(emptyList<PhoneCalendar>(), canRead) {
        value = if (canRead) withContext(Dispatchers.IO) { runCatching { calendar.calendars() }.getOrDefault(emptyList()) }
            else emptyList()
    }
    val writable = calendars.filter(PhoneCalendar::writable)
    val destination = calendars.firstOrNull { it.id == selected }
        ?: if (original == null) calendar.creationCalendar(writable) else null
    val scope = rememberCoroutineScope()
    val save = save@{
        if (busy || destination == null) return@save
        val startMillis = if (allDay) eventTime(start.toLocalDate().atStartOfDay(), ZoneOffset.UTC)
            else eventTime(start, zone, original?.start?.takeUnless { original.allDay })
        val endMillis = if (allDay) eventTime(end.toLocalDate().plusDays(1).atStartOfDay(), ZoneOffset.UTC)
            else eventTime(end, zone, original?.end?.takeUnless { original.allDay })
        if (startMillis == null || endMillis == null || endMillis <= startMillis) {
            error = R.string.event_time_error
            return@save
        }
        busy = true
        error = null
        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    calendar.save(original, EventValues(destination.id, title.trim(), description, location,
                        startMillis, endMillis, if (allDay) "UTC" else zone.id, allDay))
                }
                saved()
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                error = if (failure is StaleCalendarEvent) R.string.event_stale else R.string.calendar_write_error
            } finally {
                busy = false
            }
        }
    }
    val requestWrite = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        if (it) save() else error = R.string.calendar_write_permission
    }
    val navigateBack = { if (!busy) dismiss() }
    BackHandler(onBack = navigateBack)
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(when {
                    readOnly -> R.string.event_details
                    original != null -> R.string.edit_event
                    else -> R.string.new_event
                })) },
                navigationIcon = { ActionIcon(R.drawable.ic_back, R.string.back, enabled = !busy, onClick = navigateBack) },
            )
        },
        bottomBar = {
            if (!readOnly) EditorBottomAction(
                R.string.save, enabled = title.isNotBlank() && destination?.writable == true && !busy,
            ) {
                if (calendar.mayWrite()) save() else requestWrite.launch(Manifest.permission.WRITE_CALENDAR)
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.TopCenter) {
            Column(
                Modifier.widthIn(max = 720.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (!canRead) {
                    Text(stringResource(R.string.calendar_read_hint))
                    TextButton(onClick = { requestRead.launch(Manifest.permission.READ_CALENDAR) }) {
                        Text(stringResource(R.string.connect_calendar))
                    }
                } else if (!readOnly && destination?.writable != true) {
                    Text(stringResource(R.string.no_writable_calendar))
                }
                OutlinedTextField(title, { title = it }, Modifier.fillMaxWidth().focusNewTitle(original == null),
                    label = { Text(stringResource(R.string.event_title)) },
                    singleLine = true, enabled = !busy, readOnly = readOnly)
                Box {
                    TextButton(onClick = { menu = true }, enabled = !busy && original == null && writable.isNotEmpty()) {
                        Text(destination?.name ?: stringResource(R.string.calendars))
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        writable.forEach {
                            DropdownMenuItem(text = { Text(it.name) }, onClick = { selected = it.id; menu = false })
                        }
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(allDay, {
                        allDay = it
                        if (it && end.toLocalTime() == java.time.LocalTime.MIDNIGHT && end.toLocalDate() > start.toLocalDate()) {
                            endText = end.minusDays(1).toString()
                        } else if (!it && end <= start) {
                            endText = start.plusHours(1).toString()
                        }
                    }, enabled = !readOnly && !busy)
                    Text(stringResource(R.string.all_day))
                }
                EventDateTime(R.string.event_start, start, allDay, readOnly, !busy) { picker = "start$it" }
                EventDateTime(R.string.event_end, end, allDay, readOnly, !busy) { picker = "end$it" }
                OutlinedTextField(location, { location = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.event_location)) },
                    enabled = !busy, readOnly = readOnly)
                OutlinedTextField(description, { description = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.description)) },
                    enabled = !busy, readOnly = readOnly, minLines = 3)
                error?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
            }
        }
    }
    picker?.let { field ->
        val isStart = field.startsWith("start")
        val current = if (isStart) start else end
        val close = { picker = null }
        val choose = { time: LocalDateTime ->
            if (isStart) {
                startText = time.toString()
                if (end <= time) endText = (if (allDay) time else time.plusHours(1)).toString()
            } else endText = time.toString()
            close()
        }
        if (field.endsWith("date")) PickDate(current.toLocalDate(), close) { choose(current.with(it)) }
        else PickTime(current.toLocalTime(), close) { choose(current.with(it)) }
    }
}

@Composable
private fun EventDateTime(
    label: Int, dateTime: LocalDateTime, allDay: Boolean, readOnly: Boolean, enabled: Boolean, pick: (String) -> Unit,
) {
    val date = dateLabel(dateTime.toLocalDate())
    val time = if (allDay) null else timeLabel(dateTime.toLocalTime())
    Column {
        Text(stringResource(label), style = MaterialTheme.typography.labelLarge)
        if (readOnly) {
            Text(if (time == null) date else "$date · $time")
        } else {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { pick("date") }, enabled = enabled) { Text(date) }
                if (time != null) OutlinedButton(onClick = { pick("time") }, enabled = enabled) { Text(time) }
            }
        }
    }
}
