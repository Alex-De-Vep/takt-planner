package local.planner.android

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.google.gson.JsonPrimitive
import com.google.gson.JsonParser
import java.io.File
import java.util.Base64

internal val transcriptionProviders = listOf(
    GatewayProvider.OpenRouter, GatewayProvider.LiteLLM, GatewayProvider.GigaChat,
    GatewayProvider.OpenAI, GatewayProvider.Gemini, GatewayProvider.Mistral, GatewayProvider.Grok,
)

internal val openAiSpeechModels = setOf(
    "gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "gpt-4o-mini-transcribe-2025-12-15",
    "gpt-4o-transcribe-diarize", "whisper-1",
)
internal val gigaSpeechModels = setOf(
    "gigachat", "gigachat-pro", "gigachat-max", "gigachat-2", "gigachat-2-lite", "gigachat-2-pro",
    "gigachat-2-max", "gigachat-3-ultra",
)
internal val geminiSpeechModels = setOf(
    "gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.5-pro", "gemini-3-flash-preview",
    "gemini-3.1-flash-lite", "gemini-3.5-flash", "gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-3.5-transcribe",
)
internal val fixedTranscriptionModels = mapOf(
    GatewayProvider.Mistral to listOf(
        GatewayModel("voxtral-mini-transcribe-3", null, "Voxtral Mini Transcribe 3"),
        GatewayModel("voxtral-small-transcribe-3", null, "Voxtral Small Transcribe 3"),
    ),
    GatewayProvider.Grok to listOf(GatewayModel("grok-voice-transcribe-2.0", null, "Grok Voice Transcribe 2.0")),
)

internal data class TranscriptionSelection(val provider: GatewayProvider, val id: String, val label: String)
internal data class VoiceTranscript(val text: String, val cleanupFailed: Boolean = false)
internal class VoiceRemoteCleanupFailed(cause: Throwable) : IllegalStateException(cause)

internal fun validTranscriptionModel(model: String): Boolean =
    model.isNotBlank() && model.toByteArray().size <= 512 && model.none { it.isISOControl() }

internal class VoiceTranscriber(
    private val providers: ProviderGateway = ProviderGateway(),
    private val wav: (File) -> File = { makeVoiceWave(it, it.parentFile) },
    private val request: (String, Map<String, String>, ByteArray, String) -> String = { address, headers, body, type ->
        HttpsTransport().exchangeBytes(address, headers, body, type, limit = 512 * 1024,
            readTimeoutMillis = 120_000, method = "POST")
    },
) {
    fun transcribe(connection: GatewayConnection, model: String, file: File): VoiceTranscript {
        val provider = connection.kind
        require(provider in transcriptionProviders && provider.address(connection.address) == connection.address)
        require(validTranscriptionModel(model) && file.length() in 1..VOICE_MAX_BYTES.toLong())
        val result = when (provider) {
            GatewayProvider.GigaChat -> gigaChat(connection, model, file)
            GatewayProvider.Gemini -> VoiceTranscript(gemini(connection, model, file))
            GatewayProvider.Mistral -> {
                val wave = wav(file)
                try {
                    VoiceTranscript(multipartTranscript(connection, model, wave))
                } finally {
                    wave.delete()
                }
            }
            else -> VoiceTranscript(multipartTranscript(connection, model, file))
        }
        val text = result.text.trim()
        if (text.isEmpty() || text == "[NO_SPEECH]") {
            if (result.cleanupFailed) throw VoiceRemoteCleanupFailed(IllegalArgumentException("Empty transcript"))
            error("Empty transcript")
        }
        return result.copy(text = text)
    }

    private fun multipartTranscript(connection: GatewayConnection, model: String, file: File): String {
        val provider = connection.kind
        val path = if (provider == GatewayProvider.Grok) "/stt" else "/audio/transcriptions"
        val fields = buildMap {
            put("model", model)
            if (provider == GatewayProvider.OpenAI && model == "gpt-4o-transcribe-diarize") {
                put("chunking_strategy", "auto")
            }
        }
        return requireNotNull(upload(connection.address + path, providers.headers(connection), file, fields).string("text"))
    }

    private fun gemini(connection: GatewayConnection, model: String, file: File): String {
        require(model in geminiSpeechModels)
        val parts = JsonArray().apply {
            if (model != "gemini-3.5-transcribe") add(payload("text" to value(prompt)))
            add(payload("inlineData" to payload(
                "mimeType" to value("audio/m4a"), "data" to value(Base64.getEncoder().encodeToString(file.readBytes())),
            )))
        }
        val reply = postJson(connection.address.removeSuffix("/openai") + "/models/$model:generateContent",
            mapOf("x-goog-api-key" to connection.key), payload("contents" to arrayOfObjects(payload("parts" to parts))))
        val candidate = requireNotNull(reply.firstObject("candidates"))
        require(candidate.string("finishReason").let { it == null || it == "STOP" })
        val content = candidate["content"] as? JsonObject
        return (content?.get("parts") as? JsonArray)?.mapNotNull { raw ->
            (raw as? JsonObject)?.takeUnless { it["thought"] == JsonPrimitive(true) }?.string("text")
        }.orEmpty().joinToString("\n")
    }

    private fun gigaChat(connection: GatewayConnection, model: String, file: File): VoiceTranscript {
        val upload = upload(connection.address + "/files", providers.headers(connection), file,
            mapOf("purpose" to "general"), mime = "audio/x-m4a")
        val id = requireNotNull(upload.string("id")).also { require(it.matches(Regex("[A-Za-z0-9_-]{1,160}"))) }
        // Always remove the temporary upload once it has an ID, including after a failed transcription.
        val result = runCatching {
            val message = payload("role" to value("user"), "content" to value(prompt),
                "attachments" to JsonArray().apply { add(id) })
            val body = payload("model" to value(model), "stream" to JsonPrimitive(false),
                "messages" to arrayOfObjects(message))
            val reply = postJson(connection.address + "/chat/completions", providers.headers(connection), body)
            val choice = requireNotNull(reply.firstObject("choices"))
            require(choice.string("finish_reason").let { it == null || it == "stop" })
            requireNotNull((choice["message"] as? JsonObject)?.string("content"))
        }
        val cleanupFailed = runCatching {
            request(connection.address + "/files/$id/delete", providers.headers(connection), ByteArray(0), "application/json")
        }.isFailure
        if (cleanupFailed) result.exceptionOrNull()?.let { throw VoiceRemoteCleanupFailed(it) }
        return VoiceTranscript(result.getOrThrow(), cleanupFailed)
    }

    private fun upload(
        address: String, headers: Map<String, String>, file: File, fields: Map<String, String>,
        mime: String = if (file.extension == "wav") "audio/wav" else "audio/mp4",
    ): JsonObject {
        val boundary = "takt-${newId()}"
        val header = buildString {
            fields.forEach { (name, value) ->
                append("--$boundary\r\nContent-Disposition: form-data; name=\"$name\"\r\n\r\n$value\r\n")
            }
            val extension = if (mime == "audio/wav") "wav" else "m4a"
            append("--$boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"note.$extension\"\r\n")
            append("Content-Type: $mime\r\n\r\n")
        }.toByteArray()
        val footer = "\r\n--$boundary--\r\n".toByteArray()
        val size = file.length().also { require(it in 1..VOICE_WAVE_MAX_BYTES) }.toInt()
        val body = ByteArray(header.size + size + footer.size)
        header.copyInto(body)
        file.inputStream().buffered().use { input ->
            var position = header.size
            val end = header.size + size
            while (position < end) {
                val read = input.read(body, position, end - position)
                check(read > 0)
                position += read
            }
            check(input.read() == -1)
        }
        footer.copyInto(body, header.size + size)
        return JsonParser.parseString(request(address, headers, body, "multipart/form-data; boundary=$boundary")).asJsonObject
    }

    private fun postJson(address: String, headers: Map<String, String>, body: JsonObject): JsonObject =
        JsonParser.parseString(request(address, headers, body.toString().toByteArray(), "application/json")).asJsonObject

    private fun JsonObject.firstObject(name: String) = (get(name) as? JsonArray)?.firstOrNull() as? JsonObject
    private fun arrayOfObjects(value: JsonObject) = JsonArray().apply { add(value) }

    private companion object {
        const val prompt = "Transcribe the spoken words faithfully in their original languages. Return only the transcript. " +
            "Preserve the order of speech. Do not summarize, translate, or invent unclear words. " +
            "If there is no intelligible speech, return exactly [NO_SPEECH]."
    }
}
