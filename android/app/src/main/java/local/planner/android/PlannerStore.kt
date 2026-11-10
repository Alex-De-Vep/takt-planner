package local.planner.android

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import androidx.core.database.sqlite.transaction
import java.io.ByteArrayOutputStream
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal data class Connection(
    val profile: Profile,
    val credential: String?,
    val refreshing: Boolean = false,
    val initializeEmpty: Boolean = false,
)

internal class PlannerStore(context: Context) : SQLiteOpenHelper(context, "planner.db", null, 1) {
    private val _library = MutableStateFlow(Library())
    val library = _library.asStateFlow()

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        db.execSQL("CREATE TABLE entities (workspace TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY (workspace, id))")
        db.execSQL(
            """CREATE TABLE outbox (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT, workspace TEXT NOT NULL,
                id TEXT NOT NULL UNIQUE, body TEXT NOT NULL, error TEXT
            )""",
        )
        db.execSQL("CREATE INDEX workspace_queue ON outbox (workspace, sequence)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = error("Unsupported schema")

    @Synchronized
    fun load() {
        val interrupted = connection()?.takeIf(Connection::refreshing)
        if (interrupted == null) publish() else disconnect(interrupted.profile)
    }

    @Synchronized
    fun deviceId(): String = writableDatabase.transaction {
        setting("device") ?: newId().also { setting("device", it) }
    }

    @Synchronized
    fun connection(): Connection? = readableDatabase.setting("connection")?.let {
        json.fromJson(it, Connection::class.java)
    }

    @Synchronized
    fun beginConnection(connection: Connection) {
        writableDatabase.transaction {
            setting("connection", json.toJson(connection))
            delete("settings", "key = ?", arrayOf("active"))
        }
        publish()
    }

    @Synchronized
    fun activate(profile: Profile, snapshot: Snapshot) {
        check(connection()?.profile == profile)
        writableDatabase.transaction {
            replaceSnapshot(profile.workspace, snapshot)
            setting("active", profile.workspace)
        }
        publish()
    }

    @Synchronized
    fun credential(profile: Profile, credential: String, refreshing: Boolean = false) {
        val current = connection()?.takeIf { it.profile == profile } ?: return
        writableDatabase.setting("connection", json.toJson(current.copy(credential = credential, refreshing = refreshing)))
    }

    @Synchronized
    fun disconnect(profile: Profile) {
        val current = connection()?.takeIf { it.profile == profile } ?: return
        writableDatabase.transaction {
            setting("connection", json.toJson(current.copy(credential = null, refreshing = false)))
            delete("settings", "key = ?", arrayOf("active"))
        }
        publish()
    }

    @Synchronized
    fun edit(workspace: String, edits: List<Edit>, clockOffset: Long, proposal: ChatProposal? = null) {
        val displayed = _library.value
        val profile = checkNotNull(displayed.profile)
        check(profile.workspace == workspace)
        if (proposal != null && !proposal.matches(displayed)) throw StaleChatProposal()
        val deviceId = deviceId()
        writableDatabase.transaction {
            val clockKey = "clock:$workspace"
            var clock = setting(clockKey)?.let { json.fromJson(it, Stamp::class.java) }
            for (edit in edits) {
                val operationId = newId()
                val previous = clock
                val now = (System.currentTimeMillis() + clockOffset).coerceAtLeast(0)
                val physical = maxOf(now, previous?.physicalMillis ?: 0)
                val logical = if (previous?.physicalMillis == physical) previous.logicalCounter + 1 else 0
                val stamp = Stamp(physical, logical, deviceId, operationId)
                clock = stamp
                val mutation = Mutation(
                    operationId, profile.libraryId, deviceId, edit.id, edit.type, edit.kind,
                    edit.fields.takeUnless { it.isEmpty() }?.mapValues { FieldChange(it.value, stamp) },
                    stamp.takeIf { edit.kind == "delete" },
                )
                insertOrThrow("outbox", null, ContentValues().apply {
                    put("workspace", workspace)
                    put("id", operationId)
                    putBody(json.toJson(mutation))
                })
            }
            clock?.let { setting(clockKey, json.toJson(it)) }
        }
        publish()
    }

    @Synchronized
    fun reorderFolders(workspace: String, requested: List<String>) {
        val current = _library.value
        check(current.profile?.workspace == workspace)
        val available = current.folders.map(Entity::id)
        val order = mergeFolderOrder(requested, available)
        if (order == available) return
        writableDatabase.setting("folderOrder:$workspace", json.toJson(order))
        _library.value = current.copy(folderOrder = order)
    }

    @Synchronized
    fun cursor(workspace: String): String? = readableDatabase.setting("cursor:$workspace")

    @Synchronized
    fun snapshot(workspace: String, snapshot: Snapshot) {
        writableDatabase.transaction { replaceSnapshot(workspace, snapshot) }
        publish()
    }

    @Synchronized
    fun changes(workspace: String, entities: List<Entity>, cursor: String) {
        writableDatabase.transaction {
            entities.forEach { receive(workspace, it) }
            setting("cursor:$workspace", cursor)
        }
        publish()
    }

    @Synchronized
    fun batch(workspace: String): List<Mutation> {
        val queued = readableDatabase.query(
            "outbox", arrayOf("body"), "workspace = ? AND error IS NULL", arrayOf(workspace),
            null, null, "sequence", "100",
        ).use { cursor -> buildList {
            while (cursor.moveToNext()) add(json.fromJson(cursor.body(), Mutation::class.java))
        } }
        return mutationBatch(queued)
    }

    @Synchronized
    fun accept(workspace: String, results: List<MutationResult>) {
        writableDatabase.transaction {
            results.forEach { result ->
                if (result.status == "rejected") {
                    update("outbox", ContentValues().apply { put("error", result.error?.code ?: "rejected") },
                        "workspace = ? AND id = ?", arrayOf(workspace, result.operationId))
                } else {
                    receive(workspace, requireNotNull(result.entity))
                    delete("outbox", "workspace = ? AND id = ?", arrayOf(workspace, result.operationId))
                }
            }
        }
        publish()
    }

    private fun publish() {
        val db = readableDatabase
        val workspace = db.setting("active")
        val profile = connection()?.takeIf { it.credential != null && it.profile.workspace == workspace }?.profile
        if (profile == null || workspace == null || db.setting("cursor:$workspace") == null) {
            _library.value = Library()
            return
        }
        val current = db.query("entities", arrayOf("body"), "workspace = ?", arrayOf(workspace), null, null, null)
            .use { cursor -> buildMap {
                while (cursor.moveToNext()) {
                    val entity = json.fromJson(cursor.body(), Entity::class.java)
                    put(entity.id, entity)
                }
            }.toMutableMap() }
        var pending = 0
        var rejected = 0
        db.query("outbox", arrayOf("body", "error"), "workspace = ?", arrayOf(workspace), null, null, "sequence").use { cursor ->
            while (cursor.moveToNext()) {
                val mutation = json.fromJson(cursor.body(), Mutation::class.java)
                mutation.overlay(current[mutation.entityId])?.let { current[it.id] = it }
                if (cursor.isNull(1)) pending++ else rejected++
            }
        }
        val folderOrder = db.setting("folderOrder:$workspace")?.let {
            json.fromJson(it, Array<String>::class.java).toList()
        }.orEmpty()
        _library.value = Library(workspace, profile, current.values.filterNot(Entity::deleted), pending, rejected, folderOrder)
    }

    private fun SQLiteDatabase.replaceSnapshot(workspace: String, snapshot: Snapshot) {
        delete("entities", "workspace = ?", arrayOf(workspace))
        snapshot.entities.forEach { receive(workspace, it) }
        setting("cursor:$workspace", snapshot.cursor)
    }

    private fun SQLiteDatabase.receive(workspace: String, incoming: Entity) {
        val existing = entity(workspace, incoming.id)
        if (existing != null && existing.revision.toLong() >= incoming.revision.toLong()) return
        saveEntity(workspace, incoming)
        val key = "clock:$workspace"
        val latest = incoming.versions.values.maxOrNull() ?: return
        val previous = setting(key)?.let { json.fromJson(it, Stamp::class.java) }
        if (previous == null || latest > previous) setting(key, json.toJson(latest))
    }

    private fun SQLiteDatabase.entity(workspace: String, id: String): Entity? = query(
        "entities", arrayOf("body"), "workspace = ? AND id = ?", arrayOf(workspace, id), null, null, null,
    ).use { if (it.moveToFirst()) json.fromJson(it.body(), Entity::class.java) else null }

    private fun SQLiteDatabase.saveEntity(workspace: String, entity: Entity) {
        check(replaceOrThrow("entities", null, ContentValues().apply {
            put("workspace", workspace)
            put("id", entity.id)
            putBody(json.toJson(entity))
        }) != -1L)
    }

    // Крупный JSON хранится сжато, чтобы строка помещалась в окно SQLite CursorWindow.
    private fun ContentValues.putBody(body: String) {
        val bytes = body.toByteArray()
        if (bytes.size < 64 * 1024) {
            put("body", body)
        } else {
            val output = ByteArrayOutputStream()
            GZIPOutputStream(output).use { it.write(bytes) }
            put("body", output.toByteArray())
        }
    }

    private fun Cursor.body(): String = if (getType(0) == Cursor.FIELD_TYPE_BLOB) {
        GZIPInputStream(getBlob(0).inputStream()).bufferedReader(Charsets.UTF_8).use { it.readText() }
    } else {
        getString(0)
    }

    private fun SQLiteDatabase.setting(key: String): String? = query(
        "settings", arrayOf("value"), "key = ?", arrayOf(key), null, null, null,
    ).use { if (it.moveToFirst()) it.getString(0) else null }

    private fun SQLiteDatabase.setting(key: String, value: String) {
        replaceOrThrow("settings", null, ContentValues().apply { put("key", key); put("value", value) })
    }
}
