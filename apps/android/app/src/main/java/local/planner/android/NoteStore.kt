package local.planner.android

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import androidx.core.database.sqlite.transaction
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal data class NotesState(
    val workspace: String = "",
    val loaded: Boolean = false,
    val limit: Int? = null,
    val formatVersion: Int = 0,
    val entries: List<NoteSummary> = emptyList(),
    val pending: Int = 0,
    val error: Int? = null,
    val conflicts: Int = 0,
)

internal data class PendingNote(val id: String, val data: ByteArray, val digest: String)
internal class NoteTooLarge : IllegalArgumentException()

internal class NoteStore(private val context: Context) : SQLiteOpenHelper(context, "notes.db", null, 2) {
    private val _state = MutableStateFlow(NotesState())
    val state = _state.asStateFlow()

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE notes (
                workspace TEXT NOT NULL, id TEXT NOT NULL, body BLOB NOT NULL,
                summary TEXT NOT NULL, search TEXT NOT NULL, revision TEXT, digest TEXT NOT NULL,
                PRIMARY KEY (workspace, id)
            )
        """.trimIndent())
        db.execSQL("CREATE TABLE note_config (workspace TEXT PRIMARY KEY, byte_limit INTEGER NOT NULL, format_version INTEGER NOT NULL DEFAULT 0)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        check(oldVersion == 1 && newVersion == 2)
        db.execSQL("ALTER TABLE note_config ADD COLUMN format_version INTEGER NOT NULL DEFAULT 0")
    }

    @Synchronized
    fun open(workspace: String) {
        if (_state.value.workspace == workspace) return
        _state.value = NotesState(workspace)
        if (workspace.isEmpty()) return
        try {
            val config = readableDatabase.rawQuery(
                "SELECT byte_limit, format_version FROM note_config WHERE workspace = ?", arrayOf(workspace),
            ).use { if (it.moveToFirst()) it.getInt(0) to it.getInt(1) else null }
            if (config != null) {
                _state.value = NotesState(workspace, loaded = true, limit = config.first, formatVersion = config.second)
                publish()
            }
        } catch (_: Exception) {
            _state.value = NotesState(workspace, error = R.string.storage_error)
        }
    }

    @Synchronized
    fun ready(workspace: String, limit: Int?, formatVersion: Int = 0) {
        check(_state.value.workspace == workspace)
        if (limit == null) {
            writableDatabase.delete("note_config", "workspace = ?", arrayOf(workspace))
        } else {
            writableDatabase.replaceOrThrow("note_config", null, ContentValues().apply {
                put("workspace", workspace)
                put("byte_limit", limit)
                put("format_version", formatVersion)
            })
        }
        _state.value = _state.value.copy(loaded = true, limit = limit, formatVersion = formatVersion)
        publish()
    }

    @Synchronized
    fun syncError(workspace: String, error: Int?) {
        if (_state.value.workspace == workspace) _state.value = _state.value.copy(error = error)
    }

    @Synchronized
    fun search(workspace: String, text: String): Set<String> = readableDatabase.rawQuery(
        "SELECT id FROM notes WHERE workspace = ? AND instr(search, ?) > 0",
        arrayOf(workspace, text.lowercase()),
    ).use { cursor -> buildSet { while (cursor.moveToNext()) add(cursor.getString(0)) } }

    @Synchronized
    fun read(workspace: String, id: String): StoredNote? {
        val db = readableDatabase
        val version = db.version(workspace, id) ?: return null
        val note = decodeNote(db.body(workspace, id), id)
        return StoredNote(note, version.digest).takeUnless { note.purged || noteTrashExpired(note.deletedAt) }
    }

    @Synchronized
    fun save(workspace: String, original: StoredNote?, note: NoteDocument): StoredNote {
        val limit = _state.value.takeIf { it.workspace == workspace }?.limit ?: error("Notes unavailable")
        val saved = writableDatabase.transaction {
            val current = version(workspace, note.id)
            val existing = current?.let { decodeNote(body(workspace, note.id), note.id) }
            check(existing == null || (!existing.purged && !noteTrashExpired(existing.deletedAt)))
            val conflict = current?.digest != original?.digest
            val next = if (conflict) note.copy(id = newId()) else note
            next.richText?.validate(next.text)
            val bytes = next.wireBytes()
            if (bytes.size > limit) throw NoteTooLarge()
            val digest = noteDigest(bytes)
            write(workspace, next, bytes, if (conflict) null else current?.revision, digest)
            StoredNote(next, digest)
        }
        if (saved.document.id != note.id) _state.value = _state.value.copy(conflicts = _state.value.conflicts + 1)
        publish()
        return saved
    }

    @Synchronized
    fun applyChatProposal(proposal: ChatNoteProposal) {
        val workspace = proposal.note.workspace
        val config = _state.value.takeIf { it.workspace == workspace } ?: throw StaleNoteProposal()
        val limit = config.limit ?: throw StaleNoteProposal()
        writableDatabase.transaction {
            val current = version(workspace, proposal.note.noteId) ?: throw StaleNoteProposal()
            val original = StoredNote(decodeNote(body(workspace, proposal.note.noteId), proposal.note.noteId), current.digest)
            val next = original.withChatText(proposal)
            check(next.richText == null || config.formatVersion >= NOTE_FORMAT_VERSION)
            val bytes = next.wireBytes()
            if (bytes.size > limit) throw NoteTooLarge()
            write(workspace, next, bytes, current.revision, noteDigest(bytes))
        }
        publish()
    }

    @Synchronized
    fun revisions(workspace: String): Map<String, String?> = readableDatabase.rawQuery(
        "SELECT id, revision FROM notes WHERE workspace = ?", arrayOf(workspace),
    ).use { cursor -> buildMap { while (cursor.moveToNext()) put(cursor.getString(0), cursor.getString(1)) } }

    @Synchronized
    fun receive(workspace: String, id: String, revision: String, bytes: ByteArray) {
        check(noteDigest(bytes) == revision)
        val received = decodeNote(bytes, id)
        val incoming = if (received.purged || noteTrashExpired(received.deletedAt)) received.withoutContent() else received
        val incomingBytes = if (incoming == received) bytes else incoming.wireBytes()
        val incomingDigest = if (incoming == received) revision else noteDigest(incomingBytes)
        val copied = writableDatabase.transaction {
            val current = version(workspace, id)
            if (current?.digest == revision) {
                setRevision(workspace, id, revision)
                return@transaction false
            }
            val local = current?.takeIf { it.digest != it.revision }?.let { decodeNote(body(workspace, id), id) }
            val conflict = local != null && !local.purged && !incoming.purged
            if (conflict) {
                val copy = local.copy(id = newId())
                val copyBytes = copy.wireBytes()
                write(workspace, copy, copyBytes, null, noteDigest(copyBytes))
            }
            write(workspace, incoming, incomingBytes, revision, incomingDigest)
            conflict
        }
        if (incoming.purged) discardAudio(workspace, id)
        if (copied) _state.value = _state.value.copy(conflicts = _state.value.conflicts + 1)
    }

    @Synchronized
    fun pending(workspace: String): List<String> = readableDatabase.rawQuery(
        "SELECT id FROM notes WHERE workspace = ? AND (revision IS NULL OR revision != digest) ORDER BY id",
        arrayOf(workspace),
    ).use { cursor -> buildList { while (cursor.moveToNext()) add(cursor.getString(0)) } }

    @Synchronized
    fun pending(workspace: String, id: String): PendingNote? {
        val db = readableDatabase
        val version = db.version(workspace, id) ?: return null
        if (version.revision == version.digest) return null
        return PendingNote(id, db.body(workspace, id), version.digest)
    }

    @Synchronized
    fun acknowledge(workspace: String, id: String, revision: String) {
        writableDatabase.setRevision(workspace, id, revision)
    }

    @Synchronized
    fun publish() {
        val current = _state.value
        if (!current.loaded || current.limit == null) return
        val entries = readableDatabase.rawQuery(
            "SELECT summary FROM notes WHERE workspace = ?", arrayOf(current.workspace),
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) add(json.fromJson(cursor.getString(0), NoteSummary::class.java))
            }
        }
        val expired = entries.filter { !it.purged && noteTrashExpired(it.deletedAt) }
        if (expired.isNotEmpty()) {
            writableDatabase.transaction {
                for (entry in expired) {
                    val revision = version(current.workspace, entry.id)?.revision
                    val note = decodeNote(body(current.workspace, entry.id), entry.id).withoutContent()
                    val bytes = note.wireBytes()
                    write(current.workspace, note, bytes, revision, noteDigest(bytes))
                }
            }
            for (entry in expired) discardAudio(current.workspace, entry.id)
        }
        _state.value = current.copy(entries = entries.filter { !it.purged && !noteTrashExpired(it.deletedAt) },
            pending = pending(current.workspace).size)
    }

    private fun discardAudio(workspace: String, id: String) {
        noteAudioFile(context, workspace, id).let { file ->
            file.delete()
            File(file.parentFile, "${file.nameWithoutExtension}.part.m4a").delete()
        }
    }

    private data class Version(val revision: String?, val digest: String)

    private fun SQLiteDatabase.version(workspace: String, id: String): Version? = rawQuery(
        "SELECT revision, digest FROM notes WHERE workspace = ? AND id = ?", arrayOf(workspace, id),
    ).use { if (it.moveToFirst()) Version(it.getString(0), it.getString(1)) else null }

    private fun SQLiteDatabase.body(workspace: String, id: String): ByteArray {
        val size = rawQuery("SELECT length(body) FROM notes WHERE workspace = ? AND id = ?", arrayOf(workspace, id))
            .use { check(it.moveToFirst()); it.getInt(0) }
        // A valid note with attachments can exceed Android's CursorWindow capacity.
        val result = ByteArray(size)
        var offset = 0
        while (offset < size) {
            val chunk = rawQuery(
                "SELECT substr(body, ?, 262144) FROM notes WHERE workspace = ? AND id = ?",
                arrayOf((offset + 1).toString(), workspace, id),
            ).use { check(it.moveToFirst()); it.getBlob(0) }
            check(chunk.isNotEmpty())
            chunk.copyInto(result, offset)
            offset += chunk.size
        }
        return result
    }

    private fun SQLiteDatabase.write(
        workspace: String, note: NoteDocument, bytes: ByteArray, revision: String?, digest: String,
    ) {
        replaceOrThrow("notes", null, ContentValues().apply {
            put("workspace", workspace)
            put("id", note.id)
            put("body", bytes)
            put("summary", json.toJson(note.summary.copy(digest = digest)))
            put("search", note.title.lowercase() + "\n" + note.text.lowercase())
            put("revision", revision)
            put("digest", digest)
        })
    }

    private fun SQLiteDatabase.setRevision(workspace: String, id: String, revision: String) {
        update("notes", ContentValues().apply { put("revision", revision) }, "workspace = ? AND id = ?", arrayOf(workspace, id))
    }
}
