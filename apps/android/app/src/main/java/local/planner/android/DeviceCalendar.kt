package local.planner.android

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.provider.CalendarContract
import android.provider.CalendarContract.Calendars
import android.provider.CalendarContract.Events
import android.provider.CalendarContract.Instances
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset

internal data class PhoneCalendar(val id: Long, val name: String, val account: String, val writable: Boolean)

internal data class PhoneEvent(
    val id: Long, val calendarId: Long, val title: String, val description: String, val location: String,
    val start: Long, val end: Long, val zoneId: String, val allDay: Boolean, val recurring: Boolean,
    val editable: Boolean,
) {
    fun startsIn(zone: ZoneId): LocalDateTime = localTime(start, zone)
    fun endsIn(zone: ZoneId): LocalDateTime = localTime(end, zone)
    private fun localTime(millis: Long, zone: ZoneId) =
        Instant.ofEpochMilli(millis).atZone(if (allDay) ZoneOffset.UTC else zone).toLocalDateTime()

    fun occursOn(day: LocalDate, zone: ZoneId): Boolean {
        val displayZone = if (allDay) ZoneOffset.UTC else zone
        val startOfDay = day.atStartOfDay(displayZone).toInstant().toEpochMilli()
        val nextDay = day.plusDays(1).atStartOfDay(displayZone).toInstant().toEpochMilli()
        return start < nextDay && maxOf(start + 1, end) > startOfDay
    }
}

internal data class EventRequest(
    val event: PhoneEvent? = null, val suggestedStart: Long? = null,
)

internal data class EventValues(
    val calendarId: Long, val title: String, val description: String, val location: String,
    val start: Long, val end: Long, val zoneId: String, val allDay: Boolean,
)

internal class DeviceCalendar(private val context: Context, private val workspace: String) {
    private val resolver = context.contentResolver
    private val preferences = context.getSharedPreferences("calendar_selection", Context.MODE_PRIVATE)

    fun mayRead() = granted(Manifest.permission.READ_CALENDAR)
    fun mayWrite() = granted(Manifest.permission.WRITE_CALENDAR)
    private fun granted(permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    fun selection(calendars: List<PhoneCalendar>): Set<Long> =
        preferences.getStringSet(workspace, null)?.mapNotNull(String::toLongOrNull)?.toSet()
            ?: calendars.mapTo(mutableSetOf(), PhoneCalendar::id)

    fun select(ids: Set<Long>) {
        preferences.edit { putStringSet(workspace, ids.mapTo(mutableSetOf(), Long::toString)) }
    }

    private val creationKey get() = "creation:$workspace"

    fun preferredCreationCalendar(): Long? = preferences.getLong(creationKey, -1L).takeUnless { it == -1L }

    fun setCreationCalendar(id: Long?) {
        preferences.edit { if (id == null) remove(creationKey) else putLong(creationKey, id) }
    }

    fun creationCalendar(writable: List<PhoneCalendar>): PhoneCalendar? {
        val preferred = preferredCreationCalendar()
        return writable.firstOrNull { it.id == preferred } ?: writable.firstOrNull()
    }

    fun calendars(): List<PhoneCalendar> {
        val columns = arrayOf(Calendars._ID, Calendars.CALENDAR_DISPLAY_NAME, Calendars.ACCOUNT_NAME, Calendars.CALENDAR_ACCESS_LEVEL)
        return resolver.query(Calendars.CONTENT_URI, columns, "${Calendars.VISIBLE} = 1", null,
            "${Calendars.CALENDAR_DISPLAY_NAME} COLLATE NOCASE").rows {
            PhoneCalendar(getLong(0), getString(1).orEmpty(), getString(2).orEmpty(),
                getInt(3) >= Calendars.CAL_ACCESS_CONTRIBUTOR)
        }
    }

    fun events(from: LocalDate, until: LocalDate, zone: ZoneId, ids: Set<Long>): List<PhoneEvent> {
        if (ids.isEmpty()) return emptyList()
        val uri = Instances.CONTENT_URI.buildUpon().apply {
            ContentUris.appendId(this, from.minusDays(1).atStartOfDay(zone).toInstant().toEpochMilli())
            ContentUris.appendId(this, until.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli())
        }.build()
        val columns = arrayOf(Instances.EVENT_ID, Instances.BEGIN, Instances.END) + eventColumns
        return resolver.query(uri, columns, "${Events.DELETED} = 0 AND COALESCE(${Events.STATUS}, 0) != ?",
            arrayOf(Events.STATUS_CANCELED.toString()), "${Instances.BEGIN} ASC").rows {
            event(getLong(0), getLong(1), getLong(2), 3)
        }.filter { it.calendarId in ids }.distinctBy { it.id to it.start }
    }

    fun save(original: PhoneEvent?, values: EventValues) {
        check(mayRead() && mayWrite())
        require(values.title.isNotBlank() && values.end > values.start)
        check(calendars().any { it.id == values.calendarId && it.writable })
        val body = ContentValues().apply {
            put(Events.TITLE, values.title)
            put(Events.DESCRIPTION, values.description)
            put(Events.EVENT_LOCATION, values.location)
            put(Events.DTSTART, values.start)
            put(Events.DTEND, values.end)
            put(Events.EVENT_TIMEZONE, values.zoneId)
            put(Events.EVENT_END_TIMEZONE, values.zoneId)
            put(Events.ALL_DAY, if (values.allDay) 1 else 0)
        }
        if (original == null) {
            body.put(Events.CALENDAR_ID, values.calendarId)
            checkNotNull(resolver.insert(Events.CONTENT_URI, body))
        } else {
            check(values.calendarId == original.calendarId)
            val uri = unchangedEvent(original)
            check(resolver.update(uri, body, null, null) == 1)
        }
    }

    fun delete(original: PhoneEvent) {
        check(mayRead() && mayWrite())
        check(calendars().any { it.id == original.calendarId && it.writable })
        unchangedEvent(original)
        val selection = listOf(
            "${Events._ID} = ?", "${Events.CALENDAR_ID} = ?", "${Events.DELETED} = 0",
            "COALESCE(${Events.STATUS}, 0) != ${Events.STATUS_CANCELED}",
            "${Events.DTSTART} = ?", "${Events.DTEND} = ?", "${Events.ALL_DAY} = ?",
            "COALESCE(${Events.TITLE}, '') = ?", "COALESCE(${Events.DESCRIPTION}, '') = ?",
            "COALESCE(${Events.EVENT_LOCATION}, '') = ?", "COALESCE(${Events.EVENT_TIMEZONE}, '') = ?",
        ) + recurrenceColumns.map { "COALESCE($it, '') = ''" }
        val args = arrayOf(
            original.id.toString(), original.calendarId.toString(), original.start.toString(), original.end.toString(),
            if (original.allDay) "1" else "0", original.title, original.description, original.location, original.zoneId,
        )
        // Apply the recurrence and snapshot checks inside the provider's delete transaction too.
        if (resolver.delete(Events.CONTENT_URI, selection.joinToString(" AND "), args) != 1) throw StaleCalendarEvent()
    }

    private fun unchangedEvent(original: PhoneEvent): Uri {
        check(original.editable && !original.recurring)
        val uri = ContentUris.withAppendedId(Events.CONTENT_URI, original.id)
        val current = resolver.query(uri, arrayOf(Events.DTSTART, Events.DTEND, Events.DELETED, Events.STATUS) + eventColumns,
            null, null, null).rows {
            if (getInt(2) != 0 || getInt(3) == Events.STATUS_CANCELED) null
            else event(original.id, getLong(0), getLong(1), 4)
        }.singleOrNull()
        if (current != original) throw StaleCalendarEvent()
        return uri
    }

    private fun Cursor.event(id: Long, start: Long, end: Long, offset: Int): PhoneEvent {
        val recurring = (6..10).any { !getString(offset + it).isNullOrEmpty() }
        val editable = !recurring && getInt(offset + 11) >= Calendars.CAL_ACCESS_CONTRIBUTOR &&
            (getInt(offset + 12) == 1 || getInt(offset + 13) == 1 || getString(offset + 14).isNullOrBlank())
        return PhoneEvent(id, getLong(offset), getString(offset + 1).orEmpty(), getString(offset + 2).orEmpty(),
            getString(offset + 3).orEmpty(), start, end, getString(offset + 4).orEmpty(),
            getInt(offset + 5) == 1, recurring, editable)
    }

    private companion object {
        val recurrenceColumns = arrayOf(Events.RRULE, Events.RDATE, Events.EXRULE, Events.EXDATE, Events.ORIGINAL_ID)
        val eventColumns = arrayOf(Events.CALENDAR_ID, Events.TITLE, Events.DESCRIPTION, Events.EVENT_LOCATION,
            Events.EVENT_TIMEZONE, Events.ALL_DAY) + recurrenceColumns +
            arrayOf(Calendars.CALENDAR_ACCESS_LEVEL, Events.IS_ORGANIZER, Events.GUESTS_CAN_MODIFY, Events.ORGANIZER)
    }
}

private inline fun <T> Cursor?.rows(row: Cursor.() -> T): List<T> = this?.use { cursor ->
    buildList { while (cursor.moveToNext()) add(cursor.row()) }
}.orEmpty()

internal class StaleCalendarEvent : IllegalStateException()

internal fun eventTime(local: LocalDateTime, zone: ZoneId, original: Long? = null): Long? {
    original?.let {
        if (Instant.ofEpochMilli(it).atZone(zone).toLocalDateTime() == local) return it
    }
    val offset = zone.rules.getValidOffsets(local).firstOrNull() ?: return null
    return local.toInstant(offset).toEpochMilli()
}
