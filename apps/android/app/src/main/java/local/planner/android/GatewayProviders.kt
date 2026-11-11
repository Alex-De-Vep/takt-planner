package local.planner.android

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.google.gson.JsonPrimitive
import java.net.URLEncoder

internal enum class GatewayWire { Chat, Messages, Responses }

internal enum class GatewayProvider(
    val label: String,
    val bases: List<String>,
    val wire: GatewayWire = GatewayWire.Chat,
    val configuredModels: List<String>? = null,
) {
    ChatGPT("ChatGPT", listOf("https://api.openai.com/v1"), GatewayWire.Responses),
    OpenRouter("OpenRouter", listOf("https://openrouter.ai/api/v1")),
    LiteLLM("LiteLLM", emptyList()),
    Copilot("GitHub Copilot", emptyList()),
    MiniMaxPlan("MiniMax M Plan", listOf("https://api.minimax.io/anthropic/v1"), GatewayWire.Messages,
        listOf("MiniMax-M3.1-Flash", "MiniMax-M3")),
    MiniMax("MiniMax API", listOf("https://api.minimax.io/anthropic/v1"), GatewayWire.Messages,
        listOf("MiniMax-M3.1-Flash", "MiniMax-M3")),
    Claude("Claude", listOf("https://api.anthropic.com/v1"), GatewayWire.Messages),
    Gemini("Gemini", listOf("https://generativelanguage.googleapis.com/v1beta/openai")),
    DeepSeek("DeepSeek", listOf("https://api.deepseek.com"), GatewayWire.Responses),
    Mistral("Mistral", listOf("https://api.mistral.ai/v1"), GatewayWire.Responses),
    Glm("GLM · Z.ai", listOf("https://api.z.ai/api/paas/v4"), configuredModels = listOf("glm-5", "glm-4.7")),
    Grok("Grok", listOf("https://api.x.ai/v1"), GatewayWire.Responses),
    Qwen("QwenCloud", listOf("ap-southeast-1", "eu-central-1", "cn-hongkong", "ap-northeast-1", "us-east-1", "cn-beijing")
        .map { "https://$it.maas.qwencloudapi.com/compatible-mode/v1" }, configuredModels = listOf("qwen3.8-max", "qwen-plus", "qwen-flash")),
    Kimi("Kimi", listOf("https://api.moonshot.ai/v1", "https://api.moonshot.cn/v1")),
    Yandex("YandexGPT Pro", listOf("https://ai.api.cloud.yandex.net/v1"), configuredModels = emptyList()),
    GigaChat("GigaChat", listOf("https://api.giga.chat/v1"));

    val streams get() = this == ChatGPT || this == Copilot
    val path get() = when (wire) {
        GatewayWire.Chat -> "/chat/completions"
        GatewayWire.Messages -> "/messages"
        GatewayWire.Responses -> "/responses"
    }

    fun address(input: String): String {
        if (bases.isEmpty()) return liteLlmAddress(input)
        return input.ifBlank { bases.first() }.also { require(it in bases) }
    }

    fun tools(id: String): Boolean? {
        val lower = id.lowercase()
        return when (this) {
            ChatGPT, Yandex, Copilot -> true
            Claude -> lower.startsWith("claude-")
            Gemini -> lower.startsWith("gemini-") &&
                listOf("image", "tts", "live", "audio", "robotics", "deep-research").none(lower::contains)
            GigaChat -> lower.startsWith("gigachat")
            DeepSeek -> true.takeIf { lower.startsWith("deepseek-") }
            Grok -> true.takeIf { lower.startsWith("grok-") }
            Kimi -> true.takeIf { lower.startsWith("kimi-k2") || lower.startsWith("moonshot-v1") }
            Glm, MiniMax, MiniMaxPlan, Qwen -> true.takeIf { id in configuredModels.orEmpty() }
            else -> null
        }
    }
}

internal enum class GigaScope(val wire: String, val label: Int) {
    Personal("GIGACHAT_API_PERS", R.string.chat_giga_personal),
    Business("GIGACHAT_API_B2B", R.string.chat_giga_business),
    Corporate("GIGACHAT_API_CORP", R.string.chat_giga_corporate),
}

internal data class GatewayCandidate(val connection: GatewayConnection, val models: List<GatewayModel>)
internal data class GatewayAnswer(val text: String, val name: String? = null, val arguments: String? = null)
internal data class GatewayOptions(val modelIds: String = "", val project: String = "", val scope: GigaScope = GigaScope.Personal)

internal typealias GatewayRequest = (String, Map<String, String>, String?, String) -> String

internal fun providerRequest(http: HttpsTransport = HttpsTransport()): GatewayRequest = { url, headers, body, type ->
    http.exchange(url, headers, body, type, limit = 4_000_000, readTimeoutMillis = 75_000)
}

internal class ProviderGateway(private val request: GatewayRequest = providerRequest()) {
    private data class GigaAccess(val token: String, val expires: Long)
    private val gigaTokens = mutableMapOf<Pair<String, GigaScope>, GigaAccess>()

    fun candidate(connection: GatewayConnection, options: GatewayOptions): GatewayCandidate {
        val provider = connection.kind
        if (provider.configuredModels != null) {
            val ids = if (provider == GatewayProvider.Yandex) {
                listOf("gpt://${requireNotNull(connection.project)}/yandexgpt/latest")
            } else {
                options.modelIds.split(',', '\n').map(String::trim).filter(String::isNotEmpty).distinct()
                    .also { require(it.isNotEmpty() && it.size <= 8 && it.all { id -> id.matches(Regex("[A-Za-z0-9_./:+-]{1,160}")) }) }
            }
            // Проверяем доступ до записи ключа. В пробном запросе нет данных пользователя.
            val accessible = ids.mapNotNull { id ->
                val model = GatewayModel(id, provider.tools(id))
                try {
                    completion(connection.copy(model = id), "Reply with OK.", emptyList(), "OK", null, 64)
                    model
                } catch (failure: ServerFailure) {
                    if (failure.status !in listOf(400, 403, 404, 422)) throw failure
                    null
                }
            }
            require(accessible.isNotEmpty())
            return GatewayCandidate(connection, accessible)
        }
        if (provider == GatewayProvider.Gemini) return GatewayCandidate(connection, geminiModels(connection))
        val path = when (provider) {
            GatewayProvider.Grok -> "/language-models"
            GatewayProvider.Claude -> "/models?limit=1000"
            else -> "/models"
        }
        val root = objectRequest(connection.address + path, headers(connection))
        val account = if (provider == GatewayProvider.Copilot) {
            requireNotNull(root.string("account")).also { require(it.contains('|') && it.length <= 256) }
        } else null
        return GatewayCandidate(connection.copy(account = account), catalog(root, provider))
    }

    private fun geminiModels(connection: GatewayConnection): List<GatewayModel> {
        val result = mutableListOf<GatewayModel>()
        val seen = mutableSetOf<String>()
        var next: String? = null
        do {
            val query = next?.let { "&pageToken=" + URLEncoder.encode(it, "UTF-8") }.orEmpty()
            val page = objectRequest("https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000$query",
                mapOf("x-goog-api-key" to connection.key))
            page.getAsJsonArray("models")?.forEach { element ->
                val model = element.asJsonObject
                val name = model.string("name")
                if (name?.startsWith("models/") == true &&
                    model.getAsJsonArray("supportedGenerationMethods")?.any { it.asString == "generateContent" } == true) {
                    val id = name.removePrefix("models/")
                    result.add(GatewayModel(id, connection.kind.tools(id), model.string("displayName")))
                }
            }
            next = page.string("nextPageToken")?.takeIf { seen.size < 14 && seen.add(it) }
        } while (next != null)
        return result.distinctBy(GatewayModel::id).also { require(it.isNotEmpty()) }
    }

    fun completion(
        connection: GatewayConnection, instructions: String, history: List<ChatLine>, prompt: String,
        tool: JsonObject?, tokenLimit: Int? = null,
    ): GatewayAnswer {
        val provider = connection.kind
        val messages = JsonArray().apply {
            if (provider.wire == GatewayWire.Chat) add(message("system", instructions))
            history.forEach { add(message(it.role, it.text.take(1600))) }
            add(message("user", prompt))
        }
        val body = payload("model" to value(connection.model), "stream" to JsonPrimitive(provider.streams))
        when (provider.wire) {
            GatewayWire.Chat -> {
                body.add("messages", messages)
                tokenLimit?.let { body.addProperty("max_tokens", it) }
                tool?.let {
                    if (provider == GatewayProvider.GigaChat) {
                        body.add("functions", array(it))
                        body.addProperty("function_call", "auto")
                    } else {
                        body.add("tools", array(payload("type" to value("function"), "function" to it)))
                    }
                }
                if (provider == GatewayProvider.OpenRouter && tool != null) {
                    body.add("provider", payload("require_parameters" to JsonPrimitive(true)))
                }
                if (provider == GatewayProvider.Glm) body.add("thinking", payload("type" to value("disabled")))
                if (provider == GatewayProvider.Qwen && tool != null) body.addProperty("enable_thinking", false)
            }
            GatewayWire.Messages -> {
                while (messages.size() > 1 && messages.first().asJsonObject.string("role") == "assistant") messages.remove(0)
                body.add("messages", messages)
                body.addProperty("system", instructions)
                body.addProperty("max_tokens", tokenLimit ?: 4096)
                tool?.let {
                    val converted = it.deepCopy()
                    converted.add("input_schema", converted.remove("parameters"))
                    body.add("tools", array(converted))
                    body.add("tool_choice", payload("type" to value("auto"), "disable_parallel_tool_use" to JsonPrimitive(true)))
                }
            }
            GatewayWire.Responses -> {
                body.add("input", messages)
                body.addProperty("instructions", instructions)
                body.addProperty("store", false)
                tokenLimit?.let { body.addProperty("max_output_tokens", it) }
                tool?.let {
                    val converted = it.deepCopy()
                    converted.addProperty("type", "function")
                    if (provider == GatewayProvider.ChatGPT) {
                        converted.addProperty("strict", true)
                        strictSchema(converted.getAsJsonObject("parameters"))
                        body.add("tools", array(payload("type" to value("namespace"), "name" to value("planner"),
                            "description" to value("Task proposal cards."), "tools" to array(converted))))
                    } else {
                        converted.addProperty("strict", false)
                        body.add("tools", array(converted))
                    }
                    body.addProperty("parallel_tool_calls", false)
                }
            }
        }
        val headers = headers(connection) + if (provider.streams) mapOf("Accept" to "text/event-stream") else emptyMap()
        val raw = request(connection.address + provider.path, headers, body.toString(), JSON_TYPE)
        return decodeProviderAnswer(raw, provider.wire)
    }

    private fun headers(connection: GatewayConnection): Map<String, String> = when {
        connection.kind == GatewayProvider.GigaChat -> mapOf("Authorization" to "Bearer " + gigaToken(connection))
        connection.kind == GatewayProvider.Yandex -> mapOf("Authorization" to "Api-Key ${connection.key}",
            "OpenAI-Project" to requireNotNull(connection.project))
        connection.kind.wire == GatewayWire.Messages -> mapOf("x-api-key" to connection.key, "anthropic-version" to "2023-06-01")
        else -> buildMap {
            put("Authorization", "Bearer ${connection.key}")
            if (connection.kind == GatewayProvider.ChatGPT) put("User-Agent", "Tasks")
            if (connection.kind == GatewayProvider.Copilot) connection.account?.let { put("X-Tasks-Account", it) }
        }
    }

    @Synchronized
    private fun gigaToken(connection: GatewayConnection): String {
        val scope = connection.gigaScope ?: GigaScope.Personal
        val identity = connection.key to scope
        val now = System.currentTimeMillis()
        gigaTokens[identity]?.takeIf { it.expires > now + 30_000 }?.let { return it.token }
        val raw = request("https://ngw.devices.sberbank.ru:9443/api/v2/oauth",
            mapOf("Authorization" to "Basic ${connection.key}", "RqUID" to newId()),
            "scope=${scope.wire}", FORM_TYPE)
        val root = JsonParser.parseString(raw).asJsonObject
        val token = requireNotNull(root.string("access_token"))
        val expires = root["expires_at"].asLong
        gigaTokens.entries.removeAll { it.value.expires <= now }
        gigaTokens[identity] = GigaAccess(token, expires)
        return token
    }

    private fun objectRequest(url: String, headers: Map<String, String>) =
        JsonParser.parseString(request(url, headers, null, JSON_TYPE)).asJsonObject

    private fun catalog(root: JsonObject, provider: GatewayProvider): List<GatewayModel> {
        val rows = root.getAsJsonArray("data") ?: root.getAsJsonArray("models") ?: error("Missing model catalog")
        return rows.mapNotNull { raw ->
            val item = raw.asJsonObject
            if (provider == GatewayProvider.ChatGPT && item.string("visibility") != "list") return@mapNotNull null
            val modelId = if (provider == GatewayProvider.ChatGPT) item.string("slug") else item.string("id")
            val id = modelId?.takeIf { it.isNotBlank() && it.length <= 200 }
                ?: return@mapNotNull null
            val capabilities = item["capabilities"] as? JsonObject
            val info = item["model_info"] as? JsonObject
            val tools = (item["supports_function_calling"] ?: capabilities?.get("tools") ?: info?.get("supports_function_calling"))
                ?.takeIf { it is JsonPrimitive && it.isBoolean }?.asBoolean
                ?: (item["supported_parameters"] as? JsonArray)?.any { it.asString == "tools" }
                ?: provider.tools(id)
            GatewayModel(id, tools, item.string("name") ?: item.string("display_name") ?: item.string("title"))
        }.distinctBy(GatewayModel::id).also { require(it.isNotEmpty()) }
    }
}

internal fun decodeProviderAnswer(raw: String, wire: GatewayWire): GatewayAnswer {
    if (!raw.trimStart().startsWith("{")) {
        val events = raw.lineSequence().filter { it.startsWith("data:") }.map { it.removePrefix("data:").trim() }
            .filter { it.startsWith("{") }.map { JsonParser.parseString(it).asJsonObject }
        if (wire == GatewayWire.Responses) {
            for (event in events) {
                when (event.string("type")) {
                    "response.completed" -> return decodeOutput(event.getAsJsonObject("response"))
                    "error", "response.failed", "response.incomplete" -> {
                        val error = event.getAsJsonObject("response")?.getAsJsonObject("error")
                            ?: event.getAsJsonObject("error") ?: event
                        val code = error.string("code") ?: "incomplete"
                        val status = when (code) {
                            "subscription_sharing_usage_limit_exceeded", "rate_limit_exceeded" -> 429
                            "subscription_sharing_user_not_eligible" -> 403
                            else -> 502
                        }
                        throw ServerFailure(status, code)
                    }
                }
            }
            error("Incomplete response")
        }
        val text = StringBuilder()
        val name = StringBuilder()
        val args = StringBuilder()
        var finished = false
        events.forEach { event ->
            val choice = event.getAsJsonArray("choices")?.singleOrNull()?.asJsonObject ?: return@forEach
            if (choice.string("finish_reason") in listOf("stop", "tool_calls")) finished = true
            val delta = choice.getAsJsonObject("delta") ?: return@forEach
            delta.string("content")?.let(text::append)
            val calls = delta.getAsJsonArray("tool_calls")
            check(calls == null || calls.size() <= 1)
            calls?.singleOrNull()?.asJsonObject?.getAsJsonObject("function")?.let {
                it.string("name")?.let(name::append)
                it["arguments"]?.takeUnless(JsonElement::isJsonNull)?.let { field -> args.append(argumentText(field)) }
            }
        }
        check(finished)
        return GatewayAnswer(text.toString(), name.toString().ifBlank { null }, args.toString().ifBlank { null })
    }
    val root = JsonParser.parseString(raw).asJsonObject
    return when (wire) {
        GatewayWire.Chat -> {
            val message = root.getAsJsonArray("choices").first().asJsonObject.getAsJsonObject("message")
            val calls = message.getAsJsonArray("tool_calls")
            check(calls == null || calls.size() <= 1)
            val function = calls?.singleOrNull()?.asJsonObject?.getAsJsonObject("function")
                ?: message["function_call"]?.takeIf(JsonElement::isJsonObject)?.asJsonObject
            GatewayAnswer(message.string("content").orEmpty(), function?.string("name"),
                function?.get("arguments")?.let(::argumentText))
        }
        GatewayWire.Messages -> {
            val content = root.getAsJsonArray("content").map(JsonElement::getAsJsonObject)
            val text = content.filter { it.string("type") == "text" }.joinToString("\n") { it.string("text").orEmpty() }
            val calls = content.filter { it.string("type") == "tool_use" }
            check(calls.size <= 1)
            val call = calls.singleOrNull()
            GatewayAnswer(text, call?.string("name"), call?.get("input")?.let(::argumentText))
        }
        GatewayWire.Responses -> decodeOutput(root)
    }
}

private fun decodeOutput(root: JsonObject): GatewayAnswer {
    check(root.string("status") == null || root.string("status") == "completed")
    val output = root.getAsJsonArray("output").map(JsonElement::getAsJsonObject)
    val text = output.filter { it.string("type") == "message" }.flatMap { message ->
        message.getAsJsonArray("content").map(JsonElement::getAsJsonObject)
    }.mapNotNull {
        when (it.string("type")) {
            "output_text" -> it.string("text")
            "refusal" -> it.string("refusal")
            else -> null
        }
    }.joinToString("\n")
    val calls = output.filter { it.string("type") == "function_call" }
    check(calls.size <= 1)
    val call = calls.singleOrNull()
    val name = call?.string("name")
    check(call?.string("namespace") in listOf(null, "planner"))
    return GatewayAnswer(text, if (name == "planner.propose_changes") "propose_changes" else name,
        call?.get("arguments")?.let(::argumentText))
}

private fun strictSchema(schema: JsonObject) {
    schema.getAsJsonObject("items")?.let(::strictSchema)
    val properties = schema.getAsJsonObject("properties") ?: return
    val required = schema.getAsJsonArray("required")?.map(JsonElement::getAsString).orEmpty().toSet()
    schema.addProperty("additionalProperties", false)
    schema.add("required", JsonArray().apply { properties.keySet().forEach { add(it) } })
    properties.entrySet().forEach { (key, entry) ->
        val field = entry.asJsonObject
        strictSchema(field)
        if (key !in required) {
            val type = field.string("type")
            if (type != null) field.add("type", JsonArray().apply { add(type); add("null") })
        }
    }
}

private fun argumentText(element: JsonElement) =
    if (element is JsonPrimitive && element.isString) element.asString else element.toString()

private fun message(role: String, content: String) = payload("role" to value(role), "content" to value(content))
private fun array(element: JsonElement) = JsonArray().apply { add(element) }
internal const val JSON_TYPE = "application/json; charset=utf-8"
internal const val FORM_TYPE = "application/x-www-form-urlencoded"
