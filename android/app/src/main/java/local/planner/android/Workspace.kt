package local.planner.android

import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

private enum class Tab(val label: Int, val icon: Int) {
    Tasks(R.string.app_name, R.drawable.ic_list),
    Agenda(R.string.agenda, R.drawable.ic_calendar),
    Settings(R.string.settings, R.drawable.ic_settings),
}

private const val NEW_TASK = "new"

@Composable
internal fun Workspace(library: Library, cloud: CloudState, model: PlannerModel, snackbar: SnackbarHostState) {
    var tab by rememberSaveable { mutableStateOf(Tab.Tasks) }
    var selectedSection by rememberSaveable { mutableStateOf("inbox") }
    var route by rememberSaveable { mutableStateOf<String?>(null) }
    var managing by rememberSaveable { mutableStateOf(false) }
    val section = selectedSection.takeIf { it in Sections || library.folders.any { folder -> folder.id == it } } ?: "inbox"
    val task = library.tasks.firstOrNull { it.id == route }

    if (route != null) {
        if (route == NEW_TASK || task != null) {
            TaskEditor(library, task, section, model, snackbar) { route = null }
        } else {
            MissingTask(snackbar) { model.closeDraft(); route = null }
        }
        return
    }

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
            if (tab == Tab.Tasks) {
                ExtendedFloatingActionButton(
                    onClick = { route = NEW_TASK }, icon = { Glyph(R.drawable.ic_add) },
                    text = { Text(stringResource(R.string.new_task)) },
                )
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 720.dp).fillMaxWidth().fillMaxHeight()) {
                when (tab) {
                    Tab.Tasks -> TaskList(library, section, { selectedSection = it }, { managing = true }, { route = it }, model)
                    Tab.Agenda -> Agenda(library, { route = it }, model)
                    Tab.Settings -> Settings(library, cloud, model)
                }
            }
        }
    }
    if (managing) Folders(library, model) { managing = false }
}

private val Sections = linkedMapOf(
    "inbox" to R.string.inbox, "today" to R.string.today, "week" to R.string.week,
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
    Heading(stringResource(R.string.app_name), sectionName(section, library)) {
        ActionIcon(if (searching) R.drawable.ic_close else R.drawable.ic_search,
            if (searching) R.string.close_search else R.string.search) {
            searching = !searching
            if (!searching) search = ""
        }
        ActionIcon(R.drawable.ic_folder, R.string.manage_folders, onClick = manage)
    }
    Row(
        Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 20.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        (Sections.keys + library.folders.map(Entity::id)).forEach { key ->
            FilterChip(
                selected = key == section, onClick = { select(key) },
                label = { Text(sectionName(key, library), maxLines = 1, overflow = TextOverflow.Ellipsis) },
                modifier = Modifier.widthIn(max = 200.dp),
            )
        }
    }
    if (searching) {
        OutlinedTextField(
            value = search, onValueChange = { search = it }, singleLine = true,
            label = { Text(stringResource(R.string.search)) },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 6.dp),
        )
    }
    LazyColumn(
        contentPadding = PaddingValues(start = 20.dp, top = 16.dp, end = 20.dp, bottom = 92.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
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
                item { SectionLabel(stringResource(R.string.active_count, active.size)) }
                items(active, key = Entity::id) { task -> TaskRow(task, library, open, model) }
            }
            if (done.isNotEmpty()) {
                item {
                    TextButton(onClick = { showCompleted = !showCompleted }) {
                        Text(stringResource(if (showCompleted) R.string.hide_completed else R.string.show_completed, done.size))
                    }
                }
                if (showCompleted) items(done, key = Entity::id) { task -> TaskRow(task, library, open, model) }
            }
        }
    }
}

@Composable
private fun Agenda(library: Library, open: (String) -> Unit, model: PlannerModel) {
    val dates = library.tasks.filter { it.deadline != null && !it.completed }
        .groupBy { requireNotNull(it.deadline).agendaDate() }.toSortedMap()
    Heading(stringResource(R.string.agenda), stringResource(R.string.agenda_title))
    LazyColumn(
        contentPadding = PaddingValues(start = 20.dp, top = 14.dp, end = 20.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (dates.isEmpty()) item { EmptyPanel(R.drawable.ic_calendar, R.string.no_deadlines, R.string.no_deadlines_hint) }
        dates.forEach { (date, tasks) ->
            item(key = date.toString()) {
                val label = date.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.FULL))
                val today = LocalDate.now()
                SectionLabel(
                    when {
                        date.isBefore(today) -> stringResource(R.string.overdue_date, label)
                        date == today -> stringResource(R.string.today_date, label)
                        else -> label
                    },
                )
            }
            items(tasks.sortedBy { it.deadline?.instant }, key = Entity::id) { task -> TaskRow(task, library, open, model) }
        }
    }
}

@Composable
private fun TaskRow(task: Entity, library: Library, open: (String) -> Unit, model: PlannerModel) {
    val checklist = library.items(task.id)
    val completedLabel = stringResource(if (task.completed) R.string.completed else R.string.open_task_state)
    val actionLabel = stringResource(if (task.completed) R.string.reopen_task else R.string.complete_task)
    val deadline = task.deadline
    val overdue = deadline != null && !task.completed && (
        deadline.instant?.isBefore(java.time.Instant.now()) ?: deadline.date.isBefore(LocalDate.now(deadline.zone))
    )
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        shape = RoundedCornerShape(18.dp),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(vertical = 6.dp, horizontal = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Checkbox(
                checked = task.completed, onCheckedChange = { model.toggleCompletion(task) },
                modifier = Modifier.semantics {
                    stateDescription = completedLabel
                    this.contentDescription = actionLabel
                },
            )
            Column(
                Modifier.weight(1f).clip(RoundedCornerShape(8.dp)).clickable { open(task.id) }.padding(vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    task.text("title").orEmpty().ifBlank { stringResource(R.string.untitled) },
                    style = MaterialTheme.typography.titleMedium,
                    textDecoration = if (task.completed) TextDecoration.LineThrough else null,
                    maxLines = 2, overflow = TextOverflow.Ellipsis,
                )
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
    }
}

@Composable
internal fun Heading(kicker: String, title: String, actions: @Composable () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp, top = 18.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(kicker, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            Text(title, style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.SemiBold,
                maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        actions()
    }
}

@Composable
internal fun SectionLabel(text: String) {
    Text(text, Modifier.padding(start = 4.dp, top = 6.dp, bottom = 3.dp),
        style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
internal fun EmptyPanel(@DrawableRes icon: Int, title: Int, hint: Int) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(MaterialTheme.colorScheme.surfaceContainerLow)
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Box(Modifier.size(48.dp).background(MaterialTheme.colorScheme.primaryContainer, CircleShape),
            contentAlignment = Alignment.Center) {
            Glyph(icon, tint = MaterialTheme.colorScheme.onPrimaryContainer)
        }
        Text(stringResource(title), style = MaterialTheme.typography.titleLarge)
        Text(stringResource(hint), style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
internal fun Glyph(@DrawableRes id: Int, description: String? = null, tint: Color = MaterialTheme.colorScheme.onSurface) {
    Icon(painterResource(id), description, Modifier.size(24.dp), tint = tint)
}

@Composable
internal fun ActionIcon(
    @DrawableRes id: Int, label: Int,
    tint: Color = MaterialTheme.colorScheme.onSurface, onClick: () -> Unit,
) {
    IconButton(onClick = onClick) { Glyph(id, stringResource(label), tint) }
}

internal fun deadlineLabel(deadline: Deadline): String {
    val date = deadline.agendaDate().format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))
    val time = deadline.instant?.atZone(ZoneId.systemDefault())?.toLocalTime()
        ?.format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT))
    return if (time == null) date else "$date · $time"
}
