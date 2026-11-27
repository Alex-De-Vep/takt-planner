package local.planner.android

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ChatHistoryTest {
    @Test
    fun storesAConversationWithDatedProposalsAndCreatedObjectLinks() {
        val deadline = Deadline(LocalDate.of(2026, 11, 25), Instant.parse("2026-11-25T16:00:00Z"),
            ZoneId.of("Europe/Moscow"))
        val content = ChatThreadContent(
            attachment = ChatAttachment(noteId = "existing-note"),
            proposals = listOf(ChatProposal(title = "Scheduled task", deadline = deadline)),
            newNotes = listOf(ChatNewNoteProposal("Draft note", "Untouched draft")),
        )
        val line = ChatLine("assistant", "Created it", createdItems = listOf(
            ChatCreatedItem(ChatCreatedKind.Note, "saved-note", "Saved note"),
        ))
        val restoredContent = chatHistoryJson.fromJson(chatHistoryJson.toJson(content), ChatThreadContent::class.java)
        val restoredLine = json.fromJson(json.toJson(line), ChatLine::class.java)
        assertEquals(content, restoredContent)
        assertEquals(line, restoredLine)
    }

    @Test
    fun switchingThreadReplacesMessagesProposalsAndAttachments() {
        val former = ChatState(
            model = "configured-model", threadId = "first", attachment = ChatAttachment(taskId = "old-task"),
            lines = listOf(ChatLine("user", "First thread")),
            newNotes = listOf(ChatNewNoteProposal("First", "")), savingCreation = "old-proposal",
        )
        val second = StoredChatThread("second", listOf(ChatThreadSummary("second", null)), emptyList(), ChatThreadContent())
        val active = former.withThread(second)
        assertEquals("second", active.threadId)
        assertEquals("configured-model", active.model)
        assertEquals(emptyList<ChatLine>(), active.lines)
        assertEquals(emptyList<ChatNewNoteProposal>(), active.newNotes)
        assertEquals(ChatAttachment(), active.attachment)
        assertNull(active.savingCreation)
    }

    @Test
    fun aTitleUsesTheFirstLineAndDoesNotSplitEmoji() {
        assertEquals("First line", chatThreadTitle("  First line  \nSecond line"))
        assertEquals("A".repeat(59), chatThreadTitle("A".repeat(59) + "🚀"))
    }
}
