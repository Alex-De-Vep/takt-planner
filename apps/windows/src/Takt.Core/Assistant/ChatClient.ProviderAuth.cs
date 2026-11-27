using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Takt.Core.Assistant;

public sealed partial class ChatClient
{
    private readonly SemaphoreSlim gigaGate = new(1, 1);
    private (string Fingerprint, string Token, DateTimeOffset Expires)? gigaToken;

    private async Task<string> ProviderKeyAsync(ChatConnection connection, string key, CancellationToken cancellation)
    {
        if (connection.Provider != "giga") return key;
        string scope = connection.ProviderOption!;
        string fingerprint = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(scope + ":" + key)));
        await gigaGate.WaitAsync(cancellation).ConfigureAwait(false);
        try
        {
            if (gigaToken is { } existing && existing.Fingerprint == fingerprint && existing.Expires > DateTimeOffset.UtcNow.AddSeconds(30))
                return existing.Token;
            using var request = new HttpRequestMessage(HttpMethod.Post, "https://ngw.devices.sberbank.ru:9443/api/v2/oauth");
            request.Headers.Authorization = new AuthenticationHeaderValue("Basic", key);
            request.Headers.Add("RqUID", Guid.NewGuid().ToString("D"));
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            request.Content = new FormUrlEncodedContent(new Dictionary<string, string> { ["scope"] = scope });
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            timeout.CancelAfter(TimeSpan.FromSeconds(30));
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            CheckResponse(response, request.RequestUri!);
            if (response.Content.Headers.ContentLength > 16384) throw new InvalidDataException("Invalid GigaChat authorization reply.");
            using var json = JsonDocument.Parse(await ReadBoundedAsync(response.Content, timeout.Token, 16384).ConfigureAwait(false));
            var root = json.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("access_token", out var tokenElement) || tokenElement.ValueKind != JsonValueKind.String ||
                tokenElement.GetString() is not { Length: > 0 and <= 8192 } token || token.Any(c => char.IsControl(c) || char.IsWhiteSpace(c)) ||
                !root.TryGetProperty("expires_at", out var expiry) || expiry.ValueKind != JsonValueKind.Number ||
                !expiry.TryGetInt64(out long milliseconds))
                throw new InvalidDataException("Invalid GigaChat authorization reply.");
            var expires = DateTimeOffset.FromUnixTimeMilliseconds(milliseconds);
            if (expires <= DateTimeOffset.UtcNow || expires > DateTimeOffset.UtcNow.AddHours(2))
                throw new InvalidDataException("Invalid GigaChat token expiry.");
            gigaToken = (fingerprint, token, expires);
            return token;
        }
        finally { gigaGate.Release(); }
    }

    public async Task<string> VerifyCopilotAsync(ChatConnection connection, string code, CancellationToken cancellation)
    {
        if (connection.Provider != "copilot") throw new ArgumentException("Choose the GitHub Copilot connection.");
        ValidateConnection(connection, code, requireModel: false);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        using var request = Request(connection, code, HttpMethod.Get, "models");
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
        CheckResponse(response, request.RequestUri!);
        using var json = JsonDocument.Parse(await ReadBoundedAsync(response.Content, timeout.Token).ConfigureAwait(false));
        if (json.RootElement.ValueKind != JsonValueKind.Object || !json.RootElement.TryGetProperty("account", out var account) ||
            account.ValueKind != JsonValueKind.String || account.GetString() is not { } identity || !ChatProvider.IsCopilotAccount(identity))
            throw new InvalidDataException("The local Copilot bridge did not return a signed-in account.");
        return identity;
    }
}
