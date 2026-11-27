package local.planner.android

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import androidx.core.database.sqlite.transaction
import com.google.gson.JsonDeserializer
import com.google.gson.JsonSerializer

internal data class ChatAttachment(val taskId: String? = null, val noteId: String? = null, val eventId: Long? = null)

internal data class ChatThreadSummary(val id: String, val title: String?)

internal data class ChatThreadContent(
    val attachment: ChatAttachment = ChatAttachment(),
    val questions: List<ChatQuestion> = emptyList(),
    val proposals: List<ChatProposal> = emptyList(),
    val noteProposal: ChatNoteProposal? = null,
    val eventProposals: List<ChatEventProposal> = emptyList(),
    val newNotes: List<ChatNewNoteProposal> = emptyList(),
)

internal data class StoredChatThread(
    val id: String, val threads: List<ChatThreadSummary>, val lines: List<ChatLine>, val content: ChatThreadContent,
)

internal val chatHistoryJson = json.newBuilder()
    .registerTypeAdapter(Deadline::class.java, JsonSerializer<Deadline> { value, _, _ -> value.wire() })
    .registerTypeAdapter(Deadline::class.java, JsonDeserializer<Deadline> { value, _, _ -> Deadline.read(value) })
    .create()

internal fun chatThreadTitle(text: String): String =
    text.trim().lineSequence().firstOrNull().orEmpty().take(60).trimEnd { it.isHighSurrogate() }.trimEnd()

internal class ChatHistoryStore(context: Context) : SQLiteOpenHelper(context, "chat_history.db", null, 1) {
    override fun onConfigure(db: SQLiteDatabase) {
        db.setForeignKeyConstraintsEnabled(true)
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE threads (
                workspace TEXT NOT NULL, id TEXT NOT NULL, title TEXT, updated INTEGER NOT NULL, content TEXT NOT NULL,
                PRIMARY KEY (workspace, id)
            )
        """.trimIndent())
        db.execSQL("""
            CREATE TABLE messages (
                workspace TEXT NOT NULL, thread TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL,
                PRIMARY KEY (workspace, thread, id),
                FOREIGN KEY (workspace, thread) REFERENCES threads (workspace, id) ON DELETE CASCADE
            )
        """.trimIndent())
        db.execSQL("""
            CREATE TABLE selected (
                workspace TEXT PRIMARY KEY, thread TEXT NOT NULL,
                FOREIGN KEY (workspace, thread) REFERENCES threads (workspace, id) ON DELETE CASCADE
            )
        """.trimIndent())
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = error("Unsupported chat history version")

    fun open(workspace: String): StoredChatThread = writableDatabase.transaction {
        val current = rawQuery("SELECT thread FROM selected WHERE workspace = ?", arrayOf(workspace)).use {
            if (it.moveToFirst()) it.getString(0) else null
        }
        val id = current ?: createThread(workspace)
        readThread(workspace, id)
    }

    fun newThread(workspace: String, clear: Boolean = false): StoredChatThread = writableDatabase.transaction {
        if (clear) delete("threads", "workspace = ?", arrayOf(workspace))
        readThread(workspace, createThread(workspace))
    }

    fun selectThread(workspace: String, id: String): StoredChatThread = writableDatabase.transaction {
        val thread = readThread(workspace, id)
        select(workspace, id)
        thread
    }

    fun save(workspace: String, id: String, content: ChatThreadContent, messages: List<ChatLine>, newTitle: String? = null): List<ChatThreadSummary> =
        writableDatabase.transaction {
            val values = ContentValues().apply {
                put("content", chatHistoryJson.toJson(content))
                if (newTitle != null) put("title", newTitle)
                if (messages.isNotEmpty()) put("updated", System.currentTimeMillis())
            }
            check(update("threads", values, "workspace = ? AND id = ?", arrayOf(workspace, id)) == 1)
            messages.forEach { line ->
                val body = ContentValues().apply { put("body", json.toJson(line)) }
                if (update("messages", body, "workspace = ? AND thread = ? AND id = ?", arrayOf(workspace, id, line.id)) == 0) {
                    body.put("workspace", workspace)
                    body.put("thread", id)
                    body.put("id", line.id)
                    insertOrThrow("messages", null, body)
                }
            }
            summaries(workspace)
        }

    private fun SQLiteDatabase.createThread(workspace: String): String {
        val id = newId()
        insertOrThrow("threads", null, ContentValues().apply {
            put("workspace", workspace)
            put("id", id)
            put("updated", System.currentTimeMillis())
            put("content", chatHistoryJson.toJson(ChatThreadContent()))
        })
        select(workspace, id)
        return id
    }

    private fun SQLiteDatabase.select(workspace: String, id: String) {
        check(replaceOrThrow("selected", null, ContentValues().apply {
            put("workspace", workspace)
            put("thread", id)
        }) != -1L)
    }

    private fun SQLiteDatabase.readThread(workspace: String, id: String): StoredChatThread {
        val content = buildString {
            // A thread can contain large task drafts. Read the JSON in pieces that fit a cursor window.
            val chunkSize = 128 * 1024
            var offset = 1
            do {
                val chunk = rawQuery(
                    "SELECT substr(content, ?, ?) FROM threads WHERE workspace = ? AND id = ?",
                    arrayOf(offset.toString(), chunkSize.toString(), workspace, id),
                ).use { cursor ->
                    check(cursor.moveToFirst())
                    cursor.getString(0)
                }
                append(chunk)
                offset += chunkSize
            } while (chunk.codePointCount(0, chunk.length) == chunkSize)
        }
        val lines = rawQuery("SELECT body FROM messages WHERE workspace = ? AND thread = ? ORDER BY rowid",
            arrayOf(workspace, id)).use {
            buildList { while (it.moveToNext()) add(json.fromJson(it.getString(0), ChatLine::class.java)) }
        }
        return StoredChatThread(id, summaries(workspace), lines, chatHistoryJson.fromJson(content, ChatThreadContent::class.java))
    }

    private fun SQLiteDatabase.summaries(workspace: String): List<ChatThreadSummary> =
        rawQuery("SELECT id, title FROM threads WHERE workspace = ? ORDER BY updated DESC, rowid DESC", arrayOf(workspace)).use {
            buildList { while (it.moveToNext()) add(ChatThreadSummary(it.getString(0), it.getString(1))) }
        }
}
