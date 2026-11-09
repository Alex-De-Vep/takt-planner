package local.planner.android

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import androidx.core.database.sqlite.transaction
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal data class Connection(val profile: Profile, val credential: String?)

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
    fun load() = publish()

    @Synchronized
    fun deviceId(): String = writableDatabase.transaction {
        setting("device") ?: newId().also { setting("device", it) }
    }

    @Synchronized
    fun connection(): Connection? = readableDatabase.setting("connection")?.let {
        json.fromJson(it, Connection::class.java)
    }

    @Synchronized
    fun connect(profile: Profile, credential: String, snapshot: Snapshot) {
        writableDatabase.transaction {
            replaceSnapshot(profile.workspace, snapshot)
            setting("connection", json.toJson(Connection(profile, credential)))
            setting("active", profile.workspace)
        }
        publish()
    }

    @Synchronized
    fun credential(profile: Profile, credential: String?) {
        if (connection()?.profile != profile) return
        writableDatabase.setting("connection", json.toJson(Connection(profile, credential)))
    }

    @Synchronized
    fun useLocal() {
        writableDatabase.setting("active", LOCAL_WORKSPACE)
        publish()
    }

    @Synchronized
    fun useCloud(profile: Profile) {
        if (connection()?.profile != profile) return
        writableDatabase.setting("active", profile.workspace)
        publish()
    }

    @Synchronized
    fun edit(workspace: String, edits: List<Edit>, clockOffset: Long) {
        val displayed = _library.value
        check(displayed.workspace == workspace)
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
                    operationId, displayed.profile?.libraryId.orEmpty(), deviceId, edit.id, edit.type, edit.kind,
                    edit.fields.takeUnless { it.isEmpty() }?.mapValues { FieldChange(it.value, stamp) },
                    stamp.takeIf { edit.kind == "delete" },
                )
                if (workspace == LOCAL_WORKSPACE) {
                    val base = entity(workspace, edit.id)
                    mutation.overlay(base)?.let { saveEntity(workspace, it) }
                } else {
                    insertOrThrow("outbox", null, ContentValues().apply {
                        put("workspace", workspace)
                        put("id", operationId)
                        put("body", json.toJson(mutation))
                    })
                }
            }
            clock?.let { setting(clockKey, json.toJson(it)) }
        }
        publish()
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
            while (cursor.moveToNext()) add(json.fromJson(cursor.getString(0), Mutation::class.java))
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
        val workspace = db.setting("active") ?: LOCAL_WORKSPACE
        val profile = connection()?.profile?.takeIf { it.workspace == workspace }
        val current = db.query("entities", arrayOf("body"), "workspace = ?", arrayOf(workspace), null, null, null)
            .use { cursor -> buildMap {
                while (cursor.moveToNext()) {
                    val entity = json.fromJson(cursor.getString(0), Entity::class.java)
                    put(entity.id, entity)
                }
            }.toMutableMap() }
        var pending = 0
        var rejected = 0
        db.query("outbox", arrayOf("body", "error"), "workspace = ?", arrayOf(workspace), null, null, "sequence").use { cursor ->
            while (cursor.moveToNext()) {
                val mutation = json.fromJson(cursor.getString(0), Mutation::class.java)
                mutation.overlay(current[mutation.entityId])?.let { current[it.id] = it }
                if (cursor.isNull(1)) pending++ else rejected++
            }
        }
        _library.value = Library(workspace, profile, current.values.filterNot(Entity::deleted), pending, rejected)
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
    ).use { if (it.moveToFirst()) json.fromJson(it.getString(0), Entity::class.java) else null }

    private fun SQLiteDatabase.saveEntity(workspace: String, entity: Entity) {
        check(replaceOrThrow("entities", null, ContentValues().apply {
            put("workspace", workspace)
            put("id", entity.id)
            put("body", json.toJson(entity))
        }) != -1L)
    }

    private fun SQLiteDatabase.setting(key: String): String? = query(
        "settings", arrayOf("value"), "key = ?", arrayOf(key), null, null, null,
    ).use { if (it.moveToFirst()) it.getString(0) else null }

    private fun SQLiteDatabase.setting(key: String, value: String) {
        replaceOrThrow("settings", null, ContentValues().apply { put("key", key); put("value", value) })
    }
}
