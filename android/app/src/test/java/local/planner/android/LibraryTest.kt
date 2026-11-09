package local.planner.android

import com.google.gson.JsonNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

class LibraryTest {
    private val remote = Stamp(10, 1, "a", "a")
    private val local = Stamp(10, 2, "b", "b")
    private val original = Entity(
        "task", "task", mapOf("title" to value("Server title"), "focusDay" to value(FOCUS_MARK)),
        mapOf("title" to local, "focusDay" to remote), revision = "4",
    )

    @Test
    fun overlayMergesFieldsIndependently() {
        val mutation = update("title" to FieldChange(value("Old title"), remote), "focusDay" to FieldChange(JsonNull.INSTANCE, local))
        val result = requireNotNull(mutation.overlay(original))
        assertEquals("Server title", result.text("title"))
        assertNull(result.text("focusDay"))
        assertEquals("4", result.revision)
    }

    @Test
    fun serverNormalizationWinsAtEqualVersion() {
        val task = original.copy(fields = mapOf("placement" to placement("inbox")), versions = mapOf("placement" to local))
        val pending = update("placement" to FieldChange(placement("removed-folder"), local))
        assertEquals("inbox", pending.overlay(task)?.placement)
    }

    @Test
    fun editsCannotResurrectDeletedEntities() {
        val tombstone = original.copy(deleted = true)
        assertEquals(tombstone, update("title" to FieldChange(value("Changed"), local)).overlay(tombstone))
        assertNull(update("title" to FieldChange(value("Changed"), local)).overlay(null))
    }

    @Test
    fun requestPreservesExplicitNullAndOmitsUnusedKeys() {
        val request = update("focusDay" to FieldChange(JsonNull.INSTANCE, local)).wire()
        assertTrue(request.getAsJsonObject("changes").getAsJsonObject("focusDay")["value"].isJsonNull)
        assertFalse(request.has("deleteVersion"))
        val deletion = Mutation("b", "library", "device", "task", "task", "delete", deleteVersion = local).wire()
        assertFalse(deletion.has("changes"))
        assertTrue(deletion.has("deleteVersion"))
    }

    @Test
    fun batchesHonorOperationAndByteLimits() {
        val small = update("title" to FieldChange(value("A"), local))
        assertEquals(100, mutationBatch(List(101) { small }).size)
        val large = update("description" to FieldChange(value("я".repeat(524_288)), local))
        assertEquals(3, mutationBatch(List(5) { large }).size)
    }

    @Test
    fun deadlinesPreserveLocalDateAndTimedInstant() {
        val zone = ZoneId.of("Europe/Moscow")
        val date = LocalDate.of(2026, 11, 10)
        val dateOnly = Deadline(date, null, zone)
        assertEquals(dateOnly, Deadline.read(dateOnly.wire()))
        assertEquals(Instant.parse("2026-11-10T06:00:00Z").toEpochMilli(), dateOnly.reminderAt())
        val timed = Deadline(date, Instant.parse("2026-11-09T22:00:00Z"), zone)
        assertEquals(timed, Deadline.read(timed.wire()))
    }

    private fun update(vararg fields: Pair<String, FieldChange>) =
        Mutation("b", "library", "device", "task", "task", "update", fields.toMap())
}
