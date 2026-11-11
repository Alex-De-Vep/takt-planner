package local.planner.android

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId

class CalendarAndChatTest {
    @Test
    fun allDayEventsStayOnCalendarDateAndUseExclusiveEnd() {
        val day = LocalDate.of(2026, 11, 10)
        val west = ZoneId.of("America/Los_Angeles")
        val event = PhoneEvent(1, 1, "All day", "", "",
            Instant.parse("2026-11-10T00:00:00Z").toEpochMilli(), Instant.parse("2026-11-11T00:00:00Z").toEpochMilli(),
            "UTC", allDay = true, recurring = false, editable = true)
        assertEquals(day, event.startsIn(west).toLocalDate())
        assertTrue(event.occursOn(day, west))
        assertFalse(event.occursOn(day.minusDays(1), west))
        assertFalse(event.occursOn(day.plusDays(1), west))
    }

    @Test
    fun eventEditorRejectsDstGapsAndPreservesExistingOverlapInstant() {
        val zone = ZoneId.of("Europe/Berlin")
        assertNull(eventTime(LocalDateTime.parse("2026-03-29T02:30"), zone))
        val original = Instant.parse("2026-10-25T01:30:00Z").toEpochMilli()
        assertEquals(original, eventTime(LocalDateTime.parse("2026-10-25T02:30"), zone, original))
    }

    @Test
    fun gatewayAddressRequiresHttpsAndKeepsProxyPrefix() {
        assertEquals("https://gateway.example/team/v1", liteLlmAddress("https://gateway.example/team/"))
        assertEquals("https://gateway.example/v1", liteLlmAddress("https://gateway.example/v1"))
        assertThrows(IllegalArgumentException::class.java) { liteLlmAddress("http://gateway.example") }
        assertThrows(IllegalArgumentException::class.java) { liteLlmAddress("https://gateway.example/%2e%2e/v1") }
    }

    @Test
    fun chatUsesGatewayContractWithoutSendingTaskIds() {
        val gateway = GatewayChat(object : Transport {
            override fun request(origin: String, path: String, body: JsonObject?, token: String?): String {
                assertEquals("/chat/completions", path)
                assertEquals("qa-key", token)
                val request = requireNotNull(body)
                assertEquals("propose_changes", request.getAsJsonArray("tools").first().asJsonObject
                    .getAsJsonObject("function")["name"].asString)
                assertTrue(request.toString().contains("Selected task"))
                assertFalse(request.toString().contains("private-task-id"))
                val response = payload("message" to value("Review this"), "textEdit" to payload("title" to value("Updated title")))
                return completion(response)
            }
        })
        val task = Entity("private-task-id", "task", mapOf("title" to value("Selected task")))
        val reply = gateway.send(GatewayConnection("https://gateway.example/v1", "qa-key", "model", true),
            "Rename this task", emptyList(), task, emptyList())
        val edit = reply.proposals.single()
        assertEquals("Updated title", edit.title)
        assertTrue(edit.matches(Library(entities = listOf(task))))
        assertFalse(edit.matches(Library(entities = listOf(task.copy(fields = mapOf("title" to value("Changed elsewhere")))))))
    }

    @Test
    fun calendarActionsAreOutsideTheExistingChatContract() {
        val gateway = GatewayChat(object : Transport {
            override fun request(origin: String, path: String, body: JsonObject?, token: String?): String {
                val result = JsonParser.parseString("""{"message":"Review this","actions":[
                    {"key":"event","kind":"event","title":"Calendar event"},
                    {"key":"task","kind":"task","title":"New task","date":"2026-11-10"}
                ]}""").asJsonObject
                return completion(result)
            }
        })
        val reply = gateway.send(GatewayConnection("https://gateway.example/v1", "key", "model", true),
            "Help me plan", emptyList(), null, emptyList())
        assertEquals("New task", reply.proposals.single().title)
        assertNotNull(reply.proposals.single().deadline)
    }

    private fun completion(arguments: JsonObject): String = """{"choices":[{"message":{"tool_calls":[{"function":
        {"name":"propose_changes","arguments":${value(arguments.toString())}}}]}}]}"""
}
