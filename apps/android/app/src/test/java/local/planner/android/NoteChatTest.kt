package local.planner.android

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class NoteChatTest {
    private val png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+kvX8AAAAASUVORK5CYII="
    private val note = NoteDocument(
        id = "53f8ae32-6016-409d-990e-9656ce092857", folder = NOTE_WITHOUT_FOLDER,
        title = "Meeting", text = "🚀 Bold\n\uFFFC", pinned = true, createdAt = 0.0,
        richText = SharedNoteText(spans = listOf(NoteSpan(0, 2, bold = true), NoteSpan(8, 9, image = png))),
    )
    private fun stored(value: NoteDocument = note) = StoredNote(value, noteDigest(value.wireBytes()))
    private fun connection(tools: Boolean = true) = GatewayConnection("https://gateway.example/v1", "key", "model", tools)

    @Test
    fun noteProposalUsesMacContractAndKeepsLocalIdentityOutOfTheRequest() {
        val original = stored()
        val context = original.chatContext("private-workspace")
        val reply = GatewayChat(Fixture(payload(
            "message" to value("Review the new text"), "noteEdit" to value("Revised meeting notes"),
        )) { request ->
            val system = request.getAsJsonArray("messages").first().asJsonObject["content"].asString
            assertTrue(system.contains("Meeting"))
            assertTrue(system.contains("previous_note_proposal"))
            assertFalse(system.contains(context.noteId))
            assertFalse(system.contains(context.digest))
            assertFalse(system.contains(context.workspace))
            val local = com.google.gson.JsonParser.parseString(system.substringAfter("Local context (JSON data): ")).asJsonObject
            assertFalse(local.has("edit_target"))
            val properties = request.getAsJsonArray("tools").first().asJsonObject
                .getAsJsonObject("function").getAsJsonObject("parameters").getAsJsonObject("properties")
            assertEquals("string", properties.getAsJsonObject("noteEdit")["type"].asString)
        }).send(connection(), "Rewrite this note", emptyList(),
            Entity("unrelated-task", "task", mapOf("title" to value("Task"))), emptyList(),
            context, previousNoteProposal = "Previous suggestion")
        val proposal = requireNotNull(reply.noteProposal)
        assertEquals(context, proposal.note)
        assertEquals("Revised meeting notes", proposal.body)
        assertTrue(reply.proposals.isEmpty())
        assertEquals("Meeting", original.document.title)
        assertEquals(note.text, original.document.text)
    }

    @Test
    fun noteCanAlsoProduceIndependentTasksAndQuestionsSuppressAllChanges() {
        val body = payload(
            "message" to value("Review this"), "noteEdit" to value("Updated text"),
            "actions" to json.fromJson("""[{"key":"a","kind":"task","title":"Call the team"}]""", com.google.gson.JsonArray::class.java),
        )
        val gateway = GatewayChat(Fixture(body))
        val reply = gateway.send(connection(), "Revise and make a task", emptyList(), null, emptyList(), stored().chatContext("w"))
        assertNotNull(reply.noteProposal)
        assertEquals("Call the team", reply.proposals.single().title)
        body.add("questions", json.fromJson("""[{"text":"Which meeting?","options":["One","Two"]}]""", com.google.gson.JsonArray::class.java))
        val question = GatewayChat(Fixture(body)).send(connection(), "Revise", emptyList(), null, emptyList(), stored().chatContext("w"))
        assertNull(question.noteProposal)
        assertTrue(question.proposals.isEmpty())
        val unattached = gateway.send(connection(), "Revise", emptyList(), null, emptyList())
        assertNull(unattached.noteProposal)
    }

    @Test
    fun chatProposesNewNotesWithoutAnAttachmentAndRejectsInvalidActions() {
        val body = payload("actions" to json.fromJson("""[
            {"key":"n","kind":"note","title":"  Meeting agenda  ","description":"First item"},
            {"key":"t","kind":"task","title":"Book a room"},
            {"key":"n2","kind":"note","title":"Title only","description":null},
            {"key":"bad","kind":"note","title":"   ","description":"Missing title"},
            {"key":"bad2","kind":"note","title":"Wrong type","description":42}
        ]""", JsonArray::class.java))
        val gateway = GatewayChat(Fixture(body) { request ->
            val function = request.getAsJsonArray("tools").first().asJsonObject.getAsJsonObject("function")
            val actions = function.getAsJsonObject("parameters").getAsJsonObject("properties").getAsJsonObject("actions")
            val kinds = actions.getAsJsonObject("items").getAsJsonObject("properties").getAsJsonObject("kind")
            assertTrue(kinds.getAsJsonArray("enum").any { it.asString == "note" })
        })
        val reply = gateway.send(connection(), "Create these", emptyList(), null, emptyList())
        assertEquals(listOf("Meeting agenda" to "First item", "Title only" to ""),
            reply.newNotes.map { it.title to it.body })
        assertEquals("Book a room", reply.proposals.single().title)
        assertNull(reply.noteProposal)
        body.add("questions", json.fromJson("""[{"text":"Which date?","options":[]}]""", JsonArray::class.java))
        val clarification = gateway.send(connection(), "Create these", emptyList(), null, emptyList())
        assertTrue(clarification.newNotes.isEmpty())
        assertTrue(clarification.proposals.isEmpty())
    }

    @Test
    fun saveResultsAttachOnlyToTheirOriginatingResponseAndFailedAttemptsCanRetry() {
        val note = ChatNewNoteProposal("Agenda", "First item", id = "note-proposal")
        val task = ChatProposal(id = "task-proposal", title = "Book a room")
        val origin = ChatLine("assistant", "Review these", id = "origin", creationProposalIds = setOf(note.id, task.id))
        val later = ChatLine("assistant", "A later response", id = "later")
        val state = ChatState(lines = listOf(origin, later), proposals = listOf(task), newNotes = listOf(note),
            savingCreation = note.id)
        val failed = state.finishCreation(note.id, null)
        assertNull(failed.savingCreation)
        assertEquals(listOf(note), failed.newNotes)
        assertTrue(failed.lines.all { it.createdItems.isEmpty() })
        val noteLink = ChatCreatedItem(ChatCreatedKind.Note, "saved-note-id", note.title)
        val noteCreated = failed.copy(savingCreation = note.id).finishCreation(note.id, noteLink)
        assertTrue(noteCreated.newNotes.isEmpty())
        val taskLink = ChatCreatedItem(ChatCreatedKind.Task, "saved-task-id", requireNotNull(task.title))
        val both = noteCreated.copy(savingCreation = task.id).finishCreation(task.id, taskLink)
        assertEquals(listOf(noteLink, taskLink), both.lines.first().createdItems)
        assertEquals(later, both.lines.last())
        assertTrue(both.proposals.isEmpty())
        assertEquals(both, both.finishCreation(task.id, taskLink))
    }

    @Test
    fun replacementKeepsImagesAndMetadataAndRoundTripsInMacFormat() {
        val original = stored()
        val result = original.withChatText(ChatNoteProposal(original.chatContext("w"), "New 🚀 text"))
        assertEquals("New 🚀 text\n\uFFFC", result.text)
        val span = requireNotNull(result.richText).spans.single()
        assertEquals(png, span.image)
        assertEquals(result.text.length - 1, span.start)
        assertEquals(note.title, result.title)
        assertEquals(note.folder, result.folder)
        assertEquals(note.pinned, result.pinned)
        assertEquals(note.createdAt, result.createdAt, 0.0)
        assertEquals(result, decodeNote(result.wireBytes(), result.id))
    }

    @Test
    fun titleOnlyProposalPreservesFormattedText() {
        val original = stored()
        val renamed = GatewayChat(Fixture(payload("noteTitle" to value("New name")))).send(
            connection(), "Rename this note", emptyList(), null, emptyList(), original.chatContext("w"),
        ).noteProposal
        val updated = original.withChatText(requireNotNull(renamed))
        assertNull(renamed.body)
        assertEquals("New name", updated.title)
        assertEquals(note.text, updated.text)
        assertEquals(note.richText, updated.richText)
    }

    @Test
    fun appliedOrOutdatedProposalCannotBeAppliedAgain() {
        val original = stored()
        val proposal = ChatNoteProposal(original.chatContext("w"), "Next steps")
        val result = original.withChatText(proposal)
        for (changed in listOf(stored(result), stored(note.copy(title = "Changed")), stored(note.copy(deletedAt = 1.0)))) {
            assertThrows(StaleNoteProposal::class.java) { changed.withChatText(proposal) }
        }
        val other = stored(note.copy(id = newId()))
        assertThrows(StaleNoteProposal::class.java) { other.withChatText(proposal) }
    }

    @Test
    fun partialContextAndLegacyNotesStayAvailableForDiscussion() {
        val original = stored(note.copy(text = "x".repeat(16_000), richText = SharedNoteText()))
        val context = original.chatContext("w")
        assertEquals(12_000, context.text.length)
        assertTrue(context.truncated)
        assertFalse(context.editable)
        val proposal = ChatNoteProposal(context, "Next steps")
        assertThrows(IllegalArgumentException::class.java) { original.withChatText(proposal) }
        val legacy = stored(note.copy(document = "AAECAwQ=", richText = null)).chatContext("w")
        assertFalse(legacy.editable)
        val reply = GatewayChat(Fixture(payload("message" to value("Preview"), "noteEdit" to value("Rewrite"))) { request ->
            val properties = request.getAsJsonArray("tools").first().asJsonObject
                .getAsJsonObject("function").getAsJsonObject("parameters").getAsJsonObject("properties")
            assertFalse(properties.has("noteEdit"))
        }).send(connection(), "Revise", emptyList(), null, emptyList(), legacy)
        assertNull(reply.noteProposal)
    }

    private class Fixture(
        private val arguments: JsonObject, private val inspect: (JsonObject) -> Unit = {},
    ) : Transport {
        override fun request(
            origin: String, path: String, body: JsonObject?, token: String?, method: String, limit: Int,
        ): String {
            inspect(requireNotNull(body))
            return """{"choices":[{"message":{"tool_calls":[{"function":
                {"name":"propose_changes","arguments":${value(arguments.toString())}}}]}}]}"""
        }
    }
}
