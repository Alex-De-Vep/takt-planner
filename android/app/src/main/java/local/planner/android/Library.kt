package local.planner.android

import com.google.gson.GsonBuilder
import com.google.gson.JsonElement
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.google.gson.JsonPrimitive
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

internal const val FOCUS_MARK = "9999-12-31"
internal const val LOCAL_WORKSPACE = "local"
internal val json = GsonBuilder().disableHtmlEscaping().serializeNulls().create()

internal fun newId() = UUID.randomUUID().toString()
internal fun wireTime() = Instant.ofEpochMilli(System.currentTimeMillis()).toString()
internal fun value(text: String?) = text?.let(::JsonPrimitive) ?: JsonNull.INSTANCE
internal fun payload(vararg entries: Pair<String, JsonElement>) = JsonObject().apply {
    entries.forEach { (key, item) -> add(key, item) }
}

internal data class Stamp(
    val physicalMillis: Long,
    val logicalCounter: Int,
    val deviceId: String,
    val operationId: String,
) : Comparable<Stamp> {
    override fun compareTo(other: Stamp) = compareValuesBy(
        this, other, Stamp::physicalMillis, Stamp::logicalCounter, Stamp::deviceId, Stamp::operationId,
    )
}

internal data class Entity(
    val id: String,
    val type: String,
    val fields: Map<String, JsonElement> = emptyMap(),
    val versions: Map<String, Stamp> = emptyMap(),
    val deleted: Boolean = false,
    val revision: String = "0",
) {
    fun text(key: String): String? = fields[key]?.takeUnless { it.isJsonNull }?.asString
    fun number(key: String) = fields[key]?.asInt ?: 0
    fun flag(key: String) = fields[key]?.asBoolean ?: false
    val placement: String
        get() {
            val field = fields["placement"]?.asJsonObject ?: return "inbox"
            return field["folderId"]?.asString ?: field["kind"].asString
        }
    val focused: Boolean
        get() = text("focusDay") in setOf(FOCUS_MARK, LocalDate.now().toString())
    val completed: Boolean get() = text("completedAt") != null
    val deadline: Deadline? get() = fields["deadline"]?.takeUnless { it.isJsonNull }?.let(Deadline::read)
}

internal data class Deadline(val date: LocalDate, val instant: Instant?, val zone: ZoneId) {
    fun wire(): JsonElement = payload(
        "timeZoneId" to value(zone.id),
        "includesTime" to JsonPrimitive(instant != null),
        (if (instant == null) "date" to value(date.toString()) else "instant" to value(instant.toString())),
    )

    companion object {
        fun read(element: JsonElement): Deadline {
            val field = element.asJsonObject
            val zone = ZoneId.of(field["timeZoneId"].asString)
            val instant = field["instant"]?.asString?.let(Instant::parse)
            val date = instant?.atZone(zone)?.toLocalDate() ?: LocalDate.parse(field["date"].asString)
            return Deadline(date, instant, zone)
        }
    }
}

internal fun placement(key: String): JsonObject = when (key) {
    "today", "all", "inbox" -> payload("kind" to value("inbox"))
    "week", "month" -> payload("kind" to value(key))
    else -> payload("kind" to value("folder"), "folderId" to value(key))
}

internal data class FieldChange(val value: JsonElement, val version: Stamp)

internal data class Mutation(
    val operationId: String,
    val libraryId: String,
    val deviceId: String,
    val entityId: String,
    val entityType: String,
    val kind: String,
    val changes: Map<String, FieldChange>? = null,
    val deleteVersion: Stamp? = null,
) {
    fun wire(): JsonObject = json.toJsonTree(this).asJsonObject.apply {
        if (changes == null) remove("changes")
        if (deleteVersion == null) remove("deleteVersion")
    }

    fun overlay(base: Entity?): Entity? {
        if (base?.deleted == true) return base
        if (base == null && kind == "update") return null
        val current = base ?: Entity(entityId, entityType)
        if (kind == "delete") return current.copy(deleted = true)
        val winning = changes.orEmpty().filter { (name, field) ->
            current.versions[name]?.let { field.version > it } ?: true
        }
        return current.copy(
            fields = current.fields + winning.mapValues { it.value.value },
            versions = current.versions + winning.mapValues { it.value.version },
        )
    }
}

internal data class Edit(
    val id: String,
    val type: String,
    val kind: String,
    val fields: Map<String, JsonElement> = emptyMap(),
)

internal data class Profile(val origin: String, val email: String, val libraryId: String, val workspace: String)

internal data class Library(
    val workspace: String = LOCAL_WORKSPACE,
    val profile: Profile? = null,
    val entities: List<Entity> = emptyList(),
    val pending: Int = 0,
    val rejected: Int = 0,
) {
    val folders get() = entities.filter { it.type == "folder" }.sortedWith(compareBy({ it.number("sortOrder") }, { it.id }))
    val tasks get() = entities.filter { it.type == "task" }.sortedByDescending { it.text("createdAt")?.let(Instant::parse) }

    fun items(taskId: String) = entities.filter { it.type == "checklistItem" && it.text("taskId") == taskId }
        .sortedWith(compareBy({ it.number("sortOrder") }, { it.id }))

    fun location(task: Entity) = task.placement.takeIf { key ->
        key in listOf("inbox", "week", "month") || folders.any { it.id == key }
    } ?: "inbox"
}
