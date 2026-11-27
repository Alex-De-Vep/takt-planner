package local.planner.android

import android.app.Application
import android.os.Build
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.google.gson.JsonElement
import com.google.gson.JsonNull
import com.google.gson.JsonPrimitive
import java.time.LocalDate
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

internal enum class AccountAction { SignIn, RequestCode, ConfirmCode }

internal data class AccountActionKey(val origin: String, val email: String, val action: AccountAction)

internal data class AccountLimit(val retryAt: Long = 0, val attemptsRemaining: Int? = null)

internal data class CloudState(
    val savedProfile: Profile? = null,
    val firstSyncPending: Boolean = false,
    val needsLibrary: Boolean = false,
    val closing: Boolean = false,
    val busy: Boolean = false,
    val message: Int? = null,
    val syncRetryAt: Long = 0,
    val accountLimits: Map<AccountActionKey, AccountLimit> = emptyMap(),
)

internal class PlannerModel(application: Application) : AndroidViewModel(application) {
    private val store = PlannerStore(application)
    private val noteStore = NoteStore(application)
    private val sync = CloudSync(store, noteStore)
    private val network = Mutex()
    private var nextSync = 0L
    private var failures = 0
    private var draft: TaskDraft? = null

    val library = store.library
    val notes = noteStore.state
    val noteVoice = NoteVoice(application)
    var noteDraft by mutableStateOf<NoteDraft?>(null)
        private set
    private var openingNote = false
    val chat = ChatController(application, viewModelScope)
    private val _cloud = MutableStateFlow(CloudState())
    val cloud = _cloud.asStateFlow()
    private val _ready = MutableStateFlow(false)
    val ready = _ready.asStateFlow()
    private val _error = MutableStateFlow<Int?>(null)
    val error = _error.asStateFlow()

    init {
        viewModelScope.launch {
            while (true) {
                delay(60_000)
                withContext(Dispatchers.IO) { runCatching { noteStore.publish() } }
            }
        }
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { store.load() }
                loadConnection()
                withContext(Dispatchers.IO) { noteStore.open(library.value.workspace) }
                _ready.value = true
                if (cloud.value.firstSyncPending) firstSync() else refresh()
                library.collect {
                    chat.bind(it.workspace)
                    if (it.profile == null) {
                        draft = null
                        if (library.value.profile == null && noteDraft != null) closeNote()
                    }
                    withContext(Dispatchers.IO) { DeadlineReminders.update(getApplication(), it) }
                }
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                _error.value = R.string.storage_error
            }
        }
    }

    fun clearError() { _error.value = null }

    fun openDraft(library: Library, task: Entity?, section: String): TaskDraft {
        draft?.let { if (it.workspace == library.workspace && it.original?.id == task?.id) return it }
        val location = task?.let(library::location) ?: section.takeUnless { it == "today" || it == "all" } ?: "inbox"
        return TaskDraft(library.workspace, task, location, task?.focused ?: (section == "today")).also { draft = it }
    }

    fun closeDraft() { draft = null }

    fun refresh() = synchronize(manual = false)

    fun retrySync() = synchronize(manual = true)

    private fun synchronize(manual: Boolean) {
        val profile = library.value.profile ?: return
        val retryAt = if (manual) cloud.value.syncRetryAt else nextSync
        if (SystemClock.elapsedRealtime() < retryAt) return
        cloudAction(keepMessage = true) {
            sync.synchronize(profile)
        }
    }

    fun login(server: String, email: String, password: String) {
        val origin = origin(server) ?: return
        val key = AccountActionKey(origin, email.trim().lowercase(), AccountAction.SignIn)
        cloudAction(accountAction = { key }) { sync.login(origin, email, password, Build.MODEL.orEmpty()) }
    }

    fun requestCode(server: String, email: String, password: String, request: AccountRequest, done: (String) -> Unit) {
        val origin = origin(server) ?: return
        var challenge = ""
        val key = AccountActionKey(origin, email.trim().lowercase(), AccountAction.RequestCode)
        cloudAction(done = {
            recordAccountLimit(key, AccountLimit(retryAt = SystemClock.elapsedRealtime() + 60_000L))
            done(challenge)
        }, accountAction = { key }) { challenge = sync.challenge(origin, request, email, password) }
    }

    fun confirmCode(
        server: String, email: String, password: String, challenge: String, code: String,
        reset: Boolean, done: () -> Unit,
    ) {
        val origin = origin(server) ?: return
        val address = email.trim().lowercase()
        var action = AccountAction.ConfirmCode
        cloudAction(done, accountAction = { AccountActionKey(origin, address, action) }) {
            sync.confirm(origin, challenge, code, password, reset)
            if (!reset) {
                action = AccountAction.SignIn
                sync.login(origin, email, password, Build.MODEL.orEmpty(), initializeEmpty = true)
            }
        }
    }

    fun firstSync(initializeEmpty: Boolean = false) = cloudAction {
        val connection = store.connection() ?: return@cloudAction
        sync.firstSync(connection.profile, initializeEmpty || connection.initializeEmpty)
    }

    fun logout(profile: Profile) = cloudAction(closing = true) { sync.logout(profile) }

    suspend fun sendSupport(profile: Profile, submission: SupportSubmission): String = network.withLock {
        try {
            if (library.value.profile != profile) throw ServerFailure(401, "sign_in_required")
            withContext(Dispatchers.IO) { sync.sendSupport(profile, submission) }
        } catch (failure: ServerFailure) {
            if (failure.status == 401) loadConnection()
            throw failure
        }
    }

    fun clearCloudMessage() {
        _cloud.value = cloud.value.copy(message = null)
    }

    private fun origin(server: String): String? = runCatching { serverOrigin(server) }.getOrElse {
        _cloud.value = cloud.value.copy(message = R.string.server_address_error)
        null
    }

    private fun recordAccountLimit(key: AccountActionKey, limit: AccountLimit) {
        val moment = SystemClock.elapsedRealtime()
        val active = cloud.value.accountLimits.filterValues { it.retryAt > moment || it.attemptsRemaining != null }
        _cloud.value = cloud.value.copy(accountLimits = active + (key to limit))
    }

    private fun cloudAction(
        done: () -> Unit = {}, closing: Boolean = false, keepMessage: Boolean = false,
        accountAction: (() -> AccountActionKey)? = null, work: () -> Unit,
    ) {
        if (!network.tryLock()) return
        _cloud.value = cloud.value.copy(
            busy = true, closing = closing, message = cloud.value.message.takeIf { keepMessage },
        )
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { work() }
                nextSync = 0
                failures = 0
                _cloud.value = cloud.value.copy(message = null, syncRetryAt = 0)
                loadConnection()
                accountAction?.invoke()?.let { key ->
                    _cloud.value = cloud.value.copy(accountLimits = cloud.value.accountLimits - key)
                }
                done()
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                failures = (failures + 1).coerceAtMost(6)
                val serverFailure = failure as? ServerFailure
                val retryAfter = serverFailure?.retryAfter?.takeIf { it > 0 }
                nextSync = SystemClock.elapsedRealtime() + (retryAfter ?: (2L shl failures)).coerceIn(1, 900) * 1000
                loadConnection()
                val key = accountAction?.invoke()
                if (key != null) {
                    val retryAt = retryAfter?.let { SystemClock.elapsedRealtime() + it.coerceAtMost(86_400) * 1000 } ?: 0
                    recordAccountLimit(key, AccountLimit(retryAt, serverFailure?.attemptsRemaining))
                }
                _cloud.value = cloud.value.copy(
                    message = if (key != null && retryAfter != null && serverFailure?.status == 429) null else cloudError(failure),
                    needsLibrary = serverFailure?.code == "library_not_initialized",
                    syncRetryAt = if (retryAfter != null) nextSync else 0,
                )
            } finally {
                _cloud.value = cloud.value.copy(busy = false, closing = false)
                network.unlock()
            }
        }
    }

    private suspend fun loadConnection() {
        val connection = withContext(Dispatchers.IO) { store.connection() }
        _cloud.value = cloud.value.copy(
            savedProfile = connection?.profile,
            firstSyncPending = connection?.credential != null && library.value.profile == null,
            needsLibrary = false,
        )
    }

    private fun cloudError(failure: Exception): Int = when {
        failure is ServerFailure -> when (failure.code) {
            "sign_in_required", "unauthorized", "invalid_token", "invalid_refresh" -> R.string.sign_in_again
            "invalid_credentials" -> R.string.invalid_credentials
            "email_not_verified" -> R.string.email_not_verified
            "registration_closed" -> R.string.registration_closed
            "invalid_code" -> R.string.invalid_email_code
            "invalid_request" -> R.string.invalid_account_input
            "library_not_initialized" -> R.string.library_not_initialized
            "incompatible_protocol" -> R.string.incompatible_protocol
            "rate_limited", "busy" -> R.string.cloud_rate_limited
            else -> R.string.cloud_error
        }
        failure is java.io.IOException -> R.string.cloud_offline
        else -> R.string.cloud_error
    }

    fun openNote(id: String?, folderId: String?, recordOnOpen: Boolean = false, activeOnly: Boolean = false) {
        val current = library.value
        if (current.profile == null || noteDraft != null || openingNote) return
        openingNote = true
        viewModelScope.launch {
            try {
                val original = id?.let { withContext(Dispatchers.IO) { noteStore.read(current.workspace, it) } }
                if (library.value.workspace != current.workspace) return@launch
                if (id != null && (original == null || activeOnly && original.document.deletedAt != null)) {
                    _error.value = R.string.note_unavailable
                } else {
                    val draft = NoteDraft(
                        current.workspace, original, folderId?.let(::noteFolder), opensForRecording = id == null && recordOnOpen,
                    )
                    noteVoice.bind(draft.workspace, draft.id)
                    noteDraft = draft
                }
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                _error.value = R.string.storage_error
            } finally {
                openingNote = false
            }
        }
    }

    fun copyNoteAsText(source: NoteDraft) {
        if (noteDraft !== source || source.saving || source.transcribing || noteVoice.recording != null) return
        val openCopy = {
            val current = library.value
            if (current.profile != null && current.workspace == source.workspace) {
                val folder = source.folder.takeIf { selected -> current.folders.any { noteFolder(it.id) == selected } }
                val copy = NoteDraft(current.workspace, null, folder).apply {
                    title = source.title
                    text = source.text.replace("\uFFFC", "")
                }
                noteVoice.bind(copy.workspace, copy.id)
                noteDraft = copy
            }
        }
        if (source.dirty) saveNote(source) { openCopy() } else openCopy()
    }

    fun closeNote() {
        noteVoice.close(discard = noteDraft?.original == null)
        noteDraft = null
    }

    override fun onCleared() {
        noteVoice.suspendMedia()
        super.onCleared()
    }

    suspend fun noteChatContext(workspace: String, id: String): NoteChatContext? = withContext(Dispatchers.IO) {
        if (library.value.workspace != workspace) return@withContext null
        runCatching { noteStore.read(workspace, id) }.getOrNull()
            ?.takeIf { it.document.deletedAt == null }
            ?.chatContext(workspace)
    }

    fun applyNoteProposal(proposal: ChatNoteProposal, done: () -> Unit) {
        viewModelScope.launch {
            try {
                if (library.value.profile == null || library.value.workspace != proposal.note.workspace) {
                    throw StaleNoteProposal()
                }
                withContext(Dispatchers.IO) { noteStore.applyChatProposal(proposal) }
                chat.removeProposal(proposal.id)
                refresh()
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                _error.value = when (failure) {
                    is StaleNoteProposal -> R.string.chat_note_proposal_stale
                    is NoteTooLarge -> R.string.note_too_large
                    else -> R.string.storage_error
                }
            } finally {
                done()
            }
        }
    }

    fun createNoteFromChat(proposal: ChatNewNoteProposal) {
        val current = library.value
        val noteState = notes.value
        if (current.profile == null || noteState.workspace != current.workspace || noteState.limit == null) {
            _error.value = R.string.notes_unsupported
            return
        }
        if (!chat.beginCreation(current.workspace, proposal.id)) return
        val now = noteTime()
        val note = NoteDocument(
            proposal.id, NOTE_WITHOUT_FOLDER, title = proposal.title, text = proposal.body, createdAt = now, updatedAt = now,
            richText = SharedNoteText().takeIf { noteState.formatVersion >= NOTE_FORMAT_VERSION },
        )
        viewModelScope.launch {
            try {
                val saved = withContext(Dispatchers.IO) {
                    noteStore.read(current.workspace, note.id) ?: noteStore.save(current.workspace, null, note)
                }
                chat.finishCreation(current.workspace, proposal.id,
                    ChatCreatedItem(ChatCreatedKind.Note, saved.document.id, saved.document.title))
                if (library.value.workspace == current.workspace) refresh()
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                _error.value = if (failure is NoteTooLarge) R.string.note_too_large else R.string.storage_error
            } finally {
                chat.finishCreation(current.workspace, proposal.id, null)
            }
        }
    }

    fun transcribeNote(draft: NoteDraft, selection: TranscriptionSelection) {
        val clip = noteVoice.clip ?: return
        if (noteDraft !== draft || draft.transcribing || draft.workspace != library.value.workspace) return
        val attempt = draft.transcriptionAttempt?.takeIf { it.clip == clip && it.selection == selection }
            ?: VoiceTranscriptionAttempt(clip, selection).also { draft.transcriptionAttempt = it }
        draft.transcribing = true
        draft.transcript = null
        draft.transcriptionIssue = null
        viewModelScope.launch {
            var processingPart: Int? = null
            try {
                val result = chat.transcribeVoice(draft.workspace, attempt) { part, received ->
                    if (noteDraft !== draft) throw CancellationException()
                    draft.transcriptionPart = part
                    processingPart = part.takeIf { received == null }
                    if (received != null) attempt.completed.add(received)
                }
                if (noteDraft === draft) {
                    draft.transcriptionAttempt = null
                    draft.transcript = result.text.takeIf(String::isNotBlank)
                    if (draft.transcript == null) {
                        draft.transcriptionIssue = VoiceTranscriptionIssue(R.string.voice_transcript_empty)
                    }
                    if (result.cleanupFailed) draft.transcriptionCleanupFailed = true
                }
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                if (noteDraft === draft) {
                    draft.transcriptionIssue = VoiceTranscriptionIssue(voiceTranscriptionError(failure), processingPart)
                    if (failure is VoiceRemoteCleanupFailed || attempt.completed.any(VoiceTranscript::cleanupFailed)) {
                        draft.transcriptionCleanupFailed = true
                    }
                }
            } finally {
                draft.transcribing = false
                draft.transcriptionPart = null
            }
        }
    }

    suspend fun searchNotes(workspace: String, text: String): Set<String> = try {
        withContext(Dispatchers.IO) { noteStore.search(workspace, text) }
    } catch (failure: Exception) {
        if (failure is CancellationException) throw failure
        _error.value = R.string.storage_error
        emptySet()
    }

    fun autosaveNote(draft: NoteDraft) {
        if (draft.original != null && draft.dirty) saveNote(draft, closeAfterSave = false)
    }

    fun saveNote(draft: NoteDraft, closeAfterSave: Boolean = true, done: (String) -> Unit = {}) {
        val current = library.value
        if (noteDraft !== draft || draft.saving || noteVoice.recording != null ||
            current.workspace != draft.workspace || current.profile == null) return
        if (draft.persisting) {
            if (closeAfterSave || draft.afterPersist == null) {
                draft.afterPersist = {
                    if (closeAfterSave) saveNote(draft, done = done) else autosaveNote(draft)
                }
            }
            return
        }
        val baseline = draft.original
        val original = baseline?.document
        if (original != null && !draft.dirty) {
            if (closeAfterSave) {
                closeNote()
                done(original.id)
            }
            return
        }
        val folder = draft.folder
        if (folder != NOTE_WITHOUT_FOLDER && folder != original?.folder && current.folders.none { noteFolder(it.id) == folder }) {
            draft.error = R.string.note_choose_folder
            return
        }
        val now = noteTime()
        val richText = draft.richText ?: SharedNoteText().takeIf {
            original == null && notes.value.workspace == current.workspace && notes.value.formatVersion >= NOTE_FORMAT_VERSION
        }
        val note = (original ?: NoteDocument(draft.id, folder, createdAt = now)).copy(
            folder = folder, title = draft.title.trim(), text = draft.text, pinned = draft.pinned, richText = richText,
            updatedAt = now, deletedAt = if (draft.trashed) original?.deletedAt ?: now else null,
        )
        draft.persisting = true
        draft.saving = closeAfterSave
        draft.error = null
        viewModelScope.launch {
            try {
                val saved = withContext(Dispatchers.IO) { noteStore.save(current.workspace, baseline, note) }
                if (noteDraft === draft) {
                    if (closeAfterSave) {
                        noteVoice.close()
                        noteDraft = null
                    } else {
                        if (saved.document.id != draft.id) noteVoice.bind(draft.workspace, saved.document.id)
                        draft.acknowledge(saved)
                    }
                    done(saved.document.id)
                }
                refresh()
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                draft.error = if (failure is NoteTooLarge) R.string.note_too_large else R.string.storage_error
            } finally {
                draft.persisting = false
                draft.saving = false
                val followUp = draft.afterPersist
                draft.afterPersist = null
                if (noteDraft === draft) followUp?.invoke()
            }
        }
    }

    fun saveTask(
        draft: TaskDraft, done: (String) -> Unit, proposal: ChatProposal? = null, failed: () -> Unit = {},
        completion: Boolean? = null,
    ) {
        if (draft.saving || !finishChecklistEdit(draft) || !validText(draft.title, 16_384) || !validText(draft.description, 1_048_576) ||
            draft.newItems.any { !validText(it, 16_384) }) {
            failed()
            return
        }
        val current = library.value
        val original = draft.original
        val id = original?.id ?: proposal?.id ?: newId()
        val fields = mutableMapOf<String, JsonElement>()
        if (original == null) fields["createdAt"] = value(wireTime())
        if (original == null || draft.title != original.text("title").orEmpty()) fields["title"] = value(draft.title.trim())
        if (original == null || draft.description != original.text("description").orEmpty()) fields["description"] = value(draft.description)
        if (original == null || draft.location != draft.originalLocation) {
            val destination = draft.location.takeIf { it in listOf("inbox", "week", "month") ||
                current.folders.any { folder -> folder.id == it } } ?: "inbox"
            fields["placement"] = placement(destination)
        }
        if (draft.deadline != original?.deadline) fields["deadline"] = draft.deadline?.wire() ?: JsonNull.INSTANCE
        if (draft.focused != (original != null && draft.originalFocus)) fields["focusDay"] = value(FOCUS_MARK.takeIf { draft.focused })
        if (completion != null) fields["completedAt"] = value(wireTime().takeIf { completion })
        val items = current.items(id)
        val firstOrder = nextOrder(items)
        val edits = buildList {
            if (fields.isNotEmpty()) add(Edit(id, "task", if (original == null) "create" else "update", fields))
            items.forEach { item ->
                val title = draft.itemTitles[item.id]
                if (title != null && title != item.text("title")) {
                    add(Edit(item.id, item.type, "update", mapOf("title" to value(title))))
                }
            }
            draft.newItems.forEachIndexed { index, text ->
                add(checklistEdit(id, text.trim(), (firstOrder.toLong() + index).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()))
            }
        }
        draft.saving = true
        apply(edits, { done(id) }, failed = { draft.saving = false; failed() }, proposal = proposal)
    }

    fun applyChatProposal(proposal: ChatProposal, done: () -> Unit, failed: () -> Unit) {
        val current = library.value
        val original = current.tasks.firstOrNull { it.id == proposal.task?.id }
        if (current.profile == null || !proposal.matches(current)) {
            _error.value = R.string.chat_proposal_stale
            failed()
            return
        }
        val draft = TaskDraft(current.workspace, original, original?.let(current::location) ?: "inbox", original?.focused ?: false)
        proposal.title?.let { draft.title = it }
        proposal.description?.let { draft.description = it }
        draft.newItems = proposal.checklist
        if (original == null || proposal.clearDeadline || proposal.deadline != null) draft.deadline = proposal.deadline
        if (original == null) draft.focused = proposal.focused
        proposal.focusChange?.let { draft.focused = it }
        if (original == null && !chat.beginCreation(current.workspace, proposal.id)) {
            failed()
            return
        }
        if (original == null) {
            current.tasks.firstOrNull { it.id == proposal.id }?.let { saved ->
                chat.finishCreation(current.workspace, proposal.id,
                    ChatCreatedItem(ChatCreatedKind.Task, saved.id, saved.text("title").orEmpty()))
                done()
                return
            }
        }
        saveTask(draft, done = { id ->
            if (original == null) {
                chat.finishCreation(current.workspace, proposal.id, ChatCreatedItem(ChatCreatedKind.Task, id, draft.title.trim()))
            } else {
                chat.removeProposal(proposal.id)
            }
            done()
        }, proposal = proposal, failed = {
            chat.finishCreation(current.workspace, proposal.id, null)
            failed()
        }, completion = proposal.completion)
    }

    fun toggleFocus(task: Entity) = apply(listOf(Edit(task.id, "task", "update", mapOf(
        "focusDay" to value(FOCUS_MARK.takeUnless { task.focused }),
    ))))

    fun toggleCompletion(task: Entity) = apply(listOf(Edit(task.id, "task", "update", mapOf(
        "completedAt" to value(wireTime().takeUnless { task.completed }),
    ))))

    fun reorderFolders(workspace: String, ids: List<String>) {
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { store.reorderFolders(workspace, ids) }
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                _error.value = R.string.storage_error
            }
        }
    }

    fun folder(name: String, existing: Entity?, done: () -> Unit) {
        val text = name.trim()
        if (text.isEmpty() || text.codePointCount(0, text.length) > 80 || !validText(text, 320)) {
            _error.value = R.string.folder_name_error
            return
        }
        val fields = mutableMapOf("name" to value(text))
        if (existing == null) fields["sortOrder"] = JsonPrimitive(nextOrder(library.value.folders))
        apply(listOf(Edit(existing?.id ?: newId(), "folder", if (existing == null) "create" else "update", fields)), done)
    }

    fun finishChecklistEdit(draft: TaskDraft): Boolean {
        val edit = draft.checklistEdit ?: return true
        if (edit.hasChanges) {
            val title = edit.text.trim()
            if (!validText(title, 16_384)) return false
            when (val target = edit.target) {
                ChecklistTarget.Add -> draft.newItems = draft.newItems + title
                is ChecklistTarget.Saved -> draft.itemTitles = draft.itemTitles + (target.id to title)
                is ChecklistTarget.Draft -> draft.newItems = draft.newItems.mapIndexed { index, previous ->
                    if (index == target.index) title else previous
                }
            }
        }
        draft.checklistEdit = null
        return true
    }

    fun toggleItem(item: Entity) = apply(listOf(Edit(item.id, item.type, "update", mapOf(
        "isCompleted" to JsonPrimitive(!item.flag("isCompleted")),
    ))))

    fun remove(entity: Entity, done: () -> Unit = {}) =
        apply(listOf(Edit(entity.id, entity.type, "delete")), done)

    private fun checklistEdit(taskId: String, title: String, order: Int) = Edit(
        newId(), "checklistItem", "create", mapOf(
            "taskId" to value(taskId), "title" to value(title),
            "isCompleted" to JsonPrimitive(false), "sortOrder" to JsonPrimitive(order),
        ),
    )

    private fun validText(text: String, bytes: Int): Boolean {
        if ('\u0000' !in text && text.toByteArray().size <= bytes &&
            (bytes < 1_048_576 || value(text).toString().toByteArray().size <= MAX_BATCH_BYTES - 128 * 1024)) return true
        _error.value = R.string.text_limit
        return false
    }

    private fun nextOrder(items: List<Entity>) =
        ((items.maxOfOrNull { it.number("sortOrder") } ?: -1).toLong() + 1).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()

    private fun apply(
        edits: List<Edit>, done: () -> Unit = {}, failed: () -> Unit = {}, proposal: ChatProposal? = null,
    ) {
        val workspace = library.value.workspace
        viewModelScope.launch {
            try {
                if (edits.isNotEmpty()) withContext(Dispatchers.IO) {
                    store.edit(workspace, edits, sync.clockOffset, proposal)
                }
                done()
                refresh()
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                _error.value = if (failure is StaleChatProposal) R.string.chat_proposal_stale else R.string.storage_error
                failed()
            }
        }
    }
}

internal sealed interface ChecklistTarget {
    data object Add : ChecklistTarget
    data class Saved(val id: String) : ChecklistTarget
    data class Draft(val index: Int) : ChecklistTarget
}

internal data class ChecklistEdit(val target: ChecklistTarget, val initial: String, val text: String = initial) {
    val hasChanges get() = text.isNotBlank() && text.trim() != initial.trim()
}

internal class TaskDraft(
    val workspace: String, val original: Entity?, val originalLocation: String, val originalFocus: Boolean,
) {
    var title by mutableStateOf(original?.text("title").orEmpty())
    var description by mutableStateOf(original?.text("description").orEmpty())
    var location by mutableStateOf(originalLocation)
    var focused by mutableStateOf(originalFocus)
    var deadline by mutableStateOf(original?.deadline)
    var newItems by mutableStateOf(emptyList<String>())
    var itemTitles by mutableStateOf(emptyMap<String, String>())
    var checklistEdit by mutableStateOf<ChecklistEdit?>(null)
    var saving by mutableStateOf(false)

    val dirty get() = title != original?.text("title").orEmpty() || description != original?.text("description").orEmpty() ||
        location != originalLocation || focused != originalFocus || deadline != original?.deadline ||
        newItems.isNotEmpty() || itemTitles.isNotEmpty() || checklistEdit?.hasChanges == true
}

internal fun Entity.inSection(section: String, library: Library): Boolean = when (section) {
    "all" -> true
    "today" -> focused
    else -> library.location(this) == section
}

internal fun Deadline.agendaDate(): LocalDate = instant?.atZone(java.time.ZoneId.systemDefault())?.toLocalDate() ?: date
