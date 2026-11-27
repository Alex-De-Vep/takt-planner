package local.planner.android

import android.content.ClipData
import android.content.ClipboardManager
import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonColors
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import java.time.LocalDateTime
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
internal fun ChatScreen(
    library: Library, model: PlannerModel, calendar: DeviceCalendar,
    openCreated: (ChatCreatedItem) -> Unit, reviewEvent: (ChatEventProposal) -> Unit,
    chooseModel: () -> Unit, settings: () -> Unit,
) {
    val chat by model.chat.state.collectAsState()
    key(chat.threadId) {
        ChatThreadScreen(chat, library, model, calendar, openCreated, reviewEvent, chooseModel, settings)
    }
}

@Composable
private fun ChatThreadScreen(
    chat: ChatState, library: Library, model: PlannerModel, calendar: DeviceCalendar,
    openCreated: (ChatCreatedItem) -> Unit, reviewEvent: (ChatEventProposal) -> Unit,
    chooseModel: () -> Unit, settings: () -> Unit,
) {
    val (taskId, noteId, eventId) = chat.attachment
    val selectTaskId: (String?) -> Unit = { model.chat.setAttachment(ChatAttachment(taskId = it)) }
    val selectNoteId: (String) -> Unit = { model.chat.setAttachment(ChatAttachment(noteId = it)) }
    val clearAttachment = { model.chat.setAttachment(ChatAttachment()) }
    val prompt = remember { mutableStateOf(model.chat.draft(chat.threadId)) }
    LaunchedEffect(chat.lines.lastOrNull()?.id) {
        prompt.value = model.chat.draft(chat.threadId)
    }
    var readingMessage by rememberSaveable { mutableStateOf<String?>(null) }
    var selectContext by rememberSaveable { mutableStateOf(false) }
    var selectNotes by rememberSaveable { mutableStateOf(false) }
    var applying by remember { mutableStateOf<String?>(null) }
    val task = library.tasks.firstOrNull { it.id == taskId }
    val notes by model.notes.collectAsState()
    val noteDigest = notes.entries.firstOrNull { it.id == noteId }?.digest
    val noteEntry by produceState<Pair<String, NoteChatContext?>?>(null, library.workspace, noteId, noteDigest) {
        value = null
        value = noteId?.let { it to model.noteChatContext(library.workspace, it) }
    }
    val note = noteEntry?.takeIf { it.first == noteId }?.second?.takeIf { it.workspace == library.workspace }
    val eventEntry by produceState<Pair<Long, PhoneEvent?>?>(null, calendar, eventId) {
        value = null
        if (eventId != null) {
            val event = try {
                withContext(Dispatchers.IO) { calendar.currentEvent(eventId) }
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                null
            }
            value = eventId to event
        }
    }
    val attachedEvent = eventEntry?.takeIf { it.first == eventId }?.second?.takeIf { calendar.mayRead() }
    val contextReady = (noteId == null || note != null) && (eventId == null || attachedEvent != null)
    val clipboard = LocalContext.current.getSystemService(ClipboardManager::class.java)
    val copyLabel = stringResource(R.string.chat_copy_message)
    val copyMessage: (String) -> Unit = { text ->
        clipboard?.setPrimaryClip(ClipData.newPlainText(copyLabel, text))
    }
    val focus = LocalFocusManager.current
    val openSettings = { focus.clearFocus(); settings() }
    val openContextPicker = { focus.clearFocus(); selectContext = true }
    val send = { text: String ->
        if (contextReady) {
            model.chat.send(text.trim(), task, task?.let { library.items(it.id) }.orEmpty(), note, attachedEvent)
        }
    }
    ChatHeading(chat.activeModelLabel ?: chat.model.takeIf(String::isNotEmpty)) {
        focus.clearFocus()
        chooseModel()
    }
    ChatHistoryBar(
        chat, model.chat,
        enabled = !chat.busy && applying == null && chat.savingCreation == null && chat.threadId != null,
        clearFocus = { focus.clearFocus() },
    )
    if (chat.historyError) {
        Text(stringResource(R.string.chat_history_error), Modifier.padding(20.dp), color = MaterialTheme.colorScheme.error)
        return
    }
    if (chat.threadId == null) {
        LinearProgressIndicator(Modifier.fillMaxWidth())
        return
    }
    if (chat.model.isEmpty() && chat.lines.isEmpty()) {
        Box(Modifier.padding(horizontal = 20.dp, vertical = 12.dp)) {
            EmptyPanel(
                R.drawable.ic_assistant,
                R.string.chat_empty_title,
                if (chat.profiles.isEmpty()) R.string.chat_empty_hint else R.string.chat_no_visible_models,
                iconGradient = AssistantActionGradient,
                footer = {
                    Button(onClick = openSettings) { Text(stringResource(R.string.chat_connect_action)) }
                },
            )
        }
        chat.message?.let {
            Text(stringResource(it), Modifier.padding(horizontal = 20.dp), color = MaterialTheme.colorScheme.error)
        }
        return
    }

    val scroll = rememberLazyListState()
    val entries = remember(chat.lines) { chat.lines.asReversed().filter { it.text.isNotBlank() || it.createdItems.isNotEmpty() } }
    val showStart = entries.isEmpty()
    val hasQuestions = chat.questions.isNotEmpty()
    val canApply = !chat.busy && applying == null && chat.savingCreation == null
    val noteAvailability = when {
        notes.workspace != library.workspace || !notes.loaded -> R.string.notes_loading
        notes.limit == null -> R.string.notes_unsupported
        else -> null
    }
    val latestMessage = entries.firstOrNull()?.id
    var shownLatestMessage by rememberSaveable { mutableStateOf(latestMessage) }
    LaunchedEffect(latestMessage) {
        if (shownLatestMessage != latestMessage) {
            shownLatestMessage = latestMessage
            if (latestMessage != null) scroll.scrollToItem(0)
        }
    }

    Column(Modifier.imePadding()) {
        LazyColumn(
            state = scroll, modifier = Modifier.weight(1f), reverseLayout = !showStart,
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp, if (showStart) Alignment.Top else Alignment.Bottom),
        ) {
            if (showStart) item {
                Column(Modifier.padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Glyph(R.drawable.ic_assistant, size = 44.dp, gradient = AssistantActionGradient)
                    Text(stringResource(R.string.chat_start), style = MaterialTheme.typography.titleMedium)
                    Text(stringResource(R.string.chat_start_hint), style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            chat.noteProposal?.let { proposal ->
                item(key = proposal.id) {
                    NoteProposalCard(proposal, canApply,
                        dismiss = { model.chat.removeProposal(proposal.id) },
                        apply = {
                            if (applying == null) {
                                applying = proposal.id
                                model.applyNoteProposal(proposal) { applying = null }
                            }
                        })
                }
            }
            items(chat.proposals.asReversed(), key = ChatProposal::id) { proposal ->
                ProposalCard(proposal, canApply, { model.chat.removeProposal(proposal.id) }) {
                    if (applying == null) {
                        applying = proposal.id
                        model.applyChatProposal(proposal, { applying = null }, { applying = null })
                    }
                }
            }
            items(chat.newNotes.asReversed(), key = ChatNewNoteProposal::id) { proposal ->
                NewNoteProposalCard(proposal, canApply, noteAvailability,
                    dismiss = { model.chat.removeProposal(proposal.id) },
                    create = { model.createNoteFromChat(proposal) })
            }
            items(chat.eventProposals.asReversed(), key = ChatEventProposal::id) { proposal ->
                EventProposalCard(proposal, canApply,
                    dismiss = { model.chat.removeProposal(proposal.id) },
                    review = { reviewEvent(proposal) })
            }
            if (hasQuestions) item {
                Column {
                    chat.questions.forEach { question ->
                        Text(question.text)
                        question.options.forEach { option ->
                            TextButton(onClick = { send(option) }, enabled = !chat.busy && chat.savingCreation == null) { Text(option) }
                        }
                    }
                }
            }
            items(entries, key = ChatLine::id, contentType = { "message" }) { line ->
                ChatMessageBubble(line, copy = copyMessage, openCreated = openCreated) {
                    focus.clearFocus()
                    readingMessage = line.id
                }
            }
        }
        Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp)) {
            if (task != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = openContextPicker, enabled = !chat.busy, modifier = Modifier.weight(1f, fill = false)) {
                        Text(task.text("title").orEmpty().ifBlank { stringResource(R.string.untitled) },
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    ActionIcon(R.drawable.ic_close, R.string.chat_remove_task) { selectTaskId(null) }
                }
            }
            if (noteId != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Glyph(R.drawable.ic_note)
                    Text(note?.title?.ifBlank { stringResource(R.string.untitled_note) }
                        ?: stringResource(R.string.note), Modifier.weight(1f).padding(start = 8.dp),
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    ActionIcon(R.drawable.ic_close, R.string.chat_remove_note, onClick = clearAttachment)
                }
                if (noteEntry?.first == noteId && note == null) Text(stringResource(R.string.note_unavailable))
            }
            if (eventId != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Glyph(R.drawable.ic_calendar)
                    Text(attachedEvent?.title ?: stringResource(R.string.event_details),
                        Modifier.weight(1f).padding(start = 8.dp), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    ActionIcon(R.drawable.ic_close, R.string.chat_remove_event, onClick = clearAttachment)
                }
                if (eventEntry?.first == eventId && attachedEvent == null) Text(stringResource(R.string.chat_event_unavailable))
            }
            if (chat.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            chat.message?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
            if (chat.model.isEmpty()) {
                TextButton(onClick = openSettings) { Text(stringResource(R.string.chat_connect_action)) }
            } else {
                ChatMessageInput(
                    prompt = prompt,
                    saveDraft = { model.chat.setDraft(chat.threadId, it) },
                    showAttach = task == null && noteId == null && eventId == null,
                    attachEnabled = !chat.busy && (library.tasks.isNotEmpty() || notes.entries.any { it.deletedAt == null }),
                    sendEnabled = !chat.busy && chat.savingCreation == null && contextReady,
                    attach = openContextPicker,
                    send = send,
                )
            }
        }
    }
    val fullMessage = remember(readingMessage, entries) { entries.firstOrNull { it.id == readingMessage } }
    fullMessage?.let { line ->
        AlertDialog(
            onDismissRequest = { readingMessage = null },
            title = { Text(stringResource(R.string.chat_full_message)) },
            text = {
                Box(Modifier.heightIn(max = 440.dp).verticalScroll(rememberScrollState())) {
                    SelectionContainer { Text(line.text) }
                }
            },
            confirmButton = {
                TextButton(onClick = { readingMessage = null }) { Text(stringResource(R.string.close)) }
            },
            dismissButton = {
                IconButton(onClick = { copyMessage(line.text) }) {
                    Glyph(R.drawable.ic_copy, copyLabel, tint = MaterialTheme.colorScheme.primary, size = 18.dp)
                }
            },
        )
    }
    if (selectContext) {
        var search by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { selectContext = false }, title = { Text(stringResource(R.string.chat_attach_context)) },
            text = {
                Column {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(selected = !selectNotes, onClick = { selectNotes = false },
                            label = { Text(stringResource(R.string.tasks)) })
                        FilterChip(selected = selectNotes, onClick = { selectNotes = true },
                            label = { Text(stringResource(R.string.notes)) })
                    }
                    Text(stringResource(if (selectNotes) R.string.chat_note_context_hint else R.string.chat_context_hint))
                    PlannerTextField(search, { search = it }, placeholder = R.string.search, singleLine = true)
                    LazyColumn(Modifier.heightIn(max = 280.dp)) {
                        if (selectNotes) {
                            items(notes.entries.filter {
                                it.deletedAt == null && it.title.contains(search.trim(), ignoreCase = true)
                            }.sortedByDescending { it.updatedAt }, key = NoteSummary::id) { entry ->
                                Text(entry.title.ifBlank { stringResource(R.string.untitled_note) },
                                    Modifier.fillMaxWidth().clickable {
                                        selectNoteId(entry.id)
                                        selectContext = false
                                    }.padding(vertical = 12.dp))
                            }
                        } else {
                            items(library.tasks.filter { it.text("title").orEmpty().contains(search.trim(), ignoreCase = true) },
                                key = Entity::id) { entry ->
                                Text(entry.text("title").orEmpty().ifBlank { stringResource(R.string.untitled) },
                                    Modifier.fillMaxWidth().clickable {
                                        selectTaskId(entry.id)
                                        selectContext = false
                                    }.padding(vertical = 12.dp))
                            }
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { selectContext = false }) { Text(stringResource(R.string.close)) } },
        )
    }
}

private const val CHAT_INLINE_CHARACTERS = 1600
private const val CHAT_INLINE_LINES = 12

@Composable
private fun ChatMessageBubble(
    line: ChatLine, copy: (String) -> Unit, openCreated: (ChatCreatedItem) -> Unit, readFull: () -> Unit,
) {
    val preview = remember(line.text) { line.text.take(CHAT_INLINE_CHARACTERS).trimEnd { it.isHighSurrogate() } }
    val shortened = preview.length < line.text.length
    var overflow by remember(line.text) { mutableStateOf(false) }
    val userMessage = line.role == "user"
    val copyLabel = stringResource(R.string.chat_copy_message)
    val colors = MaterialTheme.colorScheme
    Column(Modifier.fillMaxWidth()) {
        Surface(
            modifier = Modifier.align(if (userMessage) Alignment.End else Alignment.Start),
            shape = MaterialTheme.shapes.large,
            color = if (userMessage) colors.primaryContainer else colors.surfaceContainerLow,
            contentColor = if (userMessage) colors.onPrimaryContainer else colors.onSurface,
        ) {
            Column(if (userMessage) Modifier else Modifier.background(AssistantReplyGradient)) {
                if (line.text.isNotBlank()) {
                    SelectionContainer {
                        Text(
                            if (shortened) "$preview…" else preview,
                            Modifier.padding(start = 14.dp, end = 14.dp, top = 12.dp),
                            maxLines = CHAT_INLINE_LINES,
                            overflow = TextOverflow.Ellipsis,
                            onTextLayout = { if (!shortened) overflow = it.hasVisualOverflow },
                        )
                    }
                    Row(Modifier.align(Alignment.End), verticalAlignment = Alignment.CenterVertically) {
                        if (shortened || overflow) {
                            TextButton(onClick = readFull) { Text(stringResource(R.string.chat_read_full_message)) }
                        }
                        IconButton(onClick = { copy(line.text) }) {
                            Glyph(R.drawable.ic_copy, copyLabel, tint = MaterialTheme.colorScheme.primary, size = 18.dp)
                        }
                    }
                }
                if (line.createdItems.isNotEmpty()) {
                    Column(
                        Modifier.padding(
                            start = 14.dp, end = 14.dp, top = if (line.text.isBlank()) 12.dp else 2.dp, bottom = 12.dp,
                        ),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        line.createdItems.forEach { item ->
                            val (entity, label) = when (item.kind) {
                                ChatCreatedKind.Task -> ChatEntity.Task to R.string.chat_open_created_task
                                ChatCreatedKind.Note -> ChatEntity.Note to R.string.chat_open_created_note
                            }
                            val action = stringResource(label)
                            val description = if (item.title.isBlank()) action else "$action · ${item.title}"
                            Button(
                                onClick = { openCreated(item) },
                                modifier = Modifier.semantics { contentDescription = description },
                                colors = entity.colors().button,
                            ) {
                                Text(action, Modifier.clearAndSetSemantics {}, textAlign = TextAlign.Center)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ChatMessageInput(
    prompt: MutableState<String>, showAttach: Boolean, attachEnabled: Boolean, sendEnabled: Boolean,
    saveDraft: (String) -> Unit, attach: () -> Unit, send: (String) -> Unit,
) {
    val text = prompt.value
    Row(
        Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (showAttach) {
            IconButton(onClick = attach, enabled = attachEnabled) {
                Glyph(R.drawable.ic_attach, stringResource(R.string.chat_attach_context), LocalContentColor.current)
            }
        }
        PlannerTextField(text, {
            val draft = it.take(4000)
            prompt.value = draft
            saveDraft(draft)
        }, Modifier.weight(1f),
            placeholder = R.string.chat_message, maxLines = 3)
        val canSend = sendEnabled && text.isNotBlank()
        FilledIconButton(
            onClick = { send(text) },
            enabled = canSend,
            colors = IconButtonDefaults.filledIconButtonColors(
                containerColor = Color.Transparent,
                contentColor = Color.White,
            ),
        ) {
            Box(
                Modifier.size(40.dp).then(if (canSend) Modifier.background(AssistantActionGradient, CircleShape) else Modifier),
                contentAlignment = Alignment.Center,
            ) {
                Glyph(R.drawable.ic_send, stringResource(R.string.chat_send), LocalContentColor.current)
            }
        }
    }
}

private enum class ChatEntity(@DrawableRes val icon: Int) {
    Task(R.drawable.ic_task_done), Note(R.drawable.ic_note), Event(R.drawable.ic_calendar);

    @Composable
    fun colors(): ChatEntityColors {
        val dark = isSystemInDarkTheme()
        val tint = when (this) {
            Task -> Color(if (dark) TaskPrimaryDark else TaskPrimaryLight)
            Note -> if (dark) Color(NotePrimaryDark) else Color(0xFF286D57)
            Event -> Color(if (dark) EventPrimaryDark else EventPrimaryLight)
        }
        val cardTint = if (this == Note && !dark) NoteActionColor else tint
        val background = cardTint.copy(alpha = if (dark) 0.08f else 0.13f)
            .compositeOver(MaterialTheme.colorScheme.surface)
        val (fill, text) = when (this) {
            Task -> tint to if (dark) Color(TaskOnPrimaryDark) else Color.White
            Note -> NoteActionColor to OnNoteActionColor
            Event -> Color(EventPrimaryLight) to Color.White
        }
        return ChatEntityColors(tint, background, ButtonDefaults.buttonColors(containerColor = fill, contentColor = text))
    }
}

private data class ChatEntityColors(val tint: Color, val background: Color, val button: ButtonColors)

@Composable
private fun ChatEntityCard(
    entity: ChatEntity, @StringRes label: Int, spacing: Dp = 6.dp,
    content: @Composable ColumnScope.(ButtonColors) -> Unit,
) {
    val colors = entity.colors()
    Surface(shape = MaterialTheme.shapes.large, color = colors.background, contentColor = MaterialTheme.colorScheme.onSurface) {
        Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(spacing)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Glyph(entity.icon, tint = colors.tint, size = 18.dp)
                Text(stringResource(label), style = MaterialTheme.typography.labelLarge, color = colors.tint)
            }
            content(colors.button)
        }
    }
}

@Composable
private fun ChatEntityActions(
    @StringRes label: Int, colors: ButtonColors, enabled: Boolean, dismiss: () -> Unit,
    actionEnabled: Boolean = enabled, action: () -> Unit,
) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(onClick = action, enabled = actionEnabled, colors = colors) {
            Text(stringResource(label))
        }
        TextButton(onClick = dismiss, enabled = enabled,
            colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onSurfaceVariant)) {
            Text(stringResource(R.string.cancel))
        }
    }
}

@Composable
private fun NewNoteProposalCard(
    proposal: ChatNewNoteProposal, available: Boolean, availabilityMessage: Int?, dismiss: () -> Unit, create: () -> Unit,
) {
    ChatEntityCard(ChatEntity.Note, R.string.new_note, spacing = 8.dp) { colors ->
        SelectionContainer {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(proposal.title, style = MaterialTheme.typography.titleMedium)
                if (proposal.body.isNotBlank()) {
                    Text(proposal.body, Modifier.heightIn(max = 280.dp).verticalScroll(rememberScrollState()))
                }
            }
        }
        availabilityMessage?.let { Text(stringResource(it), style = MaterialTheme.typography.bodySmall) }
        ChatEntityActions(R.string.create_note, colors, available, dismiss,
            actionEnabled = available && availabilityMessage == null, action = create)
    }
}

@Composable
private fun NoteProposalCard(
    proposal: ChatNoteProposal, available: Boolean, dismiss: () -> Unit, apply: () -> Unit,
) {
    ChatEntityCard(ChatEntity.Note, R.string.chat_note_suggestion, spacing = 8.dp) { colors ->
        val title = proposal.title ?: proposal.note.title
        SelectionContainer {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(title.ifBlank { stringResource(R.string.untitled_note) }, style = MaterialTheme.typography.titleMedium)
                proposal.body?.let { Text(it) }
            }
        }
        ChatEntityActions(R.string.chat_note_apply, colors, available, dismiss, action = apply)
    }
}

@Composable
private fun ChatHeading(activeModel: String?, chooseModel: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 12.dp, top = 4.dp, bottom = 4.dp).heightIn(min = 48.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(stringResource(R.string.chat), style = MaterialTheme.typography.headlineSmall)
        if (activeModel != null) {
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
                TextButton(onClick = chooseModel, contentPadding = PaddingValues(horizontal = 4.dp)) {
                    Text(activeModel, Modifier.weight(1f, fill = false), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Glyph(R.drawable.ic_chevron_down, tint = LocalContentColor.current)
                }
            }
        }
    }
}

@Composable
private fun ProposalCard(proposal: ChatProposal, available: Boolean, dismiss: () -> Unit, apply: () -> Unit) {
    val original = proposal.task
    ChatEntityCard(ChatEntity.Task, if (original == null) R.string.new_task else R.string.chat_edit_task) { colors ->
        SelectionContainer {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                original?.text("title")?.let { Text(stringResource(R.string.chat_proposal_target, it)) }
                proposal.title?.let { Text(it, style = MaterialTheme.typography.titleMedium) }
                proposal.description?.let { Text(it.ifBlank { stringResource(R.string.chat_clear_description) }) }
                proposal.checklist.forEach { Text("• $it") }
                proposal.deadline?.let { Text(deadlineLabel(it)) }
            }
        }
        if (proposal.clearDeadline) Text(stringResource(R.string.chat_clear_deadline))
        if (proposal.focused || proposal.focusChange == true) Text(stringResource(R.string.show_in_today))
        if (proposal.focusChange == false) Text(stringResource(R.string.unstar))
        proposal.completion?.let { complete ->
            Text(stringResource(if (complete) R.string.complete_task else R.string.reopen_task))
        }
        ChatEntityActions(R.string.chat_apply, colors, available, dismiss, action = apply)
    }
}

@Composable
private fun EventProposalCard(proposal: ChatEventProposal, available: Boolean, dismiss: () -> Unit, review: () -> Unit) {
    ChatEntityCard(ChatEntity.Event, if (proposal.original == null) R.string.new_event else R.string.edit_event) { colors ->
        SelectionContainer {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(proposal.title, style = MaterialTheme.typography.titleMedium)
                Text(chatEventInterval(proposal))
                if (proposal.allDay) Text(stringResource(R.string.all_day))
                if (proposal.location.isNotBlank()) Text(proposal.location)
                if (proposal.description.isNotBlank()) Text(proposal.description)
            }
        }
        ChatEntityActions(R.string.chat_review_event, colors, available, dismiss, action = review)
    }
}

@Composable
private fun chatEventInterval(proposal: ChatEventProposal): String {
    val start = LocalDateTime.parse(proposal.start)
    val end = LocalDateTime.parse(proposal.end)
    val startDate = start.toLocalDate()
    val endDate = end.toLocalDate()
    val sameDay = startDate == endDate
    val firstDate = dateLabel(startDate)
    val lastDate = if (sameDay) firstDate else dateLabel(endDate)
    if (proposal.allDay) return if (sameDay) firstDate else "$firstDate –\n$lastDate"
    val firstTime = timeLabel(start.toLocalTime())
    val lastTime = timeLabel(end.toLocalTime())
    return when {
        sameDay && firstTime == lastTime -> "$firstDate · $firstTime"
        sameDay -> "$firstDate · $firstTime–$lastTime"
        else -> "$firstDate · $firstTime –\n$lastDate · $lastTime"
    }
}
