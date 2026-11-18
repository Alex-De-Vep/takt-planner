package local.planner.android

import java.time.Instant
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class NoteWireTest {
    private val id = "53f8ae32-6016-409d-990e-9656ce092857"
    private val folder = "5878f3cd-ec61-4fbd-923f-4e90c22439cf"

    @Test
    fun readsMacIdentifiersAndFoundationDatesAndKeepsRichDocumentBytes() {
        val swiftJSON = """{"id":"${id.uppercase()}","folder":"folder-${folder.uppercase()}","document":"AAECAwQ=",
            "title":"Список","text":"Строка\nИзображение\ufffc","pinned":true,"createdAt":0,
            "updatedAt":1.125,"deletedAt":2}""".toByteArray()
        val note = decodeNote(swiftJSON, id)
        assertEquals(folder, note.summary.folderId)
        assertEquals("Строка\nИзображение", note.summary.preview)
        assertEquals(Instant.parse("2001-01-01T00:00:01.125Z"), noteInstant(note.updatedAt))
        assertEquals(listOf<Byte>(0, 1, 2, 3, 4), Base64.getDecoder().decode(note.document).toList())
        assertEquals(note.copy(deletedAt = null), decodeNote(note.copy(deletedAt = null).wireBytes(), id))
    }

    @Test
    fun writesPlainTextAndFolderKeyInMacFormat() {
        val note = NoteDocument(id, noteFolder(folder), "Draft", "First line\nSecond line", createdAt = 0.0)
        val wire = json.fromJson(note.wireBytes().decodeToString(), com.google.gson.JsonObject::class.java)
        assertEquals("folder-${folder.uppercase()}", wire.get("folder").asString)
        assertEquals("", wire.get("document").asString)
        assertNull(wire.get("deletedAt"))
        assertEquals(note, decodeNote(note.wireBytes(), id))
    }

    @Test
    fun macFormatKeepsEmojiOffsetsLinksAndPngOnAndroid() {
        val png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+kvX8AAAAASUVORK5CYII="
        val note = NoteDocument(
            id = id, folder = noteFolder(folder), text = "🚀 Ссылка\n• Пункт\n\uFFFC",
            richText = SharedNoteText(spans = listOf(
                NoteSpan(0, 2, bold = true, size = 24),
                NoteSpan(3, 9, italic = true, link = "https://example.test/page"),
                NoteSpan(18, 19, image = png),
            )),
        )
        assertEquals(note, decodeNote(note.wireBytes(), id))
        val styles = requireNotNull(note.richText)
        assertThrows(IllegalArgumentException::class.java) {
            styles.copy(spans = listOf(NoteSpan(1, 2, bold = true))).validate("🚀")
        }
        assertThrows(IllegalArgumentException::class.java) {
            SharedNoteText(spans = listOf(NoteSpan(0, 1, link = "javascript:echo"))).validate("a")
        }
    }
}
