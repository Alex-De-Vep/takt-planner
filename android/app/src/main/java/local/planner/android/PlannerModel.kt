package local.planner.android

import android.app.Application
import android.os.Build
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
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
    val requiresLogin: Boolean = false,
    val busy: Boolean = false,
    val message: Int? = null,
)

internal class PlannerModel(application: Application) : AndroidViewModel(application) {
    private val store = PlannerStore(application)
    private val sync = CloudSync(store)
    private val network = Mutex()
    private var nextSync = 0L
    private var failures = 0

    val library = store.library
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
                refresh()
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                _error.value = R.string.storage_error
            }
        }
    }

    fun clearError() { _error.value = null }

    fun refresh() {
        val profile = library.value.profile ?: return
        if (cloud.value.requiresLogin || System.currentTimeMillis() < nextSync) return
        cloudAction {
            sync.synchronize(profile)
        }
    }

    fun login(server: String, email: String, password: String, done: () -> Unit) {
        val origin = runCatching { serverOrigin(server) }.getOrElse {
            _cloud.value = cloud.value.copy(message = R.string.server_address_error)
            return
        }
        if (email.isBlank() || password.isBlank()) {
            _cloud.value = cloud.value.copy(message = R.string.sign_in_fields)
            return
        }
        cloudAction(done) {
            sync.login(origin, email, password, Build.MODEL.orEmpty())
        }
    }

    fun local() = cloudAction { store.useLocal() }
    fun online(profile: Profile) = cloudAction { store.useCloud(profile) }
    fun logout(profile: Profile) = cloudAction { sync.logout(profile) }

    private fun cloudAction(done: () -> Unit = {}, work: () -> Unit) {
        if (!network.tryLock()) return
        _cloud.value = cloud.value.copy(busy = true, message = null)
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
                _cloud.value = cloud.value.copy(message = cloudError(failure))
            } finally {
                _cloud.value = cloud.value.copy(busy = false)
                network.unlock()
            }
        }
    }

    private suspend fun loadConnection() {
        val connection = withContext(Dispatchers.IO) { store.connection() }
        _cloud.value = cloud.value.copy(
            savedProfile = connection?.profile,
            requiresLogin = connection != null && connection.credential == null,
        )
    }

    private fun cloudError(failure: Exception): Int = when {
        failure is ServerFailure -> when (failure.code) {
            "sign_in_required", "unauthorized", "invalid_token", "invalid_refresh" -> R.string.sign_in_again
            "invalid_credentials" -> R.string.invalid_credentials
            "email_not_verified" -> R.string.email_not_verified
            "library_not_initialized" -> R.string.library_not_initialized
            "incompatible_protocol" -> R.string.incompatible_protocol
            "rate_limited", "busy" -> R.string.cloud_rate_limited
            else -> R.string.cloud_error
        }
        failure is java.io.IOException -> R.string.cloud_offline
        else -> R.string.cloud_error
    }

    fun saveTask(
        original: Entity?, originalLocation: String, title: String, description: String, location: String,
        focused: Boolean, deadline: Deadline?, newItems: List<String>, done: () -> Unit,
    ) {
        if (!validText(title, 16_384) || !validText(description, 1_048_576) ||
            newItems.any { !validText(it, 16_384) }) return
        val current = library.value
        val id = original?.id ?: newId()
        val fields = mutableMapOf(
            "title" to value(title.trim()), "description" to value(description),
            "placement" to placement(location), "deadline" to (deadline?.wire() ?: JsonNull.INSTANCE),
        )
        if (original == null) fields["createdAt"] = value(wireTime())
        if (focused != (original?.focused ?: false)) fields["focusDay"] = value(FOCUS_MARK.takeIf { focused })
        if (original != null) {
            if (location == originalLocation) fields.remove("placement")
            if (title == original.text("title").orEmpty()) fields.remove("title")
            if (deadline == original.deadline) fields.remove("deadline")
            if (description == original.text("description").orEmpty()) fields.remove("description")
            fields.entries.removeAll { (key, value) ->
                (original.fields[key] ?: JsonNull.INSTANCE) == value
            }
        }
        val firstOrder = nextOrder(current.items(id))
        val edits = buildList {
            if (fields.isNotEmpty()) add(Edit(id, "task", if (original == null) "create" else "update", fields))
            newItems.forEachIndexed { index, text ->
                add(checklistEdit(id, text.trim(), (firstOrder.toLong() + index).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()))
            }
        }
        apply(edits, done)
    }

    fun toggleFocus(task: Entity) = apply(listOf(Edit(task.id, "task", "update", mapOf(
        "focusDay" to value(FOCUS_MARK.takeUnless { task.focused }),
    ))))

    fun toggleCompletion(task: Entity) = apply(listOf(Edit(task.id, "task", "update", mapOf(
        "completedAt" to value(wireTime().takeUnless { task.completed }),
    ))))

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

    fun addItem(task: Entity, title: String, done: () -> Unit) {
        if (!validText(title, 16_384)) return
        apply(listOf(checklistEdit(task.id, title.trim(), nextOrder(library.value.items(task.id)))), done)
    }

    fun updateItem(item: Entity, title: String, done: () -> Unit) {
        if (!validText(title, 16_384)) return
        apply(listOf(Edit(item.id, item.type, "update", mapOf("title" to value(title.trim())))), done)
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
        if ('\u0000' !in text && text.toByteArray().size <= bytes) return true
        _error.value = R.string.text_limit
        return false
    }

    private fun nextOrder(items: List<Entity>) =
        ((items.maxOfOrNull { it.number("sortOrder") } ?: -1).toLong() + 1).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()

    private fun apply(edits: List<Edit>, done: () -> Unit = {}) {
        val workspace = library.value.workspace
        viewModelScope.launch {
            try {
                if (edits.isNotEmpty()) withContext(Dispatchers.IO) {
                    store.edit(workspace, edits, if (workspace == LOCAL_WORKSPACE) 0 else sync.clockOffset)
                }
                done()
                refresh()
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                _error.value = R.string.storage_error
            }
        }
    }
}

internal fun Entity.inSection(section: String, library: Library): Boolean = when (section) {
    "all" -> true
    "today" -> focused
    else -> library.location(this) == section
}

internal fun Deadline.agendaDate(): LocalDate = instant?.atZone(java.time.ZoneId.systemDefault())?.toLocalDate() ?: date
