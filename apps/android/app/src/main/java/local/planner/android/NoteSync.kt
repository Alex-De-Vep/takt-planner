package local.planner.android

import com.google.gson.JsonNull
import com.google.gson.JsonObject
import java.util.Base64
import java.util.UUID

private val revisionPattern = Regex("[0-9a-f]{64}")

internal class NoteSync(private val store: NoteStore) {
    fun synchronize(
        workspace: String,
        limit: Int,
        formatVersion: Int,
        request: (path: String, body: JsonObject?, responseLimit: Int) -> JsonObject,
    ) {
        val responseLimit = (limit + 2) / 3 * 4 + 1024
        val index = request("/v1/notes", null, 2 * 1024 * 1024)
        val remote = mutableMapOf<String, String>()
        for (entry in index.getAsJsonArray("notes")) {
            val row = entry.asJsonObject
            val id = UUID.fromString(row.getAsJsonPrimitive("id").asString).toString()
            val revision = row.getAsJsonPrimitive("revision").asString
            check(revisionPattern.matches(revision) && remote.put(id, revision) == null)
        }
        val known = store.revisions(workspace)
        for ((id, revision) in remote) {
            if (known[id] == revision) continue
            val response = request("/v1/notes/$id", null, responseLimit)
            val data = Base64.getDecoder().decode(response.getAsJsonPrimitive("data").asString)
            val downloadedRevision = response.getAsJsonPrimitive("revision").asString
            check(data.isNotEmpty() && data.size <= limit)
            store.receive(workspace, id, downloadedRevision, data)
            // The note may have changed between the index and its download.
            remote[id] = downloadedRevision
        }
        store.ready(workspace, limit, formatVersion)

        var error: Int? = null
        for (id in store.pending(workspace)) {
            val pending = store.pending(workspace, id) ?: continue
            if (formatVersion < NOTE_FORMAT_VERSION && decodeNote(pending.data, id).richText != null) {
                error = R.string.notes_format_unsupported
                continue
            }
            if (pending.data.size > limit) {
                error = R.string.note_too_large
                continue
            }
            val body = payload(
                "baseRevision" to (remote[id]?.let(::value) ?: JsonNull.INSTANCE),
                "data" to value(Base64.getEncoder().encodeToString(pending.data)),
            )
            try {
                val receipt = request("/v1/notes/$id", body, 1024)
                check(receipt.getAsJsonPrimitive("revision").asString == pending.digest)
                store.acknowledge(workspace, id, pending.digest)
            } catch (failure: ServerFailure) {
                when {
                    failure.code == "note_conflict" -> continue
                    failure.code == "note_quota" -> error = R.string.note_quota
                    failure.status == 413 -> error = R.string.note_too_large
                    else -> throw failure
                }
            }
        }
        store.syncError(workspace, error)
    }
}
