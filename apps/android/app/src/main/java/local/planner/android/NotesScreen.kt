package local.planner.android

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import java.time.ZoneId
import kotlinx.coroutines.delay

@Composable
internal fun NotesScreen(
    library: Library, state: NotesState, cloud: CloudState, folder: String?, trash: Boolean,
    select: (String?) -> Unit, toggleTrash: () -> Unit, manage: () -> Unit, model: PlannerModel,
    syncStatus: @Composable () -> Unit,
) {
    var searching by rememberSaveable { mutableStateOf(false) }
    var query by rememberSaveable { mutableStateOf("") }
    var menu by remember { mutableStateOf(false) }
    val search = query.trim()
    val result by produceState<Pair<String, Set<String>>?>(null, library.workspace, state.entries, search) {
        value = if (search.isBlank()) null else {
            delay(180)
            search to model.searchNotes(library.workspace, search)
        }
    }
    val matches = result?.takeIf { it.first == search }?.second
    val status = state.error ?: cloud.message
    BackHandler(trash, onBack = toggleTrash)
    Heading(stringResource(if (trash) R.string.notes_trash else R.string.notes), status = syncStatus) {
        if (state.limit != null) {
            if (state.pending > 0) {
                if (cloud.busy) {
                    val label = stringResource(R.string.notes_loading)
                    CircularProgressIndicator(
                        Modifier.padding(horizontal = 12.dp).size(18.dp).semantics { contentDescription = label },
                        strokeWidth = 2.dp,
                    )
                } else {
                    ActionIcon(R.drawable.ic_sync, R.string.notes_pending, onClick = model::retrySync)
                }
            }
            ActionIcon(if (searching) R.drawable.ic_close else R.drawable.ic_search,
                if (searching) R.string.close_search else R.string.search) {
                searching = !searching
                if (!searching) query = ""
            }
            Box {
                ActionIcon(R.drawable.ic_more, R.string.note_actions) { menu = true }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.manage_folders)) }, onClick = {
                        menu = false
                        manage()
                    })
                    DropdownMenuItem(text = { Text(stringResource(if (trash) R.string.all_notes else R.string.notes_trash)) },
                        onClick = { menu = false; toggleTrash() })
                }
            }
        }
    }

    if (state.limit != null && !trash) {
        FolderTabs(listOf(null) + library.folders.map(Entity::id), folder, select, dividerBefore = 1) {
            if (it == null) stringResource(R.string.all_notes) else sectionName(it, library)
        }
    }
    if (searching) {
        PlannerTextField(query, { query = it }, Modifier.fillMaxWidth().padding(horizontal = 20.dp),
            placeholder = R.string.search, singleLine = true)
    }

    val entries = state.entries.filter {
        trash == (it.deletedAt != null) && (trash || folder == null || it.folderId == folder) &&
            (search.isBlank() || matches?.contains(it.id) == true)
    }.sortedWith(compareByDescending<NoteSummary> { it.pinned }.thenByDescending { it.updatedAt })

    LazyColumn(
        Modifier.fillMaxWidth(),
        contentPadding = PaddingValues(start = 20.dp, top = 12.dp, end = 20.dp, bottom = 92.dp),
    ) {
        if (state.error == R.string.storage_error) item {
            Text(stringResource(R.string.storage_error), color = MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(vertical = 8.dp))
            TextButton(onClick = model::retrySync, enabled = !cloud.busy) { Text(stringResource(R.string.retry)) }
        }
        if (trash && state.limit != null) item {
            Text(stringResource(R.string.notes_trash_retention), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(bottom = 8.dp))
        }
        if (state.conflicts > 0) item {
            Text(stringResource(R.string.note_conflict_copy), style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(vertical = 8.dp))
        }
        when {
            !state.loaded -> if (status == null) item {
                Text(stringResource(R.string.notes_loading), modifier = Modifier.padding(bottom = 10.dp))
                LinearProgressIndicator(Modifier.fillMaxWidth())
            }
            state.limit == null -> item {
                Text(stringResource(R.string.notes_unsupported), modifier = Modifier.padding(vertical = 8.dp))
            }
            entries.isEmpty() -> item {
                EmptyPanel(
                    R.drawable.ic_note,
                    when {
                        search.isNotBlank() -> R.string.no_results
                        trash -> R.string.notes_trash_empty
                        else -> R.string.no_notes
                    },
                    when {
                        search.isNotBlank() -> R.string.no_results_hint
                        trash -> R.string.notes_trash_hint
                        else -> R.string.no_notes_hint
                    },
                )
            }
            else -> items(entries, key = NoteSummary::id) { note ->
                NoteRow(note, library, model)
            }
        }
    }
}

@Composable
private fun NoteRow(note: NoteSummary, library: Library, model: PlannerModel) {
    Column(
        Modifier.fillMaxWidth().clickable { model.openNote(note.id, null) }.padding(vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
            if (note.pinned) Glyph(R.drawable.ic_pin, stringResource(R.string.note_pinned),
                MaterialTheme.colorScheme.primary)
            Text(
                note.title.ifBlank { stringResource(R.string.untitled_note) },
                Modifier.weight(1f),
                style = MaterialTheme.typography.titleMedium,
            )
        }
        if (note.preview.isNotBlank()) {
            Text(note.preview, maxLines = 2, overflow = TextOverflow.Ellipsis,
                color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
        }
        val date = dateLabel(noteInstant(note.updatedAt).atZone(ZoneId.systemDefault()).toLocalDate())
        val name = library.folders.firstOrNull { it.id == note.folderId }?.text("name")
        Text(if (name == null) date else stringResource(R.string.note_folder_date, name, date),
            style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    HorizontalDivider()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun NoteEditor(
    draft: NoteDraft, library: Library, writable: Boolean, sharedFormat: Boolean,
    model: PlannerModel, snackbar: SnackbarHostState,
    openChat: (String) -> Unit,
) {
    val original = draft.original?.document
    val removed = original?.deletedAt != null
    val formatted = original?.document?.isNotEmpty() == true
    val voice = model.noteVoice
    val recording = voice.startedAt != null
    val enabled = writable && !draft.saving && !recording
    val editing = enabled && !removed
    val sharedEditor = draft.richText != null || (sharedFormat && original == null)
    val hasContent = draft.title.isNotBlank() || draft.text.isNotBlank() || voice.clip != null
    val defaultVoiceTitle = stringResource(R.string.voice_note_title)
    val context = LocalContext.current
    val focus = LocalFocusManager.current
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) voice.start() else voice.permissionDenied()
    }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, voice, writable, draft) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) {
                voice.suspendMedia()
                if (writable) model.autosaveNote(draft)
            }
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            voice.suspendMedia()
        }
    }
    LaunchedEffect(draft, draft.dirty, draft.title, draft.text, draft.richText, draft.folder, draft.pinned, writable) {
        if (writable && draft.original != null && draft.dirty) {
            delay(650)
            model.autosaveNote(draft)
        }
    }
    var folders by remember { mutableStateOf(false) }
    var confirmTrash by rememberSaveable { mutableStateOf(false) }
    var confirmTextCopy by rememberSaveable { mutableStateOf(false) }
    var confirmDiscard by rememberSaveable { mutableStateOf(false) }
    val currentFolder = library.folders.firstOrNull { noteFolder(it.id) == draft.folder }
    val finish = {
        if (!draft.saving) {
            when {
                recording -> voice.stop()
                draft.persisting && original != null -> model.saveNote(draft)
                !draft.dirty && (original != null || voice.clip == null) -> model.closeNote()
                original == null || !writable -> confirmDiscard = true
                else -> model.saveNote(draft)
            }
        }
    }
    BackHandler(onBack = finish)
    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                title = { Text(stringResource(if (original == null) R.string.new_note else R.string.note)) },
                navigationIcon = { ActionIcon(R.drawable.ic_back, R.string.back, enabled = !draft.saving, onClick = finish) },
            )
        },
        bottomBar = {
            if (removed) {
                EditorBottomAction(R.string.note_restore, enabled) {
                    draft.trashed = false
                    model.saveNote(draft)
                }
            } else if (original == null) {
                EditorBottomAction(R.string.save, editing && !draft.transcribing && hasContent) {
                    if (voice.clip != null && draft.title.isBlank() && draft.text.isBlank()) {
                        draft.title = defaultVoiceTitle
                    }
                    model.saveNote(draft)
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.TopCenter) {
            Column(
                Modifier.widthIn(max = 720.dp).fillMaxWidth().verticalScroll(rememberScrollState())
                    .padding(start = 20.dp, top = 12.dp, end = 20.dp, bottom = 20.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                draft.error?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Box {
                        TextButton(onClick = { folders = true }, enabled = editing && library.folders.isNotEmpty()) {
                            Glyph(R.drawable.ic_folder)
                            Text(currentFolder?.text("name") ?: stringResource(R.string.note_missing_folder),
                                Modifier.padding(start = 8.dp))
                        }
                        DropdownMenu(expanded = folders, onDismissRequest = { folders = false }) {
                            DropdownMenuItem(text = { Text(stringResource(R.string.note_missing_folder)) }, onClick = {
                                draft.folder = NOTE_WITHOUT_FOLDER
                                folders = false
                            })
                            library.folders.forEach { folder ->
                                DropdownMenuItem(text = { Text(folder.text("name").orEmpty()) }, onClick = {
                                    draft.folder = noteFolder(folder.id)
                                    folders = false
                                })
                            }
                        }
                    }
                    PlannerTextField(
                        draft.title, { draft.title = it }, Modifier.fillMaxWidth().focusOnEntry(original == null),
                        placeholder = R.string.note_title, enabled = !draft.saving, readOnly = !editing,
                        textStyle = MaterialTheme.typography.headlineSmall,
                    )
                }
                if (!removed) Row(verticalAlignment = Alignment.CenterVertically) {
                    if (voice.clip == null) {
                        ActionIcon(R.drawable.ic_waveform, R.string.voice_start, enabled = editing) {
                            focus.clearFocus()
                            if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                                PackageManager.PERMISSION_GRANTED) voice.start()
                            else permission.launch(Manifest.permission.RECORD_AUDIO)
                        }
                    }
                    if (original != null) {
                        ActionIcon(
                            R.drawable.ic_pin, if (draft.pinned) R.string.note_unpin else R.string.note_pin,
                            tint = if (draft.pinned) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                            enabled = editing,
                        ) { draft.pinned = !draft.pinned }
                        ActionIcon(R.drawable.ic_assistant, R.string.open_context_chat, enabled = editing && !draft.transcribing) {
                            if (draft.dirty || draft.persisting) model.saveNote(draft, done = openChat)
                            else {
                                model.closeNote()
                                openChat(original.id)
                            }
                        }
                        if (formatted) {
                            ActionIcon(R.drawable.ic_edit, R.string.note_edit_text, enabled = editing && !draft.transcribing) {
                                confirmTextCopy = true
                            }
                        }
                        ActionIcon(R.drawable.ic_delete, R.string.note_move_to_trash, enabled = editing) { confirmTrash = true }
                    }
                }
                if (formatted) {
                    Text(stringResource(R.string.note_formatted_preview), style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 16.dp))
                }
                val voiceCard: @Composable () -> Unit = {
                    if (!removed) {
                        NoteVoiceControls(draft, model, editable = editing && !formatted && (!sharedEditor || sharedFormat))
                    }
                }
                if (sharedEditor) {
                    SharedNoteEditor(draft, editable = editing && sharedFormat, beforeBody = voiceCard)
                } else {
                    voiceCard()
                    if (formatted || removed) {
                        SelectionContainer {
                            Text(draft.text.replace("\uFFFC", ""), Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                        }
                    } else {
                        PlannerTextField(draft.text, { draft.text = it }, Modifier.fillMaxWidth(), placeholder = R.string.note_text,
                            minLines = 4, enabled = !draft.saving, readOnly = !editing)
                    }
                }
            }
        }
    }
    if (confirmTrash) {
        Confirm(R.string.note_move_to_trash, R.string.note_move_to_trash_hint, R.string.note_move_to_trash,
            { confirmTrash = false }) {
            confirmTrash = false
            draft.trashed = true
            model.saveNote(draft)
        }
    }
    if (confirmTextCopy) {
        Confirm(R.string.note_edit_text, R.string.note_edit_text_hint, R.string.note_create_text_copy,
            { confirmTextCopy = false }) {
            confirmTextCopy = false
            model.copyNoteAsText(draft)
        }
    }
    if (confirmDiscard) {
        Confirm(R.string.discard_title, R.string.discard_hint, R.string.discard, { confirmDiscard = false }, model::closeNote)
    }
}
