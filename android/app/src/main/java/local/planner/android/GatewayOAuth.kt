package local.planner.android

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.math.BigInteger
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.RSAPublicKeySpec
import java.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

internal data class ChatGptGrant(val clientId: String, val subject: String, val refreshToken: String, val expiresAt: Long)
internal data class OAuthCallback(val code: String, val clientId: String?)

internal class GatewayOAuth(private val request: GatewayRequest = providerRequest()) {
    suspend fun openRouter(open: (String) -> Unit): GatewayConnection {
        val state = random()
        val verifier = random()
        val grant = browserGrant("/auth/openrouter/$state", state, open) { redirect ->
            url("https://openrouter.ai/auth", mapOf(
                "callback_url" to redirect, "code_challenge" to challenge(verifier),
                "code_challenge_method" to "S256", "state" to state, "key_label" to "Tasks for Android",
            ))
        }
        return withContext(Dispatchers.IO) {
            val address = GatewayProvider.OpenRouter.bases.single()
            val body = payload("code" to value(grant.code), "code_verifier" to value(verifier),
                "code_challenge_method" to value("S256"))
            val result = read(request("$address/auth/keys", emptyMap(), body.toString(), JSON_TYPE))
            GatewayConnection(address, requireNotNull(result.string("key")), "", false, GatewayProvider.OpenRouter)
        }
    }

    suspend fun chatGpt(hostId: String, open: (String) -> Unit): GatewayConnection {
        val state = random()
        val nonce = random()
        val verifier = random()
        var redirect = ""
        val grant = browserGrant("/auth/callback", state, open) { callback ->
            redirect = callback
            url("$Issuer/api/accounts/authorize", mapOf(
                "client_id" to "dynamic_agent_client", "ext_agent_host_id" to hostId, "response_type" to "code",
                "redirect_uri" to callback, "scope" to "openid profile email offline_access resource.invoke $PlanScope",
                "resource" to Resource, "state" to state, "nonce" to nonce, "code_challenge_method" to "S256",
                "code_challenge" to challenge(verifier), "agent_name_hint" to "Tasks",
            ))
        }
        val id = grant.clientId?.takeIf { it.isNotBlank() && it.length <= 256 && it != "dynamic_agent_client" }
            ?: error("Missing OAuth client")
        return withContext(Dispatchers.IO) {
            val tokens = tokens(mapOf("grant_type" to "authorization_code", "client_id" to id, "code" to grant.code,
                "code_verifier" to verifier, "redirect_uri" to redirect, "resource" to Resource))
            val keys = read(request("$Issuer/.well-known/jwks.json", emptyMap(), null, JSON_TYPE))
            val subject = verifyChatGptIdentity(requireNotNull(tokens.string("id_token")), keys, id, nonce)
            check(tokens.string("scope")?.split(' ')?.contains(PlanScope) == true)
            val credentials = ChatGptGrant(id, subject, refresh(tokens), expires(tokens))
            GatewayConnection(Resource, access(tokens), "", false, GatewayProvider.ChatGPT, chatGpt = credentials)
        }
    }

    fun refreshChatGpt(connection: GatewayConnection): GatewayConnection {
        val grant = requireNotNull(connection.chatGpt)
        val updated = tokens(mapOf("grant_type" to "refresh_token", "client_id" to grant.clientId,
            "refresh_token" to grant.refreshToken, "resource" to Resource))
        check(updated.string("scope")?.split(' ')?.contains(PlanScope) != false)
        return connection.copy(key = access(updated), chatGpt = grant.copy(refreshToken = refresh(updated), expiresAt = expires(updated)))
    }

    private fun tokens(fields: Map<String, String>) =
        read(request("$Issuer/api/accounts/oauth/token", emptyMap(), form(fields), FORM_TYPE))

    private fun access(tokens: JsonObject): String {
        check(tokens.string("token_type").equals("bearer", ignoreCase = true))
        return requireNotNull(tokens.string("access_token")).also { require(it.isNotBlank()) }
    }

    private fun refresh(tokens: JsonObject): String =
        requireNotNull(tokens.string("refresh_token")).also { require(it.isNotBlank()) }

    private fun expires(tokens: JsonObject): Long {
        val seconds = tokens["expires_in"].asLong
        require(seconds in 1..31_536_000)
        return System.currentTimeMillis() + seconds * 1000
    }

    private companion object {
        const val Issuer = "https://auth.openai.com"
        const val Resource = "https://api.openai.com/v1"
        const val PlanScope = "chatgpt.tokens.use.direct"
    }
}

internal fun verifyChatGptIdentity(
    token: String, keys: JsonObject, clientId: String, nonce: String, nowSeconds: Long = System.currentTimeMillis() / 1000,
): String {
    val parts = token.split('.')
    require(token.length <= 32_768 && parts.size == 3)
    val decoder = Base64.getUrlDecoder()
    val header = read(String(decoder.decode(parts[0]), Charsets.UTF_8))
    val kid = requireNotNull(header.string("kid"))
    require(header.string("alg") == "RS256")
    val jwk = keys.getAsJsonArray("keys").map(JsonElement::getAsJsonObject).first {
        it.string("kid") == kid && it.string("kty") == "RSA" &&
            it.string("alg") in listOf(null, "RS256") && it.string("use") in listOf(null, "sig")
    }
    val n = decoder.decode(requireNotNull(jwk.string("n")))
    val e = decoder.decode(requireNotNull(jwk.string("e")))
    require(n.size in 256..1024 && e.size in 1..8)
    val publicKey = KeyFactory.getInstance("RSA").generatePublic(RSAPublicKeySpec(BigInteger(1, n), BigInteger(1, e)))
    val valid = Signature.getInstance("SHA256withRSA").run {
        initVerify(publicKey)
        update((parts[0] + "." + parts[1]).toByteArray(Charsets.UTF_8))
        verify(decoder.decode(parts[2]))
    }
    require(valid)
    val claims = read(String(decoder.decode(parts[1]), Charsets.UTF_8))
    val audiences = claims["aud"]?.let {
        if (it.isJsonArray) it.asJsonArray.map(JsonElement::getAsString) else listOf(it.asString)
    }.orEmpty()
    val authorized = claims.string("azp")
    require(claims.string("iss") == "https://auth.openai.com" && clientId in audiences &&
        (audiences.size == 1 || authorized == clientId) && (authorized == null || authorized == clientId) &&
        claims.string("nonce") == nonce && claims["exp"].asDouble.isFinite() &&
        claims["exp"].asDouble > nowSeconds - 5)
    return requireNotNull(claims.string("sub")).also { require(it.isNotBlank()) }
}

internal fun parseGatewayCallback(line: String, path: String, state: String): OAuthCallback? {
    val parts = line.trimEnd('\r').split(' ')
    if (parts.size != 3 || parts[0] != "GET" || !parts[2].startsWith("HTTP/") ||
        !parts[1].startsWith("$path?")) return null
    val uri = URI("http://127.0.0.1" + parts[1])
    if (uri.path != path || uri.rawFragment != null) return null
    val query = uri.rawQuery.orEmpty().split('&').mapNotNull { pair ->
        val delimiter = pair.indexOf('=')
        if (delimiter <= 0) null else
            URLDecoder.decode(pair.substring(0, delimiter), "UTF-8") to URLDecoder.decode(pair.substring(delimiter + 1), "UTF-8")
    }.groupBy({ it.first }, { it.second })
    if (query["state"]?.singleOrNull() != state) return null
    if ("error" in query) throw IOException("Authorization was cancelled")
    val code = query["code"]?.singleOrNull()?.takeIf { it.isNotBlank() && it.length <= 4096 }
        ?: throw IOException("Invalid authorization response")
    val ids = query["client_id"].orEmpty()
    require(ids.size <= 1)
    return OAuthCallback(code, ids.singleOrNull())
}

private suspend fun browserGrant(
    path: String, state: String, open: (String) -> Unit, authorizeUrl: (String) -> String,
): OAuthCallback = withContext(Dispatchers.IO) {
    ServerSocket(0, 4, InetAddress.getByName("127.0.0.1")).use { server ->
        server.soTimeout = 1_000
        val redirect = "http://127.0.0.1:${server.localPort}$path"
        withContext(Dispatchers.Main) { open(authorizeUrl(redirect)) }
        val deadline = System.nanoTime() + 180_000_000_000L
        while (System.nanoTime() < deadline) {
            ensureActive()
            val socket = try { server.accept() } catch (_: SocketTimeoutException) { continue }
            socket.use {
                it.soTimeout = 1_000
                val line = try { readRequestLine(it.getInputStream()) } catch (_: IOException) { return@use }
                val grant = try { parseGatewayCallback(line, path, state) } catch (failure: Exception) {
                    if (failure is IOException) {
                        replyToBrowser(it.getOutputStream(), "Authorization was not completed.")
                        throw failure
                    }
                    return@use
                } ?: return@use
                replyToBrowser(it.getOutputStream(), "Return to Tasks to finish connecting.")
                return@withContext grant
            }
        }
        throw SocketTimeoutException("Authorization timed out")
    }
}

private fun readRequestLine(input: java.io.InputStream): String {
    val line = ByteArrayOutputStream()
    val deadline = System.nanoTime() + 1_000_000_000L
    while (line.size() < 8192 && System.nanoTime() < deadline) {
        val byte = input.read()
        if (byte == 10) return line.toString("UTF-8")
        if (byte < 0) break
        line.write(byte)
    }
    throw IOException("Invalid callback request")
}

private fun replyToBrowser(output: java.io.OutputStream, text: String) {
    val bytes = text.toByteArray(Charsets.UTF_8)
    runCatching {
        output.write(("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n" +
            "Cache-Control: no-store\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n").toByteArray())
        output.write(bytes)
        output.flush()
    }
}

private fun read(raw: String): JsonObject = JsonParser.parseString(raw).asJsonObject
private fun random() = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).apply { SecureRandom().nextBytes(this) })
private fun challenge(verifier: String) =
    Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))
private fun url(base: String, query: Map<String, String>) = "$base?${form(query)}"
private fun form(fields: Map<String, String>) =
    fields.entries.joinToString("&") { "${it.key}=${URLEncoder.encode(it.value, "UTF-8")}" }
