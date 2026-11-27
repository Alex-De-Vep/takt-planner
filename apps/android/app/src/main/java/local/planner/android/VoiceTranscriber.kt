package local.planner.android

import androidx.annotation.StringRes
import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.google.gson.JsonParseException
import com.google.gson.JsonPrimitive
import com.google.gson.JsonParser
import java.io.File
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.Base64
import javax.net.ssl.SSLHandshakeException
import kotlinx.coroutines.CancellationException

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
internal class VoiceTranscriptionFailure(@get:StringRes val messageId: Int, cause: Throwable? = null) : Exception(cause)

internal data class VoiceTranscriptionIssue(@get:StringRes val messageId: Int, val part: Int? = null)

@StringRes
internal fun voiceTranscriptionError(failure: Exception): Int {
    val cause = if (failure is VoiceRemoteCleanupFailed) failure.cause else failure
    return when (cause) {
        is VoiceTranscriptionFailure -> cause.messageId
        is JsonParseException -> R.string.voice_transcript_invalid_response
        is SSLHandshakeException -> R.string.chat_tls_error
        is SocketTimeoutException -> R.string.voice_transcript_timeout
        is UnknownHostException, is SocketException -> R.string.voice_transcript_network
        is ServerFailure -> when (cause.status) {
            401, 403 -> R.string.voice_transcript_access
            402 -> R.string.voice_transcript_billing
            404 -> R.string.voice_transcript_model_unavailable
            413 -> R.string.voice_transcript_size
            400, 415, 422 -> R.string.voice_transcript_audio_rejected
            429 -> R.string.voice_transcript_rate_limit
            in 500..599 -> R.string.voice_transcript_service
            else -> R.string.voice_transcript_error
        }
        else -> R.string.voice_transcript_error
    }
}

internal class VoiceTranscriptionAttempt(val clip: VoiceClip, val selection: TranscriptionSelection) {
    val completed = mutableListOf<VoiceTranscript>()
}

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
    suspend fun transcribeRecording(
        connection: GatewayConnection, model: String, clip: VoiceClip, cache: File,
        completed: List<VoiceTranscript>, onPart: suspend (Int?, VoiceTranscript?) -> Unit,
    ): VoiceTranscript {
        val results = completed.toMutableList()
        var lastPart = 0
        forEachVoicePart(clip, cache, convertToWave = connection.kind == GatewayProvider.Mistral) { number, file, split ->
            lastPart = number
            if (number > results.size) {
                val progress = number.takeIf { split }
                onPart(progress, null)
                val result = transcribe(connection, model, file)
                results.add(result)
                onPart(progress, result)
            }
        }
        check(lastPart == results.size)
        val text = results.map(VoiceTranscript::text).filter(String::isNotBlank).joinToString("\n\n")
        val cleanupFailed = results.any(VoiceTranscript::cleanupFailed)
        return VoiceTranscript(text, cleanupFailed)
    }

    fun transcribe(connection: GatewayConnection, model: String, file: File): VoiceTranscript {
        val provider = connection.kind
        if (provider !in transcriptionProviders || !validTranscriptionModel(model)) {
            throw VoiceTranscriptionFailure(R.string.voice_transcript_model_unavailable)
        }
        require(provider.address(connection.address) == connection.address)
        prepareVoiceAudio { check(file.isFile && file.canRead() && file.length() in 1..VOICE_PART_MAX_BYTES) }
        val result = when (provider) {
            GatewayProvider.GigaChat -> gigaChat(connection, model, file)
            GatewayProvider.Gemini -> VoiceTranscript(gemini(connection, model, file))
            GatewayProvider.Mistral -> {
                val wave = prepareVoiceAudio { wav(file) }
                try {
                    VoiceTranscript(multipartTranscript(connection, model, wave))
                } finally {
                    wave.delete()
                }
            }
            else -> VoiceTranscript(multipartTranscript(connection, model, file))
        }
        val text = result.text.trim()
        val silence = text.trim('`').trim().equals("[NO_SPEECH]", ignoreCase = true)
        return result.copy(text = if (silence) "" else text)
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
        return upload(connection.address + path, providers.headers(connection), file, fields).string("text")
            ?: invalidResponse()
    }

    private fun gemini(connection: GatewayConnection, model: String, file: File): String {
        if (model !in geminiSpeechModels) throw VoiceTranscriptionFailure(R.string.voice_transcript_model_unavailable)
        val parts = JsonArray().apply {
            if (model != "gemini-3.5-transcribe") add(payload("text" to value(prompt)))
            add(payload("inlineData" to payload(
                "mimeType" to value("audio/m4a"), "data" to value(Base64.getEncoder().encodeToString(prepareVoiceAudio { file.readBytes() })),
            )))
        }
        val reply = postJson(connection.address.removeSuffix("/openai") + "/models/$model:generateContent",
            mapOf("x-goog-api-key" to connection.key), payload("contents" to arrayOfObjects(payload("parts" to parts))))
        val block = (reply["promptFeedback"] as? JsonObject)?.string("blockReason")
        if (!block.isNullOrBlank() && block != "BLOCK_REASON_UNSPECIFIED") {
            throw VoiceTranscriptionFailure(R.string.voice_transcript_blocked)
        }
        val candidate = reply.firstObject("candidates") ?: invalidResponse()
        when (candidate.string("finishReason")) {
            null, "STOP" -> Unit
            "MAX_TOKENS", "CONTINUATION" -> throw VoiceTranscriptionFailure(R.string.voice_transcript_truncated)
            "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "ESCALATION" ->
                throw VoiceTranscriptionFailure(R.string.voice_transcript_blocked)
            "LANGUAGE" -> throw VoiceTranscriptionFailure(R.string.voice_transcript_language)
            else -> invalidResponse()
        }
        val content = candidate["content"] ?: return ""
        val receivedParts = (content as? JsonObject ?: invalidResponse())["parts"] ?: return ""
        return (receivedParts as? JsonArray ?: invalidResponse()).mapNotNull { raw ->
            val part = raw as? JsonObject ?: invalidResponse()
            part.takeUnless { it["thought"] == JsonPrimitive(true) }?.string("text")
        }.joinToString("\n")
    }

    private fun gigaChat(connection: GatewayConnection, model: String, file: File): VoiceTranscript {
        val upload = upload(connection.address + "/files", providers.headers(connection), file,
            mapOf("purpose" to "general"), mime = "audio/x-m4a")
        val id = upload.string("id")?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{1,160}")) } ?: invalidResponse()
        // Always remove the temporary upload once it has an ID, including after a failed transcription.
        val result = runCatching {
            val message = payload("role" to value("user"), "content" to value(prompt),
                "attachments" to JsonArray().apply { add(id) })
            val body = payload("model" to value(model), "stream" to JsonPrimitive(false),
                "messages" to arrayOfObjects(message))
            val reply = postJson(connection.address + "/chat/completions", providers.headers(connection), body)
            val choice = reply.firstObject("choices") ?: invalidResponse()
            when (choice.string("finish_reason")) {
                null, "stop" -> Unit
                "length" -> throw VoiceTranscriptionFailure(R.string.voice_transcript_truncated)
                "blacklist" -> throw VoiceTranscriptionFailure(R.string.voice_transcript_blocked)
                else -> invalidResponse()
            }
            (choice["message"] as? JsonObject)?.string("content") ?: invalidResponse()
        }
        val cleanupFailed = runCatching {
            request(connection.address + "/files/$id/delete", providers.headers(connection), ByteArray(0), "application/json")
        }.isFailure
        if (cleanupFailed) result.exceptionOrNull()?.let {
            if (it is CancellationException) throw it
            throw VoiceRemoteCleanupFailed(it)
        }
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
        prepareVoiceAudio {
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
        }
        footer.copyInto(body, header.size + size)
        return parseResponse(request(address, headers, body, "multipart/form-data; boundary=$boundary"))
    }

    private fun postJson(address: String, headers: Map<String, String>, body: JsonObject): JsonObject =
        parseResponse(request(address, headers, body.toString().toByteArray(), "application/json"))

    private fun parseResponse(body: String): JsonObject =
        JsonParser.parseString(body).let { it as? JsonObject } ?: invalidResponse()

    private fun invalidResponse(): Nothing = throw VoiceTranscriptionFailure(R.string.voice_transcript_invalid_response)

    private fun JsonObject.firstObject(name: String) = (get(name) as? JsonArray)?.firstOrNull() as? JsonObject
    private fun arrayOfObjects(value: JsonObject) = JsonArray().apply { add(value) }

    private companion object {
        const val prompt = "Transcribe the spoken words faithfully in their original languages. Return only the transcript. " +
            "Preserve the order of speech. Do not summarize, translate, or invent unclear words. " +
            "If there is no intelligible speech, return exactly [NO_SPEECH]."
    }
}
