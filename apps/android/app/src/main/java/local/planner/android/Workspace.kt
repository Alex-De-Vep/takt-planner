package local.planner.android

import android.os.SystemClock
import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
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
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.PrimaryScrollableTabRow
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.hideFromAccessibility
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch

private enum class Tab(val label: Int, val icon: Int, val accent: WorkspaceAccent) {
    Tasks(R.string.tasks, R.drawable.ic_list, WorkspaceAccent.Tasks),
    Notes(R.string.notes, R.drawable.ic_note, WorkspaceAccent.Notes),
    Events(R.string.events, R.drawable.ic_calendar, WorkspaceAccent.Events),
    Chat(R.string.chat, R.drawable.ic_assistant, WorkspaceAccent.Chat),
    Settings(R.string.settings, R.drawable.ic_settings, WorkspaceAccent.Settings),
}

private const val NEW_TASK = "new"

@Composable
internal fun Workspace(library: Library, cloud: CloudState, model: PlannerModel, snackbar: SnackbarHostState) {
    var tab by rememberSaveable { mutableStateOf(Tab.Tasks) }
    val sectionColors = tab.accent.colors()
    var selectedSection by rememberSaveable { mutableStateOf("inbox") }
    var selectedNoteFolder by rememberSaveable { mutableStateOf<String?>(null) }
    var noteTrash by rememberSaveable { mutableStateOf(false) }
    val notes by model.notes.collectAsState()
    val noteState = notes.takeIf { it.workspace == library.workspace } ?: NotesState()
    val syncStatus: @Composable () -> Unit = { SyncStatus(library, noteState, cloud, model::retrySync) }
    val noteFolder = selectedNoteFolder?.takeIf { id -> library.folders.any { it.id == id } }
    var route by rememberSaveable { mutableStateOf<String?>(null) }
    var newTaskSection by rememberSaveable { mutableStateOf("inbox") }
    var creationMenuOpen by rememberSaveable { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var managing by rememberSaveable { mutableStateOf(false) }
    val tabStates = rememberSaveableStateHolder()
    val context = LocalContext.current
    val taskMissing = stringResource(R.string.task_missing)
    val calendar = remember(library.workspace) { DeviceCalendar(context.applicationContext, library.workspace) }
    var calendarRefresh by remember { mutableIntStateOf(0) }
    var calendarDateText by rememberSaveable { mutableStateOf(LocalDate.now().toString()) }
    val calendarDate = LocalDate.parse(calendarDateText)
    var eventJson by rememberSaveable { mutableStateOf<String?>(null) }
    var calendarSettings by rememberSaveable { mutableStateOf(false) }
    var chatSettings by rememberSaveable { mutableStateOf(false) }
    var chooseChatModel by rememberSaveable { mutableStateOf(false) }
    val openEvent: (EventRequest) -> Unit = { eventJson = json.toJson(it) }
    val section = selectedSection.takeIf { it in Sections || library.folders.any { folder -> folder.id == it } } ?: "inbox"
    val task = library.tasks.firstOrNull { it.id == route }

    val showCreation = tab == Tab.Tasks || tab == Tab.Events || tab == Tab.Notes && !noteTrash
    val activeFolder = when (tab) {
        Tab.Tasks -> section.takeUnless { it in Sections }
        Tab.Notes -> noteFolder
        else -> null
    }
    val create = { action: CreationAction ->
        creationMenuOpen = false
        when (action) {
            CreationAction.Task -> {
                newTaskSection = if (tab == Tab.Tasks) section else activeFolder ?: "inbox"
                route = NEW_TASK
            }
            CreationAction.Note -> model.openNote(null, activeFolder)
            CreationAction.Event -> {
                val start = calendarDate.takeIf { tab == Tab.Events && it != LocalDate.now() }
                    ?.atTime(9, 0)?.atZone(ZoneId.systemDefault())?.toInstant()?.toEpochMilli()
                openEvent(EventRequest(suggestedStart = start))
            }
            CreationAction.Recording -> model.openNote(null, activeFolder, recordOnOpen = true)
        }
    }

    val noteDraft = model.noteDraft?.takeIf { it.workspace == library.workspace }
    val eventRoute = eventJson
    if (noteDraft != null) {
        key(noteDraft.id) {
            MaterialTheme(colorScheme = WorkspaceAccent.Notes.colors()) {
                NoteEditor(
                    noteDraft, library, noteState.limit != null, noteState.formatVersion >= NOTE_FORMAT_VERSION, model, snackbar,
                ) { id ->
                    model.chat.setAttachment(ChatAttachment(noteId = id))
                    tab = Tab.Chat
                }
            }
        }
    } else if (eventRoute != null) {
        val request = remember(eventRoute) { json.fromJson(eventRoute, EventRequest::class.java) }
        MaterialTheme(colorScheme = WorkspaceAccent.Events.colors()) {
            EventEditor(request, calendar, { eventJson = null }, attachToChat = { event ->
                eventJson = null
                model.chat.setAttachment(ChatAttachment(eventId = event.id))
                tab = Tab.Chat
            }) {
                request.proposal?.let { model.chat.removeProposal(it.id) }
                eventJson = null
                calendarRefresh++
            }
        }
    } else if (route != null) {
        if (route == NEW_TASK || task != null) {
            TaskEditor(library, task, if (route == NEW_TASK) newTaskSection else section, model, snackbar, openChat = { id ->
                model.chat.setAttachment(ChatAttachment(taskId = id))
                tab = Tab.Chat
            }) { route = null }
        } else {
            MissingTask(snackbar) { model.closeDraft(); route = null }
        }
    } else {
        var navigationHeight by remember { mutableIntStateOf(0) }
        Box(Modifier.fillMaxSize()) {
            Scaffold(
                snackbarHost = { SnackbarHost(snackbar) },
                bottomBar = {
                    NavigationBar(
                        modifier = Modifier.onSizeChanged { navigationHeight = it.height }
                            .semantics { if (creationMenuOpen) hideFromAccessibility() },
                    ) {
                        val colors = MaterialTheme.colorScheme
                        Tab.entries.forEach { entry ->
                            val selected = tab == entry
                            Box(
                                modifier = Modifier.weight(1f)
                                    .padding(horizontal = 2.dp)
                                    .clip(RoundedCornerShape(24.dp))
                                    .selectable(selected, role = Role.Tab, onClick = {
                                        if (tab == Tab.Tasks && entry == Tab.Notes && section !in Sections) {
                                            selectedNoteFolder = section
                                            noteTrash = false
                                        }
                                        if (tab == Tab.Notes && entry == Tab.Tasks && !noteTrash && noteFolder != null) {
                                            selectedSection = noteFolder
                                        }
                                        tab = entry
                                    })
                                    .height(56.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                Glyph(
                                    entry.icon,
                                    description = stringResource(entry.label),
                                    tint = if (selected) sectionColors.primary else colors.onSurfaceVariant,
                                    size = if (selected) 32.dp else 28.dp,
                                    gradient = AssistantActionGradient.takeIf { selected && entry == Tab.Chat },
                                )
                            }
                        }
                    }
                },
            ) { padding ->
                Box(
                    Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding)
                        .semantics { if (creationMenuOpen) hideFromAccessibility() },
                    contentAlignment = Alignment.TopCenter,
                ) {
                    Column(Modifier.widthIn(max = 720.dp).fillMaxWidth().fillMaxHeight()) {
                        tabStates.SaveableStateProvider(tab.name) {
                            MaterialTheme(colorScheme = sectionColors) {
                                when (tab) {
                                    Tab.Tasks -> TaskList(
                                        library, section, { selectedSection = it }, { managing = true }, { route = it }, model,
                                        syncStatus = syncStatus,
                                    )
                                    Tab.Notes -> NotesScreen(
                                        library, noteState, cloud, noteFolder, noteTrash,
                                        select = { selectedNoteFolder = it }, toggleTrash = {
                                            if (noteTrash) selectedNoteFolder = null
                                            noteTrash = !noteTrash
                                        },
                                        manage = { managing = true }, model = model, syncStatus = syncStatus,
                                    )
                                    Tab.Events -> CalendarScreen(calendar, calendarDate, { calendarDateText = it.toString() },
                                        openEvent, { calendarSettings = true }, calendarRefresh)
                                    Tab.Chat -> ChatScreen(
                                        library, model, calendar,
                                        openCreated = { item ->
                                            when (item.kind) {
                                                ChatCreatedKind.Task -> {
                                                    if (library.tasks.any { it.id == item.id }) route = item.id
                                                    else scope.launch { snackbar.showSnackbar(taskMissing) }
                                                }
                                                ChatCreatedKind.Note -> model.openNote(item.id, null, activeOnly = true)
                                            }
                                        },
                                        reviewEvent = { proposal -> openEvent(EventRequest(proposal = proposal)) },
                                        chooseModel = { chooseChatModel = true },
                                        settings = { chatSettings = true },
                                    )
                                    Tab.Settings -> Settings(library, noteState, cloud, model, calendar, calendarRefresh,
                                        calendarSettings = { calendarSettings = true },
                                        chatSettings = { chatSettings = true },
                                        chooseChatModel = { chooseChatModel = true })
                                }
                            }
                        }
                    }
                }
            }
            if (showCreation) {
                CreationMenu(
                    expanded = creationMenuOpen, onExpanded = { creationMenuOpen = it },
                    notesReady = noteState.limit != null, accent = tab.accent,
                    bottomInset = with(LocalDensity.current) { navigationHeight.toDp() },
                    modifier = Modifier.matchParentSize(), create = create,
                )
            }
        }
        if (managing) MaterialTheme(colorScheme = sectionColors) {
            Folders(library, model) { managing = false }
        }
    }
    if (calendarSettings) MaterialTheme(colorScheme = WorkspaceAccent.Events.colors()) {
        CalendarChooser(calendar) { calendarSettings = false; calendarRefresh++ }
    }
    if (chooseChatModel || chatSettings) MaterialTheme(colorScheme = WorkspaceAccent.Chat.colors()) {
        if (chooseChatModel) ChatModelDialog(model.chat) { chooseChatModel = false }
        if (chatSettings) ChatConnectionDialog(model.chat) { chatSettings = false }
    }
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
    model: PlannerModel, syncStatus: @Composable () -> Unit,
) {
    var searching by rememberSaveable { mutableStateOf(false) }
    var search by rememberSaveable(section) { mutableStateOf("") }
    Heading(stringResource(R.string.tasks), status = syncStatus) {
        ActionIcon(if (searching) R.drawable.ic_close else R.drawable.ic_search,
            if (searching) R.string.close_search else R.string.search) {
            searching = !searching
            if (!searching) search = ""
        }
        ActionIcon(R.drawable.ic_folder, R.string.manage_folders, onClick = manage)
    }
    val sections = Sections.keys.toList() + library.folders.map(Entity::id)
    FolderPages(
        sections, section, select, dividerBefore = Sections.size,
        label = { sectionName(it, library) },
        afterTabs = {
            if (searching) {
                PlannerTextField(
                    value = search, onValueChange = { search = it }, singleLine = true,
                    placeholder = R.string.search,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 6.dp),
                )
            }
        },
    ) { page ->
        TaskFolderPage(library, page, search.takeIf { page == section }.orEmpty(), open, model)
    }
}

@Composable
private fun TaskFolderPage(library: Library, section: String, search: String, open: (String) -> Unit, model: PlannerModel) {
    var showCompleted by rememberSaveable { mutableStateOf(false) }
    val tasks = library.tasks.filter { task ->
        task.inSection(section, library) && (
            search.isBlank() || task.text("title").orEmpty().contains(search.trim(), ignoreCase = true) ||
                task.text("description").orEmpty().contains(search.trim(), ignoreCase = true)
        )
    }
    val (done, active) = tasks.partition(Entity::completed)
    LazyColumn(
        Modifier.fillMaxSize(),
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
                    tint = if (task.focused) taskFocusColor() else MaterialTheme.colorScheme.onSurfaceVariant,
                ) { model.toggleFocus(task) }
            }
            if (!last) HorizontalDivider(Modifier.padding(start = 48.dp, end = 12.dp),
                color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
        }
    }
}

@Composable
internal fun Heading(title: String, status: @Composable () -> Unit = {}, actions: @Composable () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp, top = 18.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
            Text(title, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.headlineLarge,
                fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            status()
        }
        actions()
    }
}

@Composable
internal fun SyncStatus(
    library: Library, notes: NotesState, cloud: CloudState, retry: () -> Unit,
    showActivity: Boolean = false,
) {
    val messages = listOfNotNull(cloud.message, notes.error?.takeUnless { it == R.string.storage_error }).distinct()
    val hasProblem = messages.isNotEmpty() || library.rejected > 0
    val pending = library.pending + notes.pending
    val showPending = showActivity && pending > 0
    if (!hasProblem && !showPending) {
        if (showActivity && cloud.busy) SyncProgress()
        return
    }

    var showDetails by rememberSaveable { mutableStateOf(false) }
    when {
        hasProblem -> ActionIcon(R.drawable.ic_sync_warning, R.string.sync_issue, tint = MaterialTheme.colorScheme.error) {
            showDetails = true
        }
        cloud.busy -> SyncProgress()
        else -> ActionIcon(R.drawable.ic_sync, R.string.notes_pending) { showDetails = true }
    }
    if (showDetails) {
        val waiting by produceState(cloud.syncRetryAt > SystemClock.elapsedRealtime(), cloud.syncRetryAt) {
            value = cloud.syncRetryAt > SystemClock.elapsedRealtime()
            delay((cloud.syncRetryAt - SystemClock.elapsedRealtime()).coerceAtLeast(0))
            value = false
        }
        AlertDialog(
            onDismissRequest = { showDetails = false },
            title = { Text(stringResource(if (hasProblem) R.string.sync_issue else R.string.sync_status)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    messages.forEach { Text(stringResource(it)) }
                    if (pending > 0) Text(stringResource(R.string.pending, pending))
                    if (library.rejected > 0) Text(stringResource(R.string.rejected, library.rejected))
                    if (cloud.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                }
            },
            confirmButton = {
                TextButton(onClick = retry, enabled = !cloud.busy && !waiting) {
                    Text(stringResource(R.string.sync_now))
                }
            },
            dismissButton = {
                TextButton(onClick = { showDetails = false }) { Text(stringResource(R.string.close)) }
            },
        )
    }
}

@Composable
private fun SyncProgress() {
    val label = stringResource(R.string.sync_status)
    CircularProgressIndicator(
        Modifier.size(20.dp).semantics { contentDescription = label },
        strokeWidth = 2.dp,
    )
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
    iconGradient: Brush? = null,
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
            Glyph(icon, tint = MaterialTheme.colorScheme.onPrimaryContainer, gradient = iconGradient)
        }
        Text(stringResource(title), style = MaterialTheme.typography.titleLarge)
        Text(stringResource(hint), style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        footer()
    }
}

@Composable
internal fun taskFocusColor(): Color =
    if (isSystemInDarkTheme()) Color(0xFFFFD600) else Color(0xFFFFCC00)

@Composable
internal fun Glyph(
    @DrawableRes id: Int,
    description: String? = null,
    tint: Color = MaterialTheme.colorScheme.onSurface,
    size: Dp = 24.dp,
    gradient: Brush? = null,
) {
    val mask = if (gradient == null) Modifier else Modifier
        .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
        .drawWithCache {
            onDrawWithContent {
                drawContent()
                drawRect(brush = gradient, blendMode = BlendMode.SrcIn)
            }
        }
    Icon(painterResource(id), description, Modifier.size(size).then(mask), tint = tint)
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


@Composable
internal fun FolderPages(
    folders: List<String>, selected: String, select: (String) -> Unit, dividerBefore: Int,
    label: @Composable (String) -> String, afterTabs: @Composable () -> Unit,
    content: @Composable (String) -> Unit,
) {
    val pages = rememberSaveableStateHolder()
    val selectFolder by rememberUpdatedState(select)
    val index = folders.indexOf(selected).coerceAtLeast(0)
    key(folders) {
        val scope = rememberCoroutineScope()
        val pager = rememberPagerState(initialPage = index) { folders.size }
        LaunchedEffect(index, pager) {
            if (pager.settledPage != index) pager.scrollToPage(index)
        }
        LaunchedEffect(pager) {
            snapshotFlow { pager.settledPage }.drop(1).collect { page ->
                folders.getOrNull(page)?.let(selectFolder)
            }
        }
        FolderTabs(folders, selected, select = { folder ->
            scope.launch { pager.animateScrollToPage(folders.indexOf(folder)) }
        }, dividerBefore = dividerBefore, label = label)
        afterTabs()
        HorizontalPager(
            state = pager, modifier = Modifier.fillMaxSize(),
            key = { folders[it] }, userScrollEnabled = folders.size > 1,
        ) { page ->
            val folder = folders[page]
            pages.SaveableStateProvider(folder) { content(folder) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun <T> FolderTabs(
    keys: List<T>, selected: T, select: (T) -> Unit, dividerBefore: Int? = null,
    label: @Composable (T) -> String,
) {
    PrimaryScrollableTabRow(
        selectedTabIndex = keys.indexOf(selected).coerceAtLeast(0), edgePadding = 6.dp, minTabWidth = 0.dp,
        indicator = {},
    ) {
        keys.forEachIndexed { index, key ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (index == dividerBefore) {
                    Box(Modifier.width(8.dp), contentAlignment = Alignment.Center) {
                        VerticalDivider(Modifier.height(18.dp))
                    }
                }
                val active = key == selected
                Box(
                    Modifier.selectable(active, role = Role.Tab, onClick = { select(key) })
                        .padding(horizontal = 14.dp).heightIn(min = 48.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        label(key), Modifier.widthIn(max = 184.dp).padding(vertical = 8.dp),
                        color = if (active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelLarge,
                    )
                    if (active) {
                        Box(Modifier.matchParentSize(), contentAlignment = Alignment.BottomCenter) {
                            Spacer(Modifier.fillMaxWidth().height(3.dp).background(MaterialTheme.colorScheme.primary, CircleShape))
                        }
                    }
                }
            }
        }
    }
}
