package local.planner.android

import com.google.gson.JsonObject
import java.io.ByteArrayOutputStream
import java.io.File

internal val transcriptionModels = linkedMapOf(
    GatewayProvider.LiteLLM to "whisper-1",
    GatewayProvider.OpenRouter to "openai/whisper-1",
)

internal fun validTranscriptionModel(model: String): Boolean =
    model.isNotBlank() && model.length <= 160 && model.none { it.isISOControl() }

internal class VoiceTranscriber(
    private val request: (String, Map<String, String>, ByteArray, String) -> String = { address, headers, body, type ->
        HttpsTransport().exchangeBytes(address, headers, body, type, limit = 512 * 1024,
            readTimeoutMillis = 120_000, method = "POST")
    },
) {
    fun transcribe(connection: GatewayConnection, model: String, file: File): String {
        require(connection.kind in transcriptionModels && validTranscriptionModel(model))
        require(file.length() in 1..VOICE_MAX_BYTES.toLong())
        val boundary = "takt-${newId()}"
        val bytes = ByteArrayOutputStream().apply {
            write("--$boundary\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n$model\r\n".toByteArray())
            write(("--$boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"note.m4a\"\r\n" +
                "Content-Type: audio/mp4\r\n\r\n").toByteArray())
            file.inputStream().use { input -> input.copyTo(this) }
            write("\r\n--$boundary--\r\n".toByteArray())
        }.toByteArray()
        val response = request(
            connection.address + "/audio/transcriptions", mapOf("Authorization" to "Bearer ${connection.key}"),
            bytes, "multipart/form-data; boundary=$boundary",
        )
        return requireNotNull(json.fromJson(response, JsonObject::class.java).string("text")?.trim())
            .also { require(it.isNotEmpty()) }
    }
}
