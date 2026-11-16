package local.planner.android

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.google.gson.JsonObject
import com.google.gson.JsonPrimitive
import java.security.MessageDigest
import java.time.Instant
import java.util.Base64
import java.util.Locale
import java.util.UUID

// Foundation's default Codable dates count seconds from 2001-01-01T00:00:00Z.
private const val FOUNDATION_EPOCH = 978_307_200L
internal const val NOTE_WITHOUT_FOLDER = "inbox"
internal const val MAX_NOTE_BYTES = 8 * 1024 * 1024

internal fun noteTime() = (System.currentTimeMillis() - FOUNDATION_EPOCH * 1000) / 1000.0
internal fun noteInstant(time: Double) = Instant.ofEpochMilli((time * 1000).toLong() + FOUNDATION_EPOCH * 1000)

internal fun noteFolder(id: String) = "folder-${UUID.fromString(id).toString().uppercase(Locale.ROOT)}"

internal data class NoteDocument(
    val id: String,
    val folder: String,
    val title: String = "",
    val text: String = "",
    val document: String = "",
    val pinned: Boolean = false,
    val createdAt: Double = noteTime(),
    val updatedAt: Double = createdAt,
    val deletedAt: Double? = null,
) {
    val summary get() = NoteSummary(
        id, folder.takeIf { it.startsWith("folder-") }?.removePrefix("folder-")?.lowercase(Locale.ROOT),
        title.take(256), text.take(512).replace("\uFFFC", ""), pinned, updatedAt, deletedAt,
    )
}

internal data class NoteSummary(
    val id: String,
    val folderId: String?,
    val title: String,
    val preview: String,
    val pinned: Boolean,
    val updatedAt: Double,
    val deletedAt: Double?,
    val digest: String = "",
)

internal data class StoredNote(val document: NoteDocument, val digest: String)

internal fun NoteDocument.wireBytes(): ByteArray = payload(
    "id" to value(id),
    "title" to value(title),
    "folder" to value(folder),
    "text" to value(text),
    "document" to value(document),
    "pinned" to JsonPrimitive(pinned),
    "createdAt" to JsonPrimitive(createdAt),
    "updatedAt" to JsonPrimitive(updatedAt),
).apply { deletedAt?.let { addProperty("deletedAt", it) } }.toString().toByteArray()

internal fun decodeNote(bytes: ByteArray, id: String): NoteDocument {
    val body = json.fromJson(bytes.toString(Charsets.UTF_8), JsonObject::class.java)
    check(body.getAsJsonPrimitive("id").asString.equals(id, ignoreCase = true))
    val document = body.getAsJsonPrimitive("document").asString
    if (document.isNotEmpty()) Base64.getDecoder().decode(document)
    return NoteDocument(
        id, body.getAsJsonPrimitive("folder").asString, body.getAsJsonPrimitive("title").asString,
        body.getAsJsonPrimitive("text").asString, document, body.getAsJsonPrimitive("pinned").asBoolean,
        body.getAsJsonPrimitive("createdAt").asDouble, body.getAsJsonPrimitive("updatedAt").asDouble,
        body.get("deletedAt")?.takeUnless { it.isJsonNull }?.asDouble,
    ).also {
        check(it.createdAt.isFinite() && it.updatedAt.isFinite() && it.deletedAt?.isFinite() != false)
    }
}

internal fun noteDigest(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }


internal class NoteDraft(
    val workspace: String,
    val original: StoredNote?,
    initialFolder: String?,
) {
    private val note = original?.document
    val id = note?.id ?: newId()
    var folder by mutableStateOf(note?.folder ?: initialFolder ?: NOTE_WITHOUT_FOLDER)
    var title by mutableStateOf(note?.title.orEmpty())
    var text by mutableStateOf(note?.text.orEmpty())
    var pinned by mutableStateOf(note?.pinned ?: false)
    var trashed by mutableStateOf(note?.deletedAt != null)
    var saving by mutableStateOf(false)
    var transcribing by mutableStateOf(false)
    var transcript by mutableStateOf<String?>(null)
    var transcriptionError by mutableStateOf<Int?>(null)
    var error by mutableStateOf<Int?>(null)

    val dirty get() = title != note?.title.orEmpty() || text != note?.text.orEmpty() ||
        (note != null && (folder != note.folder || pinned != note.pinned || trashed != (note.deletedAt != null)))
}
