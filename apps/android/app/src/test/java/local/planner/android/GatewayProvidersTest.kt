package local.planner.android

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.interfaces.RSAPublicKey
import java.util.Base64

class GatewayProvidersTest {
    private val tool = read("""{"name":"propose_changes","description":"Review changes","parameters":{"type":"object"}}""")

    @Test
    fun messagesProtocolUsesAnthropicHeadersAndDecodesToolUse() {
        val gateway = ProviderGateway { url, headers, body, _ ->
            assertEquals("https://api.anthropic.com/v1/messages", url)
            assertEquals("key", headers["x-api-key"])
            assertEquals("2023-06-01", headers["anthropic-version"])
            assertFalse(headers.containsKey("Authorization"))
            val outgoing = read(requireNotNull(body))
            assertEquals("system instructions", outgoing.string("system"))
            assertEquals("object", outgoing.getAsJsonArray("tools").first().asJsonObject
                .getAsJsonObject("input_schema").string("type"))
            """{"content":[{"type":"text","text":"Review"},{"type":"tool_use","name":"propose_changes","input":{"message":"Done"}}]}"""
        }
        val answer = gateway.completion(connection(GatewayProvider.Claude), "system instructions", emptyList(), "Question", tool)
        assertEquals("Review", answer.text)
        assertEquals("propose_changes", answer.name)
        assertEquals("Done", read(requireNotNull(answer.arguments)).string("message"))
    }

    @Test
    fun responsesProtocolKeepsTheProviderEndpointAndDecodesCompletedOutput() {
        val gateway = ProviderGateway { url, headers, body, _ ->
            assertEquals("https://api.deepseek.com/responses", url)
            assertEquals("Bearer key", headers["Authorization"])
            val outgoing = read(requireNotNull(body))
            assertFalse(outgoing["store"].asBoolean)
            assertEquals("function", outgoing.getAsJsonArray("tools").first().asJsonObject.string("type"))
            """{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Review this"}]},
                {"type":"function_call","name":"propose_changes","arguments":"{\"message\":\"Draft\"}"}]}"""
        }
        val answer = gateway.completion(connection(GatewayProvider.DeepSeek), "Instructions", emptyList(), "Question", tool)
        assertEquals("Review this", answer.text)
        assertEquals("Draft", read(requireNotNull(answer.arguments)).string("message"))
    }

    @Test
    fun yandexValidatesFolderScopedModelWithApiKey() {
        val gateway = ProviderGateway { url, headers, body, _ ->
            assertEquals("https://ai.api.cloud.yandex.net/v1/chat/completions", url)
            assertEquals("Api-Key key", headers["Authorization"])
            assertEquals("folder12345", headers["OpenAI-Project"])
            assertEquals("gpt://folder12345/yandexgpt/latest", read(requireNotNull(body)).string("model"))
            """{"choices":[{"message":{"content":"OK"}}]}"""
        }
        val result = gateway.candidate(connection(GatewayProvider.Yandex).copy(project = "folder12345"), GatewayOptions())
        assertEquals("gpt://folder12345/yandexgpt/latest", result.models.single().id)
    }

    @Test
    fun gigaChatExchangesAuthorizationAndSupportsLegacyFunctionCalls() {
        var exchanges = 0
        val gateway = ProviderGateway { url, headers, body, type ->
            when {
                url.contains("/oauth") -> {
                    exchanges++
                    assertEquals(FORM_TYPE, type)
                    assertEquals("scope=GIGACHAT_API_B2B", body)
                    assertEquals("Basic key", headers["Authorization"])
                    assertTrue(headers.getValue("RqUID").isNotBlank())
                    """{"access_token":"short-lived","expires_at":${System.currentTimeMillis() + 600_000}}"""
                }
                url.endsWith("/models") -> {
                    assertEquals("Bearer short-lived", headers["Authorization"])
                    """{"data":[{"id":"GigaChat-2"}]}"""
                }
                else -> {
                    assertEquals("Bearer short-lived", headers["Authorization"])
                    val outgoing = read(requireNotNull(body))
                    assertEquals("auto", outgoing.string("function_call"))
                    assertFalse(outgoing.has("tools"))
                    """{"choices":[{"message":{"content":null,"function_call":{"name":"propose_changes",
                        "arguments":{"message":"Draft"}}}}]}"""
                }
            }
        }
        val profile = connection(GatewayProvider.GigaChat).copy(gigaScope = GigaScope.Business)
        assertEquals("GigaChat-2", gateway.candidate(profile, GatewayOptions()).models.single().id)
        assertEquals("propose_changes", gateway.completion(profile, "Instructions", emptyList(), "Question", tool).name)
        assertEquals(1, exchanges)
    }

    @Test
    fun copilotUsesBridgeAccountAndAssemblesStreamingToolArguments() {
        val bridge = "https://bridge.example/v1"
        val gateway = ProviderGateway { url, headers, body, _ ->
            if (url == "$bridge/models") {
                """{"account":"https://github.com|demo","data":[{"id":"model","supported_parameters":["tools"]}]}"""
            } else {
                assertEquals("$bridge/chat/completions", url)
                assertEquals("https://github.com|demo", headers["X-Tasks-Account"])
                assertTrue(read(requireNotNull(body))["stream"].asBoolean)
                """
                    data: {"choices":[{"delta":{"tool_calls":[{"function":{"name":"propose_changes","arguments":"{\"message\":"}}]}}]}

                    data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"\"Draft\"}"}}]}}]}

                    data: {"choices":[{"finish_reason":"tool_calls"}]}

                    data: [DONE]
                """.trimIndent()
            }
        }
        val candidate = gateway.candidate(GatewayConnection(bridge, "key", "model", true, GatewayProvider.Copilot), GatewayOptions())
        val result = gateway.completion(candidate.connection, "Instructions", emptyList(), "Question", tool)
        assertEquals("propose_changes", result.name)
        assertEquals("Draft", read(requireNotNull(result.arguments)).string("message"))
    }

    @Test
    fun chatGptUsesNamespacedStrictToolsAndReadsCompletedStream() {
        val gateway = ProviderGateway { url, headers, body, _ ->
            assertEquals("https://api.openai.com/v1/responses", url)
            assertEquals("text/event-stream", headers["Accept"])
            val outgoing = read(requireNotNull(body))
            val namespace = outgoing.getAsJsonArray("tools").first().asJsonObject
            assertEquals("planner", namespace.string("name"))
            assertTrue(namespace.getAsJsonArray("tools").first().asJsonObject["strict"].asBoolean)
            """data: {"type":"response.completed","response":{"status":"completed","output":[
                {"type":"function_call","namespace":"planner","name":"propose_changes","arguments":"{}"}]}}"""
                .replace("\n", "")
        }
        val answer = gateway.completion(connection(GatewayProvider.ChatGPT), "Instructions", emptyList(), "Question", tool)
        assertEquals("propose_changes", answer.name)
    }

    @Test
    fun browserCallbackRejectsWrongStateAndRepeatedCodes() {
        assertNull(parseGatewayCallback("GET /auth/callback?state=wrong&code=bad HTTP/1.1", "/auth/callback", "expected"))
        assertThrows(java.io.IOException::class.java) {
            parseGatewayCallback("GET /auth/callback?state=expected&code=a&code=b HTTP/1.1", "/auth/callback", "expected")
        }
        assertEquals(OAuthCallback("a+b", "app"),
            parseGatewayCallback("GET /auth/callback?state=expected&code=a%2Bb&client_id=app HTTP/1.1", "/auth/callback", "expected"))
    }

    @Test
    fun chatGptReauthorizationKeepsItsRegisteredClient() {
        val previous = "oaiapp_existing"
        assertEquals("oaiapp_existing", chatGptClientId(null, previous))
        assertEquals("oaiapp_existing", chatGptClientId("oaiapp_existing", previous))
        assertThrows(IllegalArgumentException::class.java) { chatGptClientId("oaiapp_different", previous) }
        assertThrows(IllegalArgumentException::class.java) { chatGptClientId(null, null) }
    }

    @Test
    fun chatGptKeepsTheIssuedRegistrationWhenTheSignInCodeIsRejected() {
        val oauth = GatewayOAuth { address, _, body, _ ->
            assertEquals("https://auth.openai.com/api/accounts/oauth/token", address)
            assertTrue(requireNotNull(body).contains("client_id=oaiapp_new"))
            throw ServerFailure(400, "invalid_grant")
        }
        val failure = assertThrows(ChatGptOAuthFailure::class.java) {
            runBlocking { oauth.exchangeChatGptCode("oaiapp_new", "expired", "verifier", "http://127.0.0.1:1455/auth/callback") }
        }
        assertEquals(ChatGptOAuthStage.Token, failure.stage)
        assertEquals("oaiapp_new", failure.retryClientId)
        assertEquals("oaiapp_new", chatGptClientId(null, failure.retryClientId))
        assertEquals(R.string.chat_oauth_code_expired, chatGptOAuthMessage(failure))
    }

    @Test
    fun chatGptReportsBrowserAndTokenTimeoutsSeparately() {
        val timeout = java.net.SocketTimeoutException()
        assertEquals(R.string.chat_oauth_timeout, chatGptOAuthMessage(ChatGptOAuthFailure(ChatGptOAuthStage.Browser, timeout)))
        assertEquals(R.string.chat_oauth_server_timeout, chatGptOAuthMessage(ChatGptOAuthFailure(ChatGptOAuthStage.Token, timeout)))
    }

    @Test
    fun chatGptRefreshKeepsTheRegistrationWhenPermissionExpires() {
        val connection = connection(GatewayProvider.ChatGPT).copy(
            chatGpt = ChatGptGrant("oaiapp_existing", "subject", "old-refresh", 0),
        )
        val revoked = GatewayOAuth { _, _, _, _ -> throw ServerFailure(400, "invalid_grant") }
            .refreshChatGpt(connection)
        assertEquals("", revoked.key)
        assertEquals("", revoked.chatGpt?.refreshToken)
        assertEquals("oaiapp_existing", revoked.chatGpt?.clientId)

        val temporary = GatewayOAuth { _, _, _, _ -> throw ServerFailure(503, "http_error") }
        assertThrows(ServerFailure::class.java) { temporary.refreshChatGpt(connection) }
    }

    @Test
    fun savedConnectionKeepsVisibilityAndModelCapabilitiesAfterCatalogRefresh() {
        val legacy = read("""{"address":"https://gateway.example/v1","key":"test","model":"first","tools":true}""")
        val saved = json.fromJson(legacy, GatewayConnection::class.java)
        assertTrue(saved.ready)
        assertEquals(listOf("first"), saved.visibleModels.map(GatewayModel::id))
        val first = GatewayModel("first", true)
        val second = GatewayModel("second", false)
        val third = GatewayModel("third", true)
        val hidden = saved.withCatalog(listOf(first, second)).copy(hiddenModelIds = setOf("first")).withVisibleModels()
        assertEquals("second", hidden.model)
        assertFalse(hidden.tools)
        val reloaded = json.fromJson(json.toJson(hidden), GatewayConnection::class.java)
            .withCatalog(listOf(first, second, third))
        assertEquals(listOf("second", "third"), reloaded.visibleModels.map(GatewayModel::id))
        assertEquals("second", reloaded.model)
        assertTrue(reloaded.copy(hiddenModelIds = emptySet()).withModel(first).tools)
    }

    @Test
    fun proposalsDefaultToOnForPreviouslyConnectedModelsUnlessUnsupported() {
        val stored = json.fromJson(read("""{
            "address":"https://gateway.example/v1","key":"test","model":"old","tools":false,
            "modelTools":{"old":false},
            "models":[{"id":"old"},{"id":"text-only","tools":false}]
        }"""), GatewayConnection::class.java)
        val connected = stored.withVisibleModels()
        assertTrue(connected.tools)
        assertFalse(connected.withModel(connected.catalog.last()).tools)
        assertFalse(connected.withCatalog(emptyList()).ready)
    }

    @Test
    fun chatGptIdentityRequiresValidSignatureAudienceAndNonce() {
        val pair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        val public = pair.public as RSAPublicKey
        val encoder = Base64.getUrlEncoder().withoutPadding()
        fun encoded(text: String) = encoder.encodeToString(text.toByteArray(Charsets.UTF_8))
        val modulus = encoder.encodeToString(public.modulus.toByteArray())
        val exponent = encoder.encodeToString(public.publicExponent.toByteArray())
        val keys = read("""{"keys":[{"kid":"test","kty":"RSA","n":"$modulus","e":"$exponent"}]}""")
        val header = encoded("""{"kid":"test","alg":"RS256"}""")
        val claims = encoded("""{"iss":"https://auth.openai.com","aud":"app","sub":"test-user","nonce":"test","exp":300}""")
        val signed = "$header.$claims"
        val signature = Signature.getInstance("SHA256withRSA").run {
            initSign(pair.private)
            update(signed.toByteArray())
            encoder.encodeToString(sign())
        }
        val jwt = "$signed.$signature"
        assertEquals("test-user", verifyChatGptIdentity(jwt, keys, "app", "test", nowSeconds = 100))
        assertThrows(IllegalArgumentException::class.java) {
            verifyChatGptIdentity(jwt, keys, "app", "other", nowSeconds = 100)
        }
        assertThrows(IllegalArgumentException::class.java) {
            verifyChatGptIdentity(jwt, keys, "other-app", "test", nowSeconds = 100)
        }
    }

    private fun read(raw: String): JsonObject = JsonParser.parseString(raw).asJsonObject

    private fun connection(provider: GatewayProvider) =
        GatewayConnection(provider.bases.first(), "key", "model", true, provider)
}
