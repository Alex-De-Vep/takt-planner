using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Takt.Core.Assistant;

public sealed record ChatGptCredential(string ClientId, string Subject, string? Email, string IdToken,
    string AccessToken, string RefreshToken, DateTimeOffset Expires, string Scope)
{
    public override string ToString() => "ChatGPT credential [redacted]";
}

public sealed class ChatGptOAuth(HttpClient? transport = null)
{
    private const string Issuer = "https://auth.openai.com";
    private const string Resource = "https://api.openai.com/v1";
    private const string RequiredScope = "chatgpt.tokens.use.direct";
    private static readonly HttpClient DefaultHttp = ChatClient.CreateHttpClient();
    private sealed record Tokens(
        [property: JsonPropertyName("access_token")] string AccessToken,
        [property: JsonPropertyName("refresh_token")] string? RefreshToken,
        [property: JsonPropertyName("id_token")] string? IdToken,
        [property: JsonPropertyName("expires_in")] int ExpiresIn,
        [property: JsonPropertyName("token_type")] string TokenType,
        [property: JsonPropertyName("scope")] string? Scope);

    public async Task<ChatGptCredential> SignInAsync(string hostId, ChatGptCredential? previous,
        Func<Uri, Task> openBrowser, CancellationToken cancellation)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromMinutes(4));
        string state = Random(), nonce = Random(), verifier = Random();
        try
        {
            var callback = await OpenRouterOAuth.ReceiveChatGptAsync(state, redirect =>
            {
                var parameters = new Dictionary<string, string>
                {
                    ["client_id"] = previous?.ClientId ?? "dynamic_agent_client",
                    ["ext_agent_host_id"] = hostId,
                    ["response_type"] = "code",
                    ["redirect_uri"] = redirect.AbsoluteUri,
                    ["scope"] = "openid profile email offline_access resource.invoke " + RequiredScope,
                    ["resource"] = Resource,
                    ["state"] = state,
                    ["nonce"] = nonce,
                    ["code_challenge_method"] = "S256",
                    ["code_challenge"] = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)))
                };
                if (previous is null) parameters["agent_name_hint"] = "Takt";
                else if (previous.Email is { } email) parameters["login_hint"] = email;
                string query = string.Join("&", parameters.Select(pair => Uri.EscapeDataString(pair.Key) + "=" + Uri.EscapeDataString(pair.Value)));
                return openBrowser(new Uri(Issuer + "/api/accounts/authorize?" + query));
            }, timeout.Token);

            string id = callback.ClientId ?? previous?.ClientId ?? "";
            if (!ValidClient(id) || previous is not null && previous.ClientId != id)
                throw new InvalidDataException("ChatGPT did not return the expected client registration.");
            var tokens = await ExchangeAsync(new()
            {
                ["grant_type"] = "authorization_code",
                ["client_id"] = id,
                ["code"] = callback.Code,
                ["code_verifier"] = verifier,
                ["redirect_uri"] = callback.Redirect.AbsoluteUri,
                ["resource"] = Resource
            }, timeout.Token);
            using var keys = await GetKeysAsync(timeout.Token);
            var identity = VerifyIdentity(tokens.IdToken, keys.RootElement, id, nonce);
            if (previous is not null && identity.Subject != previous.Subject)
                throw new InvalidOperationException("Sign in to the same ChatGPT account to renew this connection.");
            string scope = tokens.Scope ?? "";
            if (!AllowsPlan(scope) || !ValidToken(tokens.RefreshToken))
                throw new InvalidOperationException("Authorize ChatGPT plan usage in your browser to connect this account.");
            return new(id, identity.Subject, identity.Email, tokens.IdToken!, tokens.AccessToken,
                tokens.RefreshToken!, DateTimeOffset.UtcNow.AddSeconds(tokens.ExpiresIn), scope);
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        { throw new TimeoutException("ChatGPT sign-in timed out."); }
    }

    public async Task<ChatGptCredential> RefreshAsync(ChatGptCredential saved, CancellationToken cancellation)
    {
        if (!ValidClient(saved.ClientId) || !ValidToken(saved.RefreshToken) || !AllowsPlan(saved.Scope))
            throw new InvalidDataException("Sign in to ChatGPT again.");
        var tokens = await ExchangeAsync(new()
        {
            ["grant_type"] = "refresh_token",
            ["client_id"] = saved.ClientId,
            ["refresh_token"] = saved.RefreshToken,
            ["resource"] = Resource
        }, cancellation);
        string scope = tokens.Scope ?? saved.Scope;
        if (!AllowsPlan(scope) || !ValidToken(tokens.RefreshToken))
            throw new InvalidOperationException("This ChatGPT session needs a new sign-in.");
        return saved with { AccessToken = tokens.AccessToken, RefreshToken = tokens.RefreshToken!,
            Scope = scope, Expires = DateTimeOffset.UtcNow.AddSeconds(tokens.ExpiresIn) };
    }

    public static bool ValidToken(string? value) => value is { Length: > 0 and <= 16384 } &&
        !value.Any(c => char.IsControl(c) || char.IsWhiteSpace(c));
    private static bool ValidClient(string id) => id is { Length: > 0 and <= 256 } && id != "dynamic_agent_client" &&
        id.All(c => char.IsAsciiLetterOrDigit(c) || c is '_' or '-' or '.');
    private static bool AllowsPlan(string scopes) => scopes.Split(' ', StringSplitOptions.RemoveEmptyEntries).Contains(RequiredScope);
    private static string Random() => Base64Url(RandomNumberGenerator.GetBytes(32));
    private static string Base64Url(byte[] data) => Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    private static byte[] Decode(string value)
    {
        if (!value.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_')) throw IdentityProblem();
        return Convert.FromBase64String(value.Replace('-', '+').Replace('_', '/') + new string('=', (4 - value.Length % 4) % 4));
    }

    private async Task<Tokens> ExchangeAsync(Dictionary<string, string> values, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, Issuer + "/api/accounts/oauth/token")
        {
            Content = new FormUrlEncodedContent(values)
        };
        using var reply = await ReadJsonAsync(request, cancellation);
        var tokens = reply.RootElement.Deserialize<Tokens>();
        if (tokens is null || !ValidToken(tokens.AccessToken) || !string.Equals(tokens.TokenType, "Bearer", StringComparison.OrdinalIgnoreCase) ||
            tokens.ExpiresIn is < 1 or > 31536000)
            throw new InvalidDataException("ChatGPT returned an invalid token reply.");
        return tokens;
    }

    private async Task<JsonDocument> GetKeysAsync(CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, Issuer + "/.well-known/jwks.json");
        return await ReadJsonAsync(request, cancellation);
    }

    private async Task<JsonDocument> ReadJsonAsync(HttpRequestMessage request, CancellationToken cancellation)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        try
        {
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            using var response = await (transport ?? DefaultHttp).SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            if (response.StatusCode != HttpStatusCode.OK || response.RequestMessage?.RequestUri is { } returned && returned != request.RequestUri)
                throw new InvalidOperationException("ChatGPT could not authorize this connection. Sign in again.");
            const int limit = 96 * 1024;
            if (response.Content.Headers.ContentLength > limit) throw IdentityProblem();
            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
            using var data = new MemoryStream();
            var buffer = new byte[4096];
            int read;
            while ((read = await stream.ReadAsync(buffer, timeout.Token)) > 0)
            {
                if (data.Length + read > limit) throw IdentityProblem();
                data.Write(buffer, 0, read);
            }
            return JsonDocument.Parse(data.ToArray());
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        { throw new TimeoutException("The ChatGPT authorization service timed out."); }
    }

    private static (string Subject, string? Email) VerifyIdentity(string? token, JsonElement jwks, string client, string nonce)
    {
        try
        {
            if (token is not { Length: > 0 and <= 32768 }) throw IdentityProblem();
            string[] parts = token.Split('.');
            if (parts.Length != 3) throw IdentityProblem();
            using var header = JsonDocument.Parse(Decode(parts[0]));
            var keyId = Text(header.RootElement, "kid");
            if (Text(header.RootElement, "alg") != "RS256" || string.IsNullOrEmpty(keyId)) throw IdentityProblem();
            var keys = jwks.GetProperty("keys").EnumerateArray().Where(item =>
                Text(item, "kid") == keyId && Text(item, "kty") == "RSA" &&
                Text(item, "use") is (null or "sig") && Text(item, "alg") is (null or "RS256")).ToArray();
            if (keys.Length != 1) throw IdentityProblem();
            var modulus = Decode(Text(keys[0], "n") ?? "");
            var exponent = Decode(Text(keys[0], "e") ?? "");
            if (modulus.Length is < 256 or > 1024 || exponent.Length is < 1 or > 8) throw IdentityProblem();
            using var rsa = RSA.Create();
            rsa.ImportParameters(new RSAParameters { Modulus = modulus, Exponent = exponent });
            if (!rsa.VerifyData(Encoding.ASCII.GetBytes(parts[0] + "." + parts[1]), Decode(parts[2]), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1))
                throw IdentityProblem();

            using var payload = JsonDocument.Parse(Decode(parts[1]));
            var claims = payload.RootElement;
            var audience = claims.GetProperty("aud");
            string?[] values = audience.ValueKind == JsonValueKind.Array
                ? audience.EnumerateArray().Select(value => value.GetString()).ToArray()
                : [audience.GetString()];
            string? authorizedParty = Text(claims, "azp");
            string? subject = Text(claims, "sub");
            if (Text(claims, "iss") != Issuer || !values.Contains(client) || (values.Length > 1 || authorizedParty is not null) && authorizedParty != client ||
                !claims.GetProperty("exp").TryGetInt64(out long expires) || expires < DateTimeOffset.UtcNow.ToUnixTimeSeconds() - 5 ||
                Text(claims, "nonce") != nonce || subject is not { Length: > 0 and <= 256 } || subject.Any(char.IsControl))
                throw IdentityProblem();
            string? email = Text(claims, "email");
            if (email is { Length: > 254 } || email?.Any(char.IsControl) == true) email = null;
            return (subject, email);
        }
        catch (Exception error) when (error is FormatException or JsonException or CryptographicException or InvalidOperationException or KeyNotFoundException)
        { throw IdentityProblem(); }
    }

    private static string? Text(JsonElement value, string key) => value.ValueKind == JsonValueKind.Object &&
        value.TryGetProperty(key, out var item) && item.ValueKind == JsonValueKind.String ? item.GetString() : null;
    private static InvalidDataException IdentityProblem() => new("The ChatGPT sign-in identity could not be verified.");
}
