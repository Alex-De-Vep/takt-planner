package local.planner.android

import java.net.SocketTimeoutException
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
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
            ).text)
        } finally {
            file.delete()
        }
    }

    @Test
    fun catalogKeepsSpeechModelsSeparateFromChatModels() {
        val providers = ProviderGateway { url, headers, body, _ ->
            assertEquals(mapOf("Authorization" to "Bearer qa-key"), headers)
            assertEquals(null, body)
            when (url) {
                "https://api.openai.com/v1/models" ->
                    """{"data":[{"id":"gpt-chat"},{"id":"gpt-4o-transcribe"}]}"""
                "https://gateway.example/team/model/info" ->
                    """{"data":[{"model_name":"text","model_info":{"mode":"chat"}},
                        {"model_name":"speech","model_info":{"mode":"audio_transcription"}}]}"""
                "https://openrouter.ai/api/v1/models?output_modalities=transcription" ->
                    """{"data":[{"id":"openai/whisper-1","name":"Whisper"}]}"""
                else -> error("Unexpected request: $url")
            }
        }
        assertEquals(listOf("gpt-4o-transcribe"), providers.transcriptionCatalog(connection(GatewayProvider.OpenAI)).map { it.id })
        assertEquals(listOf("gpt-chat"), providers.candidate(connection(GatewayProvider.OpenAI), GatewayOptions()).models.map { it.id })
        assertEquals(listOf("speech"), providers.transcriptionCatalog(connection(GatewayProvider.LiteLLM)).map { it.id })
        assertEquals("Whisper", providers.transcriptionCatalog(connection(GatewayProvider.OpenRouter)).single().label)
    }

    @Test
    fun routesGeminiAndGrokThroughTheirAudioEndpoints() {
        val file = Files.createTempFile("note-audio", ".m4a").toFile()
        try {
            file.writeBytes(byteArrayOf(1, 2, 3))
            val gemini = VoiceTranscriber { url, headers, body, type ->
                assertEquals("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent", url)
                assertEquals(mapOf("x-goog-api-key" to "qa-key"), headers)
                assertEquals("application/json", type)
                assertTrue(body.toString(Charsets.UTF_8).contains("AQID"))
                """{"candidates":[{"finishReason":"STOP","content":{"parts":[
                    {"text":"reasoning","thought":true},{"text":"spoken words"}]}}]}"""
            }
            assertEquals("spoken words", gemini.transcribe(connection(GatewayProvider.Gemini), "gemini-2.5-flash", file).text)
            val grok = VoiceTranscriber { url, _, bytes, type ->
                assertEquals("https://api.x.ai/v1/stt", url)
                assertTrue(type.startsWith("multipart/form-data"))
                assertTrue(bytes.toString(Charsets.UTF_8).contains("grok-voice-transcribe-2.0"))
                """{"text":"spoken words"}"""
            }
            assertEquals("spoken words", grok.transcribe(connection(GatewayProvider.Grok), "grok-voice-transcribe-2.0", file).text)
        } finally {
            file.delete()
        }
    }

    @Test
    fun gigaChatDeletesItsUploadWhenTranscriptionFails() {
        val file = Files.createTempFile("note-audio", ".m4a").toFile()
        try {
            file.writeBytes(byteArrayOf(1, 2, 3))
            val paths = mutableListOf<String>()
            val providers = ProviderGateway { url, _, _, _ ->
                assertTrue(url.endsWith("/oauth"))
                """{"access_token":"audio-token","expires_at":4102444800000}"""
            }
            val transcriber = VoiceTranscriber(providers) { url, headers, content, _ ->
                assertEquals(mapOf("Authorization" to "Bearer audio-token"), headers)
                val path = url.removePrefix("https://api.giga.chat/v1")
                paths.add(path)
                when (path) {
                    "/files" -> """{"id":"sample-file-id"}"""
                    "/chat/completions" -> {
                        assertTrue(content.toString(Charsets.UTF_8).contains("\"attachments\":[\"sample-file-id\"]"))
                        """{"choices":[]}"""
                    }
                    "/files/sample-file-id/delete" -> "{}"
                    else -> error(path)
                }
            }
            val failure = assertThrows(VoiceTranscriptionFailure::class.java) {
                transcriber.transcribe(connection(GatewayProvider.GigaChat), "GigaChat-2", file)
            }
            assertEquals(R.string.voice_transcript_invalid_response, failure.messageId)
            assertEquals(listOf("/files", "/chat/completions", "/files/sample-file-id/delete"), paths)
        } finally {
            file.delete()
        }
    }

    @Test
    fun mistralUsesWaveCopyAndKeepsTheOriginalRecording() {
        val original = Files.createTempFile("note-audio", ".m4a").toFile()
        val wave = Files.createTempFile("note-wave", ".wav").toFile()
        try {
            original.writeBytes(byteArrayOf(0, 1))
            wave.writeBytes(pcmWaveHeader(4, channels = 1, rate = 24_000) + byteArrayOf(1, 2, 3, 4))
            val header = ByteBuffer.wrap(wave.readBytes()).order(ByteOrder.LITTLE_ENDIAN)
            assertEquals(24_000, header.getInt(24))
            assertEquals(4, header.getInt(40))
            val transcriber = VoiceTranscriber(wav = { wave }) { url, _, bytes, _ ->
                assertEquals("https://api.mistral.ai/v1/audio/transcriptions", url)
                assertTrue(bytes.toString(Charsets.ISO_8859_1).contains("filename=\"note.wav\""))
                """{"text":"Voice transcript"}"""
            }
            assertEquals("Voice transcript", transcriber.transcribe(
                connection(GatewayProvider.Mistral), "voxtral-mini-transcribe-3", original,
            ).text)
            assertTrue(original.exists())
            assertFalse(wave.exists())
        } finally {
            original.delete()
            wave.delete()
        }
    }

    @Test
    fun acceptsAnExplicitEmptyTranscriptAndRejectsAMissingTextField() = runBlocking {
        val file = Files.createTempFile("note-audio", ".m4a").toFile()
        try {
            file.writeBytes(byteArrayOf(1, 2, 3))
            val connection = connection(GatewayProvider.OpenAI)
            val model = "gpt-4o-transcribe"
            for (body in listOf("""{"text":""}""", """{"text":"  "}""", """{"text":"`[no_speech]`"}""")) {
                val transcriber = VoiceTranscriber { _, _, _, _ -> body }
                val result = transcriber.transcribeRecording(connection, model, VoiceClip(file, 1000),
                    requireNotNull(file.parentFile), emptyList()) { _, _ -> }
                assertEquals("", result.text)
            }
            for (body in listOf("{}", """{"text":null}""", """{"text":123}""", "[]")) {
                val transcriber = VoiceTranscriber { _, _, _, _ -> body }
                val failure = assertThrows(VoiceTranscriptionFailure::class.java) {
                    transcriber.transcribe(connection, model, file)
                }
                assertEquals(R.string.voice_transcript_invalid_response, failure.messageId)
            }
        } finally {
            file.delete()
        }
    }

    @Test
    fun geminiDistinguishesBlockedAndTruncatedResponsesFromSilence() {
        val file = Files.createTempFile("note-audio", ".m4a").toFile()
        try {
            file.writeBytes(byteArrayOf(1, 2, 3))
            val connection = connection(GatewayProvider.Gemini)
            val model = "gemini-2.5-flash"
            val cases = mapOf(
                """{"promptFeedback":{"blockReason":"SAFETY"}}""" to R.string.voice_transcript_blocked,
                """{"candidates":[{"finishReason":"SAFETY"}]}""" to R.string.voice_transcript_blocked,
                """{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"Partial"}]}}]}""" to
                    R.string.voice_transcript_truncated,
                """{"candidates":[{"finishReason":"STOP","content":"invalid"}]}""" to R.string.voice_transcript_invalid_response,
            )
            for ((body, message) in cases) {
                val transcriber = VoiceTranscriber { _, _, _, _ -> body }
                val failure = assertThrows(VoiceTranscriptionFailure::class.java) {
                    transcriber.transcribe(connection, model, file)
                }
                assertEquals(message, failure.messageId)
            }
            val empty = VoiceTranscriber { _, _, _, _ ->
                """{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"[NO_SPEECH]"}]}}]}"""
            }
            assertEquals("", empty.transcribe(connection, model, file).text)
        } finally {
            file.delete()
        }
    }

    @Test
    fun gigaChatReportsCleanupIndependentlyOfSilenceAndRecognitionErrors() {
        val file = Files.createTempFile("note-audio", ".m4a").toFile()
        try {
            file.writeBytes(byteArrayOf(1, 2, 3))
            val providers = ProviderGateway { _, _, _, _ -> """{"access_token":"abc","expires_at":4102444800000}""" }
            val connection = connection(GatewayProvider.GigaChat)
            var reply = """{"choices":[{"finish_reason":"stop","message":{"content":"[NO_SPEECH]"}}]}"""
            val transcriber = VoiceTranscriber(providers) { url, _, _, _ ->
                when (url.removePrefix(connection.address)) {
                    "/files" -> """{"id":"sample-file-id"}"""
                    "/chat/completions" -> reply
                    "/files/sample-file-id/delete" -> throw ServerFailure(503, "unavailable")
                    else -> error(url)
                }
            }
            assertEquals(VoiceTranscript("", cleanupFailed = true), transcriber.transcribe(connection, "GigaChat-2", file))
            reply = """{"choices":[{"finish_reason":"length","message":{"content":"Partial"}}]}"""
            val failure = assertThrows(VoiceRemoteCleanupFailed::class.java) {
                transcriber.transcribe(connection, "GigaChat-2", file)
            }
            assertEquals(R.string.voice_transcript_truncated, voiceTranscriptionError(failure))
        } finally {
            file.delete()
        }
    }

    @Test
    fun retainsCompletedPartsAndClassifiesProviderFailures() = runBlocking {
        val file = Files.createTempFile("note-audio", ".m4a").toFile()
        try {
            file.writeBytes(byteArrayOf(1, 2, 3))
            val transcriber = VoiceTranscriber { _, _, _, _ -> error("Completed audio must not be sent twice") }
            val result = transcriber.transcribeRecording(connection(GatewayProvider.OpenAI), "gpt-4o-transcribe",
                VoiceClip(file, 1000), requireNotNull(file.parentFile), listOf(VoiceTranscript("Saved"))) { _, _ ->
                error("Completed audio must not be processed again")
            }
            assertEquals("Saved", result.text)
            assertEquals(R.string.voice_transcript_timeout, voiceTranscriptionError(SocketTimeoutException()))
            assertEquals(R.string.voice_transcript_access, voiceTranscriptionError(ServerFailure(401, "unauthorized")))
            assertEquals(R.string.voice_transcript_size, voiceTranscriptionError(ServerFailure(413, "too_large")))
            assertEquals(R.string.voice_transcript_rate_limit, voiceTranscriptionError(ServerFailure(429, "limited")))
            assertEquals(R.string.voice_transcript_service, voiceTranscriptionError(ServerFailure(503, "unavailable")))
        } finally {
            file.delete()
        }
    }

    private fun connection(provider: GatewayProvider) = GatewayConnection(
        provider.bases.firstOrNull() ?: "https://gateway.example/team/v1", "qa-key", "chat", false, provider,
    )
}
