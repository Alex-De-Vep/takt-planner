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
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId

class CalendarAndChatTest {
    @Test
    fun monthGridIncludesCompleteWeeksAndLeapDay() {
        val leapDay = LocalDate.of(2028, 2, 29)
        val month = CalendarView.Month.dates(leapDay, DayOfWeek.MONDAY)
        assertEquals(LocalDate.of(2028, 1, 31), month.start)
        assertEquals(LocalDate.of(2028, 3, 6), month.endExclusive)
        assertEquals(35, month.days.size)
        assertTrue(month.days.contains(leapDay))
        assertEquals(LocalDate.of(2028, 3, 29), CalendarView.Month.move(leapDay, 1))
        assertEquals(LocalDate.of(2027, 2, 28), CalendarView.Month.move(LocalDate.of(2027, 1, 31), 1))
    }

    @Test
    fun weekUsesLocalFirstDayAcrossYearBoundary() {
        val date = LocalDate.of(2027, 1, 1)
        val monday = CalendarView.Week.dates(date, DayOfWeek.MONDAY)
        val sunday = CalendarView.Week.dates(date, DayOfWeek.SUNDAY)
        assertEquals(LocalDate.of(2026, 12, 28), monday.start)
        assertEquals(LocalDate.of(2027, 1, 3), monday.last)
        assertEquals(LocalDate.of(2026, 12, 27), sunday.start)
        assertEquals(7, sunday.days.size)
        assertEquals(LocalDate.of(2027, 1, 8), CalendarView.Week.move(date, 1))
    }

    @Test
    fun dayViewKeepsOnlyTheSelectedDate() {
        val date = LocalDate.of(2026, 12, 31)
        val range = CalendarView.Day.dates(date, DayOfWeek.SUNDAY)
        assertEquals(listOf(date), range.days)
        assertEquals(LocalDate.of(2027, 1, 1), CalendarView.Day.move(date, 1))
        assertEquals(LocalDate.of(2026, 12, 30), CalendarView.Day.move(date, -1))
    }

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
            override fun request(
                origin: String, path: String, body: JsonObject?, token: String?, method: String, limit: Int,
            ): String {
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
    fun chatProposesCalendarEventsAndTasksWithoutConfusingThem() {
        val gateway = GatewayChat(object : Transport {
            override fun request(
                origin: String, path: String, body: JsonObject?, token: String?, method: String, limit: Int,
            ): String {
                val result = JsonParser.parseString("""{"message":"Review this","actions":[
                    {"key":"event","kind":"event","title":"Calendar event","start":"2026-11-10T15:00","location":"Office"},
                    {"key":"task","kind":"task","title":"New task","date":"2026-11-10"}
                ]}""").asJsonObject
                return completion(result)
            }
        })
        val reply = gateway.send(GatewayConnection("https://gateway.example/v1", "key", "model", true),
            "Help me plan", emptyList(), null, emptyList())
        assertEquals("New task", reply.proposals.single().title)
        assertNotNull(reply.proposals.single().deadline)
        val event = reply.eventProposals.single()
        assertNull(event.original)
        assertEquals("2026-11-10T15:00", event.start)
        assertEquals("2026-11-10T16:00", event.end)
        assertEquals("Office", event.location)
    }

    @Test
    fun eventCreationAcceptsSharedDateAndTimeFieldsFromProviders() {
        val zone = ZoneId.of("Europe/Moscow")
        val allDay = proposedEvent(JsonParser.parseString(
            """{"title":"Workshop","kind":"event","date":"2026-11-21","allDay":true}""",
        ).asJsonObject, null, zone)
        assertEquals("2026-11-21T00:00", requireNotNull(allDay).start)
        assertEquals(allDay.start, allDay.end)
        assertTrue(allDay.allDay)
        val timed = proposedEvent(JsonParser.parseString(
            """{"title":"Workshop","kind":"event","date":"2026-11-21","time":"13:30"}""",
        ).asJsonObject, null, zone)
        assertEquals("2026-11-21T13:30", requireNotNull(timed).start)
        assertEquals("2026-11-21T14:30", timed.end)
        assertNull(proposedEvent(JsonParser.parseString(
            """{"title":"Workshop","kind":"event","date":"2026-11-21"}""",
        ).asJsonObject, null, zone))
    }

    @Test
    fun eventEditIsScopedToTheAttachmentAndKeepsItsDuration() {
        val event = PhoneEvent(100700900L, 922500L, "Planning", "", "Old room",
            Instant.parse("2026-11-10T12:00:00Z").toEpochMilli(), Instant.parse("2026-11-10T13:30:00Z").toEpochMilli(),
            "Europe/Moscow", allDay = false, recurring = false, editable = true)
        val gateway = GatewayChat(object : Transport {
            override fun request(origin: String, path: String, body: JsonObject?, token: String?, method: String, limit: Int): String {
                assertFalse(body.toString().contains(event.id.toString()))
                assertFalse(body.toString().contains(event.calendarId.toString()))
                return completion(JsonParser.parseString("""{"message":"Review this","eventEdit":{
                    "start":"2026-11-11T10:00","location":"New room"
                }}""").asJsonObject)
            }
        })
        val connection = GatewayConnection("https://gateway.example/v1", "key", "model", true)
        val reply = gateway.send(connection, "Move it", emptyList(), null, emptyList(), event = event)
        val proposal = reply.eventProposals.single()
        assertEquals(event, proposal.original)
        assertEquals("Planning", proposal.title)
        assertEquals("2026-11-11T11:30", proposal.end)
        assertEquals("New room", proposal.location)
        assertTrue(gateway.send(connection, "Move it", emptyList(), null, emptyList()).eventProposals.isEmpty())
        assertTrue(gateway.send(connection, "Move it", emptyList(), null, emptyList(),
            event = event.copy(recurring = true, editable = false)).eventProposals.isEmpty())
    }

    @Test
    fun taskEditRejectsStaleStatusAndCanRemoveTheDeadline() {
        val gateway = GatewayChat(object : Transport {
            override fun request(origin: String, path: String, body: JsonObject?, token: String?, method: String, limit: Int): String =
                completion(JsonParser.parseString("""{"textEdit":{"clearDate":true,"today":false,"completed":true}}""").asJsonObject)
        })
        val task = Entity("test-task", "task", mapOf("title" to value("Planning")))
        val connection = GatewayConnection("https://gateway.example/v1", "key", "model", true)
        val edit = gateway.send(connection, "Complete the task", emptyList(), task, emptyList()).proposals.single()
        assertTrue(edit.clearDeadline)
        assertEquals(false, edit.focusChange)
        assertEquals(true, edit.completion)
        assertTrue(edit.matches(Library(entities = listOf(task))))
        val completed = task.copy(fields = task.fields + ("completedAt" to value("2026-11-10T12:00:00Z")))
        assertFalse(edit.matches(Library(entities = listOf(completed))))
    }

    @Test
    fun chatSendsPlainNoteContextWithoutTurningItIntoATaskTarget() {
        val gateway = GatewayChat(object : Transport {
            override fun request(
                origin: String, path: String, body: JsonObject?, token: String?, method: String, limit: Int,
            ): String {
                val messages = requireNotNull(body).getAsJsonArray("messages")
                val system = messages.first().asJsonObject["content"].asString
                val context = JsonParser.parseString(system.substringAfter("Local context (JSON data): ")).asJsonObject
                assertEquals("Project", context.getAsJsonObject("note_context")["title"].asString)
                assertEquals("Review notes", context.getAsJsonObject("note_context")["text"].asString)
                assertFalse(context.has("edit_target"))
                return """{"choices":[{"message":{"content":"Ready"}}]}"""
            }
        })
        val reply = gateway.send(GatewayConnection("https://gateway.example/v1", "key", "model", false),
            "Summarize", emptyList(), null, emptyList(), NoteChatContext("Project", "Review notes"))
        assertEquals("Ready", reply.text)
    }

    private fun completion(arguments: JsonObject): String = """{"choices":[{"message":{"tool_calls":[{"function":
        {"name":"propose_changes","arguments":${value(arguments.toString())}}}]}}]}"""
}
