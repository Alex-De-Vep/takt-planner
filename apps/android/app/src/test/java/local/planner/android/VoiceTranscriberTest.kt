package local.planner.android

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VoiceTranscriberTest {
    @Test
    fun uploadsBinaryAudioWithSeparateModelAndReadsTranscript() {
        val sample = byteArrayOf(0, 1, 2, -1)
        val file = Files.createTempFile("note-audio", ".m4a").toFile()
        try {
            file.writeBytes(sample)
            val transcriber = VoiceTranscriber { url, headers, bytes, contentType ->
                assertEquals("https://gateway.example/team/v1/audio/transcriptions", url)
                assertEquals(mapOf("Authorization" to "Bearer qa-key"), headers)
                val boundary = contentType.substringAfter("boundary=")
                val body = bytes.toString(Charsets.ISO_8859_1)
                assertTrue(body.startsWith("--$boundary\r\n"))
                assertTrue(body.contains("name=\"model\"\r\n\r\nqa-transcription\r\n"))
                assertTrue(body.contains("name=\"file\"; filename=\"note.m4a\""))
                assertTrue(body.contains(sample.toString(Charsets.ISO_8859_1)))
                assertTrue(body.endsWith("\r\n--$boundary--\r\n"))
                """{"text":" Результат "}"""
            }
            assertEquals("Результат", transcriber.transcribe(
                GatewayConnection("https://gateway.example/team/v1", "qa-key", "chat", false),
                "qa-transcription", file,
            ))
        } finally {
            file.delete()
        }
    }
}
