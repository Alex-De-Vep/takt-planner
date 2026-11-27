package local.planner.android

import com.google.gson.JsonObject
import com.google.gson.JsonPrimitive
import java.time.Duration
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.temporal.ChronoUnit

internal data class ChatEventProposal(
    val original: PhoneEvent?, val title: String, val description: String, val location: String,
    val start: String, val end: String, val zoneId: String, val allDay: Boolean,
    val id: String = newId(),
)

internal fun PhoneEvent.chatContext(defaultZone: ZoneId): JsonObject {
    val zone = chatZone(defaultZone)
    val start = startsIn(zone)
    val end = endsIn(zone)
    return payload(
        "title" to value(title.take(500)), "description" to value(description.take(12_000)),
        "location" to value(location.take(500)), "time_zone" to value(zone.id),
        "start" to value(if (allDay) start.toLocalDate().toString() else start.toString()),
        "end" to value(if (allDay) end.toLocalDate().minusDays(1).toString() else end.toString()),
        "allDay" to JsonPrimitive(allDay), "editable" to JsonPrimitive(editable && !recurring),
    )
}

private fun PhoneEvent.chatZone(defaultZone: ZoneId): ZoneId =
    if (allDay) ZoneOffset.UTC else runCatching { ZoneId.of(zoneId) }.getOrDefault(defaultZone)

internal fun proposedEvent(fields: JsonObject, original: PhoneEvent?, defaultZone: ZoneId): ChatEventProposal? {
    if (original != null && (!original.editable || original.recurring)) return null
    val zone = original?.takeUnless { it.allDay }?.chatZone(defaultZone) ?: defaultZone
    val allDay = fields.boolean("allDay") ?: original?.allDay ?: false
    val title = (fields.string("title")?.trim() ?: original?.title)
        ?.takeIf { it.isNotBlank() && it.length <= 500 && '\u0000' !in it } ?: return null
    val description = fields.string("description")?.take(12_000) ?: original?.description.orEmpty()
    val location = fields.string("location")?.take(500) ?: original?.location.orEmpty()
    if ('\u0000' in description || '\u0000' in location) return null
    val unchangedMode = original?.allDay == allDay
    val oldStart = original?.startsIn(zone)
    val oldEnd = original?.endsIn(zone)?.let { if (original.allDay) it.minusDays(1) else it }
    // Some providers use the shared action date/time fields for new calendar events.
    val suppliedStart = fields.string("start") ?: fields.string("date")?.takeIf { original == null }?.let { date ->
        if (allDay) date else fields.string("time")?.let { time -> "${date}T$time" } ?: return null
    }
    val start = readEventDate(suppliedStart, allDay, oldStart.takeIf { unchangedMode }) ?: return null
    val inferredEnd = when {
        unchangedMode && oldStart != null && oldEnd != null -> {
            if (allDay) start.plusDays(ChronoUnit.DAYS.between(oldStart.toLocalDate(), oldEnd.toLocalDate()))
            else start.plus(Duration.between(oldStart, oldEnd))
        }
        allDay -> start
        else -> start.plusHours(1)
    }
    val end = readEventDate(fields.string("end"), allDay, inferredEnd) ?: return null
    if (end.year !in 1..9999) return null
    if (allDay) {
        if (end < start) return null
    } else {
        val first = eventTime(start, zone, original?.start?.takeIf { unchangedMode }) ?: return null
        val last = eventTime(end, zone, original?.end?.takeIf { unchangedMode }) ?: return null
        if (last <= first) return null
    }
    if (original != null && unchangedMode && title == original.title && description == original.description &&
        location == original.location && start == oldStart && end == oldEnd) return null
    return ChatEventProposal(
        original, title, description, location, start.toString(), end.toString(), if (allDay) "UTC" else zone.id, allDay,
    )
}

private fun readEventDate(value: String?, allDay: Boolean, fallback: LocalDateTime?): LocalDateTime? {
    if (value == null) return fallback
    return runCatching {
        if (allDay) LocalDate.parse(value).atStartOfDay() else LocalDateTime.parse(value)
    }.getOrNull()?.takeIf { it.year in 1..9999 }
}
