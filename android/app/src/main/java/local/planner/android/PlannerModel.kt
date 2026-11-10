package local.planner.android

import android.app.Application
import android.os.Build
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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext

internal data class CloudState(
    val savedProfile: Profile? = null,
    val firstSyncPending: Boolean = false,
    val needsLibrary: Boolean = false,
    val closing: Boolean = false,
    val busy: Boolean = false,
    val message: Int? = null,
)

internal class PlannerModel(application: Application) : AndroidViewModel(application) {
    private val store = PlannerStore(application)
    private val sync = CloudSync(store)
    private val network = Mutex()
    private var nextSync = 0L
    private var failures = 0
    private var draft: TaskDraft? = null

    val library = store.library
    val chat = ChatController(application, viewModelScope)
    private val _cloud = MutableStateFlow(CloudState())
    val cloud = _cloud.asStateFlow()
    private val _ready = MutableStateFlow(false)
    val ready = _ready.asStateFlow()
    private val _error = MutableStateFlow<Int?>(null)
    val error = _error.asStateFlow()

    init {
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { store.load() }
                loadConnection()
                _ready.value = true
                if (cloud.value.firstSyncPending) firstSync() else refresh()
                library.collect {
                    chat.bind(it.workspace)
                    if (it.profile == null) draft = null
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

    fun refresh() {
        val profile = library.value.profile ?: return
        if (System.currentTimeMillis() < nextSync) return
        cloudAction {
            sync.synchronize(profile)
        }
    }

    fun login(server: String, email: String, password: String) {
        val origin = origin(server) ?: return
        cloudAction { sync.login(origin, email, password, Build.MODEL.orEmpty()) }
    }

    fun requestCode(server: String, email: String, password: String, request: AccountRequest, done: (String) -> Unit) {
        val origin = origin(server) ?: return
        var challenge = ""
        cloudAction({ done(challenge) }) { challenge = sync.challenge(origin, request, email, password) }
    }

    fun confirmCode(
        server: String, email: String, password: String, challenge: String, code: String,
        reset: Boolean, done: () -> Unit,
    ) {
        val origin = origin(server) ?: return
        cloudAction(done) {
            sync.confirm(origin, challenge, code, password, reset)
            if (!reset) sync.login(origin, email, password, Build.MODEL.orEmpty(), initializeEmpty = true)
        }
    }

    fun firstSync(initializeEmpty: Boolean = false) = cloudAction {
        val connection = store.connection() ?: return@cloudAction
        sync.firstSync(connection.profile, initializeEmpty || connection.initializeEmpty)
    }

    fun logout(profile: Profile) = cloudAction(closing = true) { sync.logout(profile) }

    fun clearCloudMessage() {
        _cloud.value = cloud.value.copy(message = null)
    }

    private fun origin(server: String): String? = runCatching { serverOrigin(server) }.getOrElse {
        _cloud.value = cloud.value.copy(message = R.string.server_address_error)
        null
    }

    private fun cloudAction(done: () -> Unit = {}, closing: Boolean = false, work: () -> Unit) {
        if (!network.tryLock()) return
        _cloud.value = cloud.value.copy(busy = true, closing = closing, message = null)
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { work() }
                nextSync = 0
                failures = 0
                loadConnection()
                done()
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                failures = (failures + 1).coerceAtMost(6)
                val delay = (failure as? ServerFailure)?.retryAfter ?: (2L shl failures)
                nextSync = System.currentTimeMillis() + delay.coerceIn(1, 900) * 1000
                loadConnection()
                _cloud.value = cloud.value.copy(
                    message = cloudError(failure),
                    needsLibrary = (failure as? ServerFailure)?.code == "library_not_initialized",
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

    fun saveTask(
        draft: TaskDraft, done: () -> Unit, proposal: ChatProposal? = null, failed: () -> Unit = {},
        completion: Boolean? = null,
    ) {
        if (draft.saving || !finishChecklistEdit(draft) || !validText(draft.title, 16_384) || !validText(draft.description, 1_048_576) ||
            draft.newItems.any { !validText(it, 16_384) }) {
            failed()
            return
        }
        val current = library.value
        val original = draft.original
        val id = original?.id ?: newId()
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
        apply(edits, done, failed = { draft.saving = false; failed() }, proposal = proposal)
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
        if (original == null) {
            draft.deadline = proposal.deadline
            draft.focused = proposal.focused
        }
        saveTask(draft, done, proposal, failed)
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
