package local.planner.android

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.google.gson.JsonArray
import com.google.gson.JsonObject
import java.io.IOException
import java.net.URI
import java.net.URL
import java.security.KeyStore
import java.security.MessageDigest
import java.time.Instant
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.net.ssl.HttpsURLConnection

internal const val MAX_BATCH_BYTES = 4 * 1024 * 1024
internal const val DEFAULT_ORIGIN = "https://planner-server.tail037e91.ts.net"

internal data class Snapshot(
    val protocolVersion: Int,
    val libraryId: String,
    val cursor: String,
    val initialized: Boolean,
    val entities: List<Entity>,
)

internal data class Change(val revision: String, val entity: Entity)
internal data class Changes(val libraryId: String, val changes: List<Change>, val nextCursor: String, val hasMore: Boolean)
internal data class Problem(val code: String)
internal data class MutationResult(val operationId: String?, val status: String, val entity: Entity?, val error: Problem?)
private data class Results(val results: List<MutationResult>)
private data class ErrorBody(val error: Problem?)
private data class Tokens(val accessToken: String, val refreshToken: String, val expiresIn: Int)
private data class User(val email: String, val libraryId: String)
private data class Config(val protocolVersion: Int, val serverTime: String)
private data class Challenge(val challengeId: String)

internal enum class AccountRequest(val path: String) {
    Register("/v1/auth/register"),
    Resend("/v1/auth/resend-verification"),
    Reset("/v1/auth/password-reset/request"),
}

internal class ServerFailure(val status: Int, val code: String, val retryAfter: Long? = null) : IOException(code)

internal fun serverOrigin(address: String): String {
    val uri = URI(address.trim())
    require(uri.scheme.equals("https", ignoreCase = true) && uri.host != null &&
        uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null &&
        uri.rawPath in listOf("", "/") && (uri.port == -1 || uri.port in 1..65535))
    return URI("https", null, uri.host.lowercase(), uri.port.takeUnless { it == 443 } ?: -1, null, null, null).toString()
}

internal fun mutationBatch(queued: List<Mutation>): List<Mutation> {
    var remaining = MAX_BATCH_BYTES - 32
    return queued.take(100).takeWhile { mutation ->
        remaining -= mutation.wire().toString().toByteArray().size + 1
        remaining >= 0
    }
}

internal interface Transport {
    fun request(origin: String, path: String, body: JsonObject? = null, token: String? = null): String
}

internal class HttpsTransport : Transport {
    override fun request(origin: String, path: String, body: JsonObject?, token: String?): String =
        exchange(origin + path, token?.let { mapOf("Authorization" to "Bearer $it") }.orEmpty(), body?.toString())

    fun exchange(
        address: String, headers: Map<String, String>, body: String? = null,
        contentType: String = "application/json; charset=utf-8", limit: Int = Int.MAX_VALUE,
        readTimeoutMillis: Int = 25_000,
    ): String {
        val connection = URL(address).openConnection() as HttpsURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000
            connection.readTimeout = readTimeoutMillis
            connection.setRequestProperty("Accept", "application/json")
            headers.forEach(connection::setRequestProperty)
            if (body != null) {
                val bytes = body.toByteArray()
                connection.requestMethod = "POST"
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", contentType)
                connection.setFixedLengthStreamingMode(bytes.size)
                connection.outputStream.use { it.write(bytes) }
            }
            val status = connection.responseCode
            if (status in 200..299) {
                return connection.inputStream.bufferedReader(Charsets.UTF_8).use { reader ->
                    if (limit == Int.MAX_VALUE) reader.readText() else buildString {
                        val buffer = CharArray(8192)
                        var count = reader.read(buffer)
                        while (count >= 0) {
                            if (length + count > limit) throw IOException("Response too large")
                            append(buffer, 0, count)
                            count = reader.read(buffer)
                        }
                    }
                }
            }
            val response = connection.errorStream?.bufferedReader(Charsets.UTF_8)?.use { reader ->
                val buffer = CharArray(16_384)
                val count = reader.read(buffer)
                if (count > 0) String(buffer, 0, count) else ""
            }
            val error = runCatching { json.fromJson(response, ErrorBody::class.java)?.error }.getOrNull()
            throw ServerFailure(status, error?.code ?: "http_error", connection.getHeaderField("Retry-After")?.toLongOrNull())
        } finally {
            connection.disconnect()
        }
    }
}

internal class CredentialVault(private val alias: String = "planner.refresh.v1") {
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        return (store.getKey(alias, null) as? SecretKey)
            ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
                init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
                generateKey()
            }
    }

    fun seal(profile: Profile, credential: String) = seal(profile.workspace, credential)
    fun open(profile: Profile, credential: String) = open(profile.workspace, credential)

    fun seal(scope: String, credential: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(scope.toByteArray())
        return Base64.encodeToString(cipher.iv + cipher.doFinal(credential.toByteArray()), Base64.NO_WRAP)
    }

    fun open(scope: String, credential: String): String {
        val bytes = Base64.decode(credential, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, 12))
        cipher.updateAAD(scope.toByteArray())
        return cipher.doFinal(bytes, 12, bytes.size - 12).toString(Charsets.UTF_8)
    }
}

internal class CloudSync(
    private val store: PlannerStore,
    private val transport: Transport = HttpsTransport(),
) {
    private val vault = CredentialVault()
    private var session: Pair<Profile, String>? = null
    private var expiry = 0L

    @Volatile
    var clockOffset = 0L
        private set

    fun login(origin: String, email: String, password: String, deviceName: String, initializeEmpty: Boolean = false) {
        configure(origin)
        val tokens = request<Tokens>(origin, "/v1/auth/login", payload(
            "email" to value(email.trim()), "password" to value(password),
            "deviceId" to value(store.deviceId()), "deviceName" to value(deviceName.ifBlank { "Android" }.take(100)),
        ))
        val user = request<User>(origin, "/v1/me", token = tokens.accessToken)
        val hostKey = MessageDigest.getInstance("SHA-256").digest(origin.toByteArray())
            .joinToString("") { "%02x".format(it) }
        val profile = Profile(origin, user.email, user.libraryId, "$hostKey:${user.libraryId}")
        store.beginConnection(Connection(profile, vault.seal(profile, tokens.refreshToken), initializeEmpty = initializeEmpty))
        remember(profile, tokens)
        firstSync(profile, initializeEmpty)
    }

    fun challenge(origin: String, action: AccountRequest, email: String, password: String): String {
        val body = payload("email" to value(email.trim()))
        if (action == AccountRequest.Register) body.add("password", value(password))
        return request<Challenge>(origin, action.path, body).challengeId
    }

    fun confirm(origin: String, challenge: String, code: String, password: String, reset: Boolean) {
        val path = if (reset) "/v1/auth/password-reset/confirm" else "/v1/auth/verify-email"
        val passwordField = if (reset) "newPassword" else "password"
        request<JsonObject>(origin, path, payload(
            "challengeId" to value(challenge), "code" to value(code), passwordField to value(password),
        ))
    }

    fun firstSync(profile: Profile, initializeEmpty: Boolean) {
        configure(profile.origin)
        var snapshot = authorized<Snapshot>(profile, "/v1/sync/snapshot")
        if (!snapshot.initialized && initializeEmpty) {
            check(snapshot.libraryId == profile.libraryId && snapshot.protocolVersion == 1)
            val id = newId()
            try {
                authorized<JsonObject>(profile, "/v1/library/imports", payload("importId" to value(id)))
                authorized<JsonObject>(profile, "/v1/library/imports/$id/commit", JsonObject())
            } catch (failure: ServerFailure) {
                if (failure.code != "library_exists") throw failure
            }
            snapshot = authorized(profile, "/v1/sync/snapshot")
        }
        validateSnapshot(snapshot, profile.libraryId)
        store.activate(profile, snapshot)
    }

    fun synchronize(profile: Profile) {
        configure(profile.origin)
        pull(profile)
        while (true) {
            val batch = store.batch(profile.workspace)
            if (batch.isEmpty()) break
            val mutations = JsonArray().apply { batch.forEach { add(it.wire()) } }
            val results = authorized<Results>(profile, "/v1/sync/mutations", payload("mutations" to mutations)).results
            check(results.size == batch.size && results.zip(batch).all { (result, sent) ->
                result.operationId == sent.operationId && when (result.status) {
                    "rejected" -> result.error != null
                    "applied", "deleted" -> result.entity?.let { it.id == sent.entityId && it.type == sent.entityType } == true
                    else -> false
                }
            })
            store.accept(profile.workspace, results)
        }
        pull(profile)
    }

    fun logout(profile: Profile) {
        try {
            authorized<JsonObject>(profile, "/v1/auth/logout", JsonObject())
        } finally {
            session = null
            store.disconnect(profile)
        }
    }

    private fun configure(origin: String) {
        val config = request<Config>(origin, "/v1/config")
        if (config.protocolVersion != 1) throw ServerFailure(409, "incompatible_protocol")
        clockOffset = Instant.parse(config.serverTime).toEpochMilli() - System.currentTimeMillis()
    }

    private fun pull(profile: Profile) {
        var cursor = store.cursor(profile.workspace)
        if (cursor != null) {
            try {
                while (true) {
                    val page = authorized<Changes>(profile, "/v1/sync/changes?cursor=$cursor")
                    val previous = requireNotNull(cursor).toLong()
                    val next = page.nextCursor.toLong()
                    check(page.libraryId == profile.libraryId && next >= previous && (!page.hasMore || next > previous))
                    check(page.changes.all { it.entity.revision == it.revision && it.revision.toLong() in (previous + 1)..next })
                    store.changes(profile.workspace, page.changes.map(Change::entity), page.nextCursor)
                    if (!page.hasMore) return
                    cursor = page.nextCursor
                }
            } catch (failure: ServerFailure) {
                if (failure.code !in listOf("cursor_expired", "invalid_cursor")) throw failure
            }
        }
        val snapshot = authorized<Snapshot>(profile, "/v1/sync/snapshot")
        validateSnapshot(snapshot, profile.libraryId)
        store.snapshot(profile.workspace, snapshot)
    }

    private fun validateSnapshot(snapshot: Snapshot, libraryId: String) {
        check(snapshot.libraryId == libraryId)
        if (snapshot.protocolVersion != 1) throw ServerFailure(409, "incompatible_protocol")
        if (!snapshot.initialized) throw ServerFailure(409, "library_not_initialized")
        val cursor = snapshot.cursor.toLong()
        check(cursor >= 0 && snapshot.entities.all { it.revision.toLong() in 0..cursor })
    }

    private fun remember(profile: Profile, tokens: Tokens) {
        session = profile to tokens.accessToken
        expiry = System.nanoTime() + (tokens.expiresIn - 30).coerceAtLeast(0) * 1_000_000_000L
    }

    private fun access(profile: Profile): String {
        session?.takeIf { it.first == profile && System.nanoTime() < expiry }?.let { return it.second }
        val credential = store.connection()?.takeIf { it.profile == profile && !it.refreshing }?.credential
        if (credential == null) {
            store.disconnect(profile)
            throw ServerFailure(401, "sign_in_required")
        }
        val refreshToken = try {
            vault.open(profile, credential)
        } catch (_: Exception) {
            store.disconnect(profile)
            throw ServerFailure(401, "sign_in_required")
        }
        // После потери ответа повтор старого токена может отозвать сессию.
        store.credential(profile, credential, refreshing = true)
        try {
            val tokens = request<Tokens>(profile.origin, "/v1/auth/refresh", payload("refreshToken" to value(refreshToken)))
            store.credential(profile, vault.seal(profile, tokens.refreshToken))
            remember(profile, tokens)
            return tokens.accessToken
        } catch (failure: Exception) {
            if (failure is ServerFailure && failure.status == 429) {
                store.credential(profile, credential)
                throw failure
            }
            store.disconnect(profile)
            throw ServerFailure(401, "sign_in_required")
        }
    }

    private inline fun <reified T> authorized(profile: Profile, path: String, body: JsonObject? = null): T {
        val access = access(profile)
        return try {
            request<T>(profile.origin, path, body, access)
        } catch (failure: ServerFailure) {
            if (failure.status != 401) throw failure
            session = null
            try {
                request<T>(profile.origin, path, body, access(profile))
            } catch (retry: ServerFailure) {
                if (retry.status == 401) {
                    session = null
                    store.disconnect(profile)
                }
                throw retry
            }
        }
    }

    private inline fun <reified T> request(origin: String, path: String, body: JsonObject? = null, token: String? = null): T =
        json.fromJson(transport.request(origin, path, body, token), T::class.java)
}
