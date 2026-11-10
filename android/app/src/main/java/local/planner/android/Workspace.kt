package local.planner.android

import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.PrimaryScrollableTabRow
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.time.LocalDate
import java.time.ZoneId

private enum class Tab(val label: Int, val icon: Int) {
    Tasks(R.string.app_name, R.drawable.ic_list),
    Events(R.string.events, R.drawable.ic_calendar),
    Chat(R.string.chat, R.drawable.ic_chat),
    Settings(R.string.settings, R.drawable.ic_settings),
}

private const val NEW_TASK = "new"

@Composable
internal fun Workspace(library: Library, cloud: CloudState, model: PlannerModel, snackbar: SnackbarHostState) {
    var tab by rememberSaveable { mutableStateOf(Tab.Tasks) }
    var selectedSection by rememberSaveable { mutableStateOf("inbox") }
    var route by rememberSaveable { mutableStateOf<String?>(null) }
    var managing by rememberSaveable { mutableStateOf(false) }
    val tabStates = rememberSaveableStateHolder()
    val context = LocalContext.current
    val calendar = remember(library.workspace) { DeviceCalendar(context.applicationContext, library.workspace) }
    var calendarRefresh by remember { mutableIntStateOf(0) }
    var calendarDateText by rememberSaveable { mutableStateOf(LocalDate.now().toString()) }
    val calendarDate = LocalDate.parse(calendarDateText)
    var eventJson by rememberSaveable { mutableStateOf<String?>(null) }
    var calendarSettings by rememberSaveable { mutableStateOf(false) }
    var chatSettings by rememberSaveable { mutableStateOf(false) }
    val openEvent: (EventRequest) -> Unit = { eventJson = json.toJson(it) }
    val section = selectedSection.takeIf { it in Sections || library.folders.any { folder -> folder.id == it } } ?: "inbox"
    val task = library.tasks.firstOrNull { it.id == route }

    val eventRoute = eventJson
    if (eventRoute != null) {
        val request = remember(eventRoute) { json.fromJson(eventRoute, EventRequest::class.java) }
        EventEditor(request, calendar, { eventJson = null }) { eventJson = null; calendarRefresh++ }
    } else if (route != null) {
        if (route == NEW_TASK || task != null) {
            TaskEditor(library, task, section, model, snackbar) { route = null }
        } else {
            MissingTask(snackbar) { model.closeDraft(); route = null }
        }
    } else {
        Scaffold(
            snackbarHost = { SnackbarHost(snackbar) },
            bottomBar = {
                NavigationBar {
                    Tab.entries.forEach { entry ->
                        NavigationBarItem(
                            selected = tab == entry, onClick = { tab = entry },
                            icon = { Glyph(entry.icon) }, label = { Text(stringResource(entry.label)) },
                        )
                    }
                }
            },
            floatingActionButton = {
                when (tab) {
                    Tab.Tasks -> ExtendedFloatingActionButton(
                        onClick = { route = NEW_TASK }, icon = { Glyph(R.drawable.ic_add) },
                        text = { Text(stringResource(R.string.new_task)) },
                    )
                    Tab.Events -> ExtendedFloatingActionButton(
                        onClick = {
                            val start = calendarDate.takeUnless { it == LocalDate.now() }
                                ?.atTime(9, 0)?.atZone(ZoneId.systemDefault())?.toInstant()?.toEpochMilli()
                            openEvent(EventRequest(suggestedStart = start))
                        }, icon = { Glyph(R.drawable.ic_add) },
                        text = { Text(stringResource(R.string.new_event)) },
                    )
                    else -> Unit
                }
            },
        ) { padding ->
            Box(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding), contentAlignment = Alignment.TopCenter) {
                Column(Modifier.widthIn(max = 720.dp).fillMaxWidth().fillMaxHeight()) {
                    tabStates.SaveableStateProvider(tab.name) {
                        when (tab) {
                            Tab.Tasks -> TaskList(library, section, { selectedSection = it }, { managing = true }, { route = it }, model)
                            Tab.Events -> CalendarScreen(calendar, calendarDate, { calendarDateText = it.toString() },
                                openEvent, { calendarSettings = true }, calendarRefresh)
                            Tab.Chat -> ChatScreen(library, model) { chatSettings = true }
                            Tab.Settings -> Settings(library, cloud, model, calendar, calendarRefresh,
                                { calendarSettings = true }, { chatSettings = true })
                        }
                    }
                }
            }
        }
        if (managing) Folders(library, model) { managing = false }
    }
    if (calendarSettings) CalendarChooser(calendar) { calendarSettings = false; calendarRefresh++ }
    if (chatSettings) ChatConnectionDialog(model.chat) { chatSettings = false }
}

private val Sections = linkedMapOf(
    "today" to R.string.today, "inbox" to R.string.inbox, "week" to R.string.week,
    "month" to R.string.month, "all" to R.string.all_tasks,
)

@Composable
internal fun sectionName(section: String, library: Library): String =
    Sections[section]?.let { stringResource(it) }
        ?: library.folders.firstOrNull { it.id == section }?.text("name")
        ?: stringResource(R.string.inbox)

@Composable
private fun TaskList(
    library: Library, section: String, select: (String) -> Unit, manage: () -> Unit, open: (String) -> Unit,
    model: PlannerModel,
) {
    var searching by rememberSaveable { mutableStateOf(false) }
    var search by rememberSaveable(section) { mutableStateOf("") }
    var showCompleted by rememberSaveable(section) { mutableStateOf(false) }
    val tasks = library.tasks.filter { task ->
        task.inSection(section, library) && (
            search.isBlank() || task.text("title").orEmpty().contains(search.trim(), ignoreCase = true) ||
                task.text("description").orEmpty().contains(search.trim(), ignoreCase = true)
        )
    }
    val (done, active) = tasks.partition(Entity::completed)
    Heading(sectionName(section, library)) {
        ActionIcon(if (searching) R.drawable.ic_close else R.drawable.ic_search,
            if (searching) R.string.close_search else R.string.search) {
            searching = !searching
            if (!searching) search = ""
        }
        ActionIcon(R.drawable.ic_folder, R.string.manage_folders, onClick = manage)
    }
    val sections = Sections.keys + library.folders.map(Entity::id)
    PrimaryScrollableTabRow(
        selectedTabIndex = sections.indexOf(section).coerceAtLeast(0), edgePadding = 6.dp, minTabWidth = 0.dp,
        indicator = {},
    ) {
        sections.forEachIndexed { index, key ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (index == Sections.size) {
                    Box(Modifier.width(8.dp), contentAlignment = Alignment.Center) {
                        VerticalDivider(Modifier.height(18.dp))
                    }
                }
                val selected = key == section
                Box(
                    Modifier.selectable(selected, role = Role.Tab, onClick = { select(key) })
                        .padding(horizontal = 14.dp).heightIn(min = 48.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        sectionName(key, library), Modifier.widthIn(max = 184.dp).padding(vertical = 8.dp),
                        color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelLarge,
                    )
                    if (selected) {
                        Box(Modifier.matchParentSize(), contentAlignment = Alignment.BottomCenter) {
                            Spacer(Modifier.fillMaxWidth().height(3.dp).background(MaterialTheme.colorScheme.primary, CircleShape))
                        }
                    }
                }
            }
        }
    }
    if (searching) {
        PlannerTextField(
            value = search, onValueChange = { search = it }, singleLine = true,
            placeholder = R.string.search,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 6.dp),
        )
    }
    LazyColumn(
        contentPadding = PaddingValues(start = 20.dp, top = 16.dp, end = 20.dp, bottom = 92.dp),
    ) {
        if (tasks.isEmpty()) {
            item {
                EmptyPanel(
                    if (search.isBlank()) R.drawable.ic_list else R.drawable.ic_search,
                    if (search.isBlank()) R.string.no_tasks else R.string.no_results,
                    if (search.isBlank()) R.string.no_tasks_hint else R.string.no_results_hint,
                )
            }
        } else {
            if (active.isNotEmpty()) {
                taskRows(active, library, open, model)
            } else if (done.isNotEmpty() && search.isBlank()) {
                item { EmptyPanel(R.drawable.ic_task_done, R.string.all_completed, R.string.all_completed_hint) }
            }
            if (done.isNotEmpty()) {
                if (active.isNotEmpty() || search.isBlank()) item { Spacer(Modifier.height(10.dp)) }
                item(key = "completed-header") {
                    val expandedState = stringResource(if (showCompleted) R.string.completed_expanded else R.string.completed_collapsed)
                    Surface(
                        color = MaterialTheme.colorScheme.surfaceContainerLow,
                        shape = groupShape(first = true, last = !showCompleted),
                    ) {
                        Row(
                            Modifier.fillMaxWidth().semantics { stateDescription = expandedState }
                                .clickable(role = Role.Button) { showCompleted = !showCompleted }
                                .padding(horizontal = 16.dp, vertical = 14.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(stringResource(R.string.completed_group, done.size), Modifier.weight(1f),
                                style = MaterialTheme.typography.titleMedium)
                            Glyph(if (showCompleted) R.drawable.ic_chevron_up else R.drawable.ic_chevron_down)
                        }
                    }
                }
                if (showCompleted) taskRows(done, library, open, model, firstRounded = false)
            }
        }
    }
}

private fun LazyListScope.taskRows(
    entries: List<Entity>, library: Library, open: (String) -> Unit, model: PlannerModel, firstRounded: Boolean = true,
) {
    itemsIndexed(entries, key = { _, task -> task.id }) { index, task ->
        val last = index == entries.lastIndex
        TaskRow(task, library, open, model, firstRounded && index == 0, last)
    }
}

private fun groupShape(first: Boolean, last: Boolean) = RoundedCornerShape(
    topStart = if (first) 20.dp else 0.dp, topEnd = if (first) 20.dp else 0.dp,
    bottomStart = if (last) 20.dp else 0.dp, bottomEnd = if (last) 20.dp else 0.dp,
)

@Composable
private fun TaskRow(
    task: Entity, library: Library, open: (String) -> Unit, model: PlannerModel, first: Boolean, last: Boolean,
) {
    val checklist = library.items(task.id)
    val completedLabel = stringResource(if (task.completed) R.string.completed else R.string.open_task_state)
    val actionLabel = stringResource(if (task.completed) R.string.reopen_task else R.string.complete_task)
    val deadline = task.deadline
    val overdue = deadline != null && !task.completed && (
        deadline.instant?.isBefore(java.time.Instant.now()) ?: deadline.date.isBefore(LocalDate.now(deadline.zone))
    )
    Surface(color = MaterialTheme.colorScheme.surfaceContainerLow, shape = groupShape(first, last)) {
        Column {
            Row(
                Modifier.fillMaxWidth().padding(vertical = 3.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Box(
                    Modifier.size(48.dp).clip(CircleShape)
                        .toggleable(task.completed, role = Role.Checkbox, onValueChange = { model.toggleCompletion(task) })
                        .semantics { stateDescription = completedLabel; contentDescription = actionLabel },
                    contentAlignment = Alignment.Center,
                ) {
                    Glyph(if (task.completed) R.drawable.ic_task_done else R.drawable.ic_task_open,
                        tint = if (task.completed) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Column(
                    Modifier.weight(1f).clip(RoundedCornerShape(8.dp)).clickable { open(task.id) }.padding(vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        task.text("title").orEmpty().ifBlank { stringResource(R.string.untitled) },
                        style = MaterialTheme.typography.titleMedium,
                        textDecoration = if (task.completed) TextDecoration.LineThrough else null,
                        maxLines = 3, overflow = TextOverflow.Ellipsis,
                    )
                    task.text("description")?.trim()?.takeIf(String::isNotEmpty)?.let { description ->
                        Text(description, style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                    if (deadline != null || checklist.isNotEmpty()) {
                        val parts = buildList {
                            if (deadline != null) add(deadlineLabel(deadline))
                            if (checklist.isNotEmpty()) {
                                add(stringResource(R.string.checklist_count, checklist.count { it.flag("isCompleted") }, checklist.size))
                            }
                        }
                        Text(
                            parts.joinToString(" · "), style = MaterialTheme.typography.bodySmall,
                            color = if (overdue) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                ActionIcon(
                    if (task.focused) R.drawable.ic_star else R.drawable.ic_star_outline,
                    if (task.focused) R.string.unstar else R.string.star,
                    tint = if (task.focused) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                ) { model.toggleFocus(task) }
            }
            if (!last) HorizontalDivider(Modifier.padding(start = 48.dp, end = 12.dp),
                color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
        }
    }
}

@Composable
internal fun Heading(title: String, actions: @Composable () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp, top = 18.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.SemiBold,
            maxLines = 2, overflow = TextOverflow.Ellipsis)
        actions()
    }
}

@Composable
internal fun SectionLabel(text: String) {
    Text(text, Modifier.padding(start = 4.dp, top = 6.dp, bottom = 3.dp),
        style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
internal fun EmptyPanel(
    @DrawableRes icon: Int, title: Int, hint: Int,
    header: @Composable () -> Unit = {},
    footer: @Composable () -> Unit = {},
) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(MaterialTheme.colorScheme.surfaceContainerLow)
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        header()
        Box(Modifier.size(48.dp).background(MaterialTheme.colorScheme.primaryContainer, CircleShape),
            contentAlignment = Alignment.Center) {
            Glyph(icon, tint = MaterialTheme.colorScheme.onPrimaryContainer)
        }
        Text(stringResource(title), style = MaterialTheme.typography.titleLarge)
        Text(stringResource(hint), style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        footer()
    }
}

@Composable
internal fun Glyph(@DrawableRes id: Int, description: String? = null, tint: Color = MaterialTheme.colorScheme.onSurface) {
    Icon(painterResource(id), description, Modifier.size(24.dp), tint = tint)
}

@Composable
internal fun ActionIcon(
    @DrawableRes id: Int, label: Int,
    tint: Color = MaterialTheme.colorScheme.onSurface, enabled: Boolean = true, onClick: () -> Unit,
) {
    IconButton(onClick = onClick, enabled = enabled) { Glyph(id, stringResource(label), tint) }
}

@Composable
internal fun deadlineLabel(deadline: Deadline): String {
    val date = dateLabel(deadline.agendaDate())
    val time = deadline.instant?.atZone(ZoneId.systemDefault())?.toLocalTime()
        ?.let { timeLabel(it) }
    return if (time == null) date else "$date · $time"
}
