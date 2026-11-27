using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Takt.Core.Assistant;

public sealed record OpenRouterGrant(string Key)
{
    // Records normally include their properties in ToString; this one holds a credential.
    public override string ToString() => "OpenRouterGrant { Key = [redacted] }";
}

/// <summary>Explicit browser PKCE sign-in. Nothing listens or opens until ConnectAsync is called.</summary>
public sealed class OpenRouterOAuth
{
    private static readonly Uri ExchangeAddress = new("https://openrouter.ai/api/v1/auth/keys");
    private static readonly HttpClient SharedHttp = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false, UseCookies = false, Credentials = null, PreAuthenticate = false,
        AutomaticDecompression = DecompressionMethods.None, ConnectTimeout = TimeSpan.FromSeconds(15),
        MaxResponseHeadersLength = 16, MaxConnectionsPerServer = 2, PooledConnectionLifetime = TimeSpan.FromMinutes(5)
    }) { Timeout = Timeout.InfiniteTimeSpan };
    private const int MaxHeaderBytes = 8192, MaxCodeBytes = 4096, MaxReplyBytes = 16384;
    private readonly HttpClient http;
    private readonly SemaphoreSlim flowGate = new(1, 1);
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    // An injected transport is for isolated fixtures: it must disable redirects,
    // cookies and default credentials just as SharedHttp does. HttpClient does not
    // expose handler redirect settings for inspection after construction.
    public OpenRouterOAuth(HttpClient? http = null)
    {
        this.http = http ?? SharedHttp;
        if (this.http.DefaultRequestHeaders.Contains("Authorization") || this.http.DefaultRequestHeaders.Contains("Cookie") || this.http.DefaultRequestHeaders.Contains("Proxy-Authorization"))
            throw new ArgumentException("Use a separate credential-free HTTP client for OpenRouter sign-in.");
    }
    public async Task<OpenRouterGrant> ConnectAsync(Func<Uri, Task> openBrowser, CancellationToken cancellation)
    {
        ArgumentNullException.ThrowIfNull(openBrowser); cancellation.ThrowIfCancellationRequested();
        if (!await flowGate.WaitAsync(0, cancellation)) throw new InvalidOperationException("An OpenRouter connection is already in progress.");
        try
        {
            using var total = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            total.CancelAfter(TimeSpan.FromMinutes(3));
            using var receiving = CancellationTokenSource.CreateLinkedTokenSource(total.Token);
            var listener = new TcpListener(IPAddress.Loopback, 0) { ExclusiveAddressUse = true };
            Task receiver = Task.CompletedTask;
            try
            {
                try { listener.Start(8); }
                catch (SocketException) { throw Failure("Windows could not open the local sign-in callback. Close other connection attempts and try again."); }
                int port = ((IPEndPoint)listener.LocalEndpoint).Port;
                string state = Random(32), verifier = Random(32), nonce = Random(16);
                var callback = new Uri($"http://127.0.0.1:{port}/oauth/callback/{nonce}");
                var completion = new TaskCompletionSource<Callback>(TaskCreationOptions.RunContinuationsAsynchronously);
                using var stopped = receiving.Token.Register(listener.Stop);
                receiver = ReceiveAsync(listener, callback, state, completion, receiving.Token);
                total.Token.ThrowIfCancellationRequested();
                try { await openBrowser(AuthorizationUri(callback, verifier, state)).WaitAsync(total.Token); }
                catch (OperationCanceledException) { throw; }
                catch (Exception) { throw Failure("Windows could not open OpenRouter sign-in in your browser. Try connecting again."); }
                var result = await completion.Task.WaitAsync(total.Token);
                // Release the loopback port before exchanging the single-use code.
                receiving.Cancel(); listener.Stop(); await receiver;
                if (result.Denied) throw Failure("OpenRouter sign-in was not completed. You can connect again when ready.");
                return await ExchangeAsync(result.Code!, verifier, total.Token);
            }
            catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
            { throw new SignInTimeout("OpenRouter sign-in timed out. Start a new connection attempt."); }
            catch (SocketException) when (total.IsCancellationRequested)
            {
                cancellation.ThrowIfCancellationRequested();
                throw new SignInTimeout("OpenRouter sign-in timed out. Start a new connection attempt.");
            }
            catch (SignInFailure) { throw; }
            catch (SignInTimeout) { throw; }
            catch (OperationCanceledException) { throw new OperationCanceledException("OpenRouter sign-in was cancelled.", cancellation); }
            catch (Exception) { throw Failure("OpenRouter sign-in could not finish. Start a new connection attempt."); }
            finally
            {
                receiving.Cancel(); listener.Stop();
                await receiver;
            }
        }
        finally { flowGate.Release(); }
    }
    internal static async Task<(string Code, string? ClientId, Uri Redirect)> ReceiveChatGptAsync(
        string state, Func<Uri, Task> openBrowser, CancellationToken cancellation)
        => await ReceiveLoopbackCodeAsync(state, "127.0.0.1", "/auth/callback", openBrowser, cancellation);

    internal static async Task<(string Code, string? ClientId, Uri Redirect)> ReceiveLoopbackCodeAsync(
        string state, string host, string path, Func<Uri, Task> openBrowser, CancellationToken cancellation)
    {
        using var receiving = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        var listener = new TcpListener(IPAddress.Loopback, 0) { ExclusiveAddressUse = true };
        Task receiver = Task.CompletedTask;
        try
        {
            listener.Start(8);
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            var callback = new Uri($"http://{host}:{port}{path}");
            var completion = new TaskCompletionSource<Callback>(TaskCreationOptions.RunContinuationsAsynchronously);
            using var stopped = receiving.Token.Register(listener.Stop);
            receiver = ReceiveAsync(listener, callback, state, completion, receiving.Token, requireDenialState: true);
            await openBrowser(callback).WaitAsync(cancellation);
            var result = await completion.Task.WaitAsync(cancellation);
            if (result.Denied) throw new InvalidOperationException("Authorization was declined in the browser.");
            return (result.Code!, result.ClientId, callback);
        }
        finally
        {
            receiving.Cancel();
            listener.Stop();
            await receiver;
        }
    }

    private static Uri AuthorizationUri(Uri callback, string verifier, string state) => new("https://openrouter.ai/auth?" +
        string.Join("&", new Dictionary<string, string>
        {
            ["callback_url"] = callback.AbsoluteUri, ["code_challenge"] = Challenge(verifier),
            ["code_challenge_method"] = "S256", ["state"] = state, ["key_label"] = "Takt for Windows"
        }.Select(pair => Uri.EscapeDataString(pair.Key) + "=" + Uri.EscapeDataString(pair.Value))));
    private static string Random(int bytes) => Base64Url(RandomNumberGenerator.GetBytes(bytes));
    private static string Challenge(string verifier) => Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
    private static string Base64Url(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    private sealed class SignInFailure(string message) : InvalidOperationException(message) { }
    private sealed class SignInTimeout(string message) : TimeoutException(message) { }
    private static SignInFailure Failure(string message) => new(message);
    private sealed record Callback(string? Code = null, bool Denied = false, int Status = 400, string? ClientId = null)
    {
        public bool Accepted => Code is not null || Denied;
        public override string ToString() => "OpenRouter callback [redacted]";
    }
    private static async Task ReceiveAsync(TcpListener listener, Uri callback, string state, TaskCompletionSource<Callback> completion, CancellationToken cancellation, bool requireDenialState = false)
    {
        var workers = new List<Task>();
        try
        {
            while (true)
            {
                var client = await listener.AcceptTcpClientAsync(cancellation).ConfigureAwait(false);
                workers.RemoveAll(task => task.IsCompleted);
                if (workers.Count >= 8) { client.Dispose(); continue; }
                workers.Add(ReceiveClientAsync(client, callback, state, completion, cancellation, requireDenialState));
            }
        }
        catch (Exception) when (cancellation.IsCancellationRequested) { }
        catch (Exception) { completion.TrySetException(Failure("Windows could not receive the browser sign-in response. Try connecting again.")); }
        finally { await Task.WhenAll(workers).ConfigureAwait(false); }
    }
    private static async Task ReceiveClientAsync(TcpClient client, Uri callback, string state, TaskCompletionSource<Callback> completion, CancellationToken cancellation, bool requireDenialState = false)
    {
        using (client)
        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation))
        {
            timeout.CancelAfter(TimeSpan.FromSeconds(5));
            using var close = timeout.Token.Register(client.Dispose);
            try
            {
                if (client.Client.RemoteEndPoint is not IPEndPoint endpoint || !endpoint.Address.Equals(IPAddress.Loopback)) return;
                var stream = client.GetStream();
                string header = await ReadHeaderAsync(stream, timeout.Token).ConfigureAwait(false);
                var result = ParseCallback(header, callback, state, requireDenialState);
                try { await ReplyAsync(stream, result.Status, result.Code is not null, timeout.Token).ConfigureAwait(false); }
                catch (Exception) when (!cancellation.IsCancellationRequested) { /* Closing the browser cannot erase an already verified callback. */ }
                if (result.Accepted && !cancellation.IsCancellationRequested) completion.TrySetResult(result);
            }
            catch (Exception) { /* Untrusted, oversized, incomplete and slow requests do not terminate the flow. */ }
        }
    }
    private static async Task<string> ReadHeaderAsync(Stream stream, CancellationToken cancellation)
    {
        byte[] bytes = new byte[MaxHeaderBytes]; int count = 0;
        while (count < bytes.Length)
        {
            int read = await stream.ReadAsync(bytes.AsMemory(count, bytes.Length - count), cancellation).ConfigureAwait(false);
            if (read == 0) break;
            count += read;
            for (int i = Math.Max(0, count - read - 3); i + 3 < count; ++i)
                if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10)
                {
                    // This endpoint has no request body or pipelined requests.
                    if (i + 4 != count) throw Failure("Invalid callback request.");
                    for (int j = 0; j < i; ++j) if (bytes[j] < 9 || bytes[j] > 126) throw Failure("Invalid callback request.");
                    return Encoding.ASCII.GetString(bytes, 0, i);
                }
        }
        throw Failure("Invalid callback request.");
    }
    private static Callback ParseCallback(string header, Uri callback, string state, bool requireDenialState)
    {
        if (header.Length > MaxHeaderBytes) return new();
        var lines = header.Split("\r\n", StringSplitOptions.None);
        var request = lines[0].Split(' ', StringSplitOptions.None);
        if (request.Length != 3 || request[0] != "GET" || request[2] != "HTTP/1.1" || request[1].Length > 6144) return new();
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (lines.Length > 65) return new();
        foreach (var line in lines.Skip(1))
        {
            int colon = line.IndexOf(':');
            if (colon <= 0 || !line[..colon].All(c => char.IsAsciiLetterOrDigit(c) || "!#$%&'*+-.^_`|~".Contains(c)) ||
                line[(colon + 1)..].Any(c => c < ' ' && c != '\t' || c > '~') || !headers.TryAdd(line[..colon], line[(colon + 1)..].Trim(' ', '\t'))) return new();
        }
        if (!headers.TryGetValue("Host", out var host) || host != callback.Authority || headers.ContainsKey("Transfer-Encoding") ||
            headers.ContainsKey("Upgrade") || headers.TryGetValue("Content-Length", out var length) && length != "0") return new();
        string target = request[1]; int question = target.IndexOf('?');
        string path = question < 0 ? target : target[..question];
        if (path != callback.AbsolutePath) return new(Status: 404);
        if (question < 0 || target.Contains('#') || target.Contains('\\')) return new();
        Dictionary<string, string> query;
        try { query = Query(target[(question + 1)..]); } catch (Exception) { return new(); }
        bool hasState = query.TryGetValue("state", out var returnedState);
        if (hasState && !SameState(returnedState!, state)) return new();
        if (query.ContainsKey("error"))
        {
            // Docs do not echo state on denial. Exact unguessable callback path
            // and literal Host bind this response to the active flow instead.
            if (query.ContainsKey("code") || requireDenialState && !hasState) return new();
            return new(Denied: true);
        }
        if (!hasState || !query.TryGetValue("code", out var code) || string.IsNullOrWhiteSpace(code) ||
            Encoding.UTF8.GetByteCount(code) > MaxCodeBytes || code.Any(char.IsControl)) return new();
        return new(code, Status: 200, ClientId: query.GetValueOrDefault("client_id"));
    }
    private static bool SameState(string returned, string expected) => returned.Length == expected.Length &&
        CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(returned), Encoding.UTF8.GetBytes(expected));
    private static Dictionary<string, string> Query(string raw)
    {
        var pairs = raw.Split('&', StringSplitOptions.None);
        if (pairs.Length > 16) throw Failure("Invalid callback request.");
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in pairs)
        {
            int equals = pair.IndexOf('=');
            if (equals <= 0 || !result.TryAdd(Decode(pair[..equals]), Decode(pair[(equals + 1)..]))) throw Failure("Invalid callback request.");
        }
        return result;
    }
    private static string Decode(string text)
    {
        using var bytes = new MemoryStream();
        for (int i = 0; i < text.Length; ++i)
        {
            char c = text[i];
            if (c == '%')
            {
                if (i + 2 >= text.Length || !byte.TryParse(text.AsSpan(i + 1, 2), System.Globalization.NumberStyles.AllowHexSpecifier, System.Globalization.CultureInfo.InvariantCulture, out byte b)) throw Failure("Invalid callback request.");
                bytes.WriteByte(b); i += 2;
            }
            else if (c == '+') bytes.WriteByte((byte)' ');
            else if (c < '!' || c > '~') throw Failure("Invalid callback request.");
            else bytes.WriteByte((byte)c);
        }
        string result = StrictUtf8.GetString(bytes.ToArray());
        if (result.Any(char.IsControl)) throw Failure("Invalid callback request.");
        return result;
    }
    private static Task ReplyAsync(Stream stream, int status, bool success, CancellationToken cancellation)
    {
        string text = success ? "Response received. Return to Takt to finish connecting." : status == 404 ? "Not found." : "Sign-in response not accepted. Return to Takt or continue signing in.";
        byte[] body = Encoding.UTF8.GetBytes(text);
        string reason = status == 200 ? "OK" : status == 404 ? "Not Found" : "Bad Request";
        string header = $"HTTP/1.1 {status} {reason}\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nPragma: no-cache\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'; base-uri 'none'\r\nX-Content-Type-Options: nosniff\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n";
        return stream.WriteAsync(Encoding.ASCII.GetBytes(header).Concat(body).ToArray(), cancellation).AsTask();
    }
    private async Task<OpenRouterGrant> ExchangeAsync(string code, string verifier, CancellationToken cancellation)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, ExchangeAddress);
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            request.Headers.CacheControl = new CacheControlHeaderValue { NoStore = true };
            request.Content = new ByteArrayContent(JsonSerializer.SerializeToUtf8Bytes(new { code, code_verifier = verifier, code_challenge_method = "S256" }));
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).WaitAsync(timeout.Token).ConfigureAwait(false);
            if (response.RequestMessage?.RequestUri is { } actual && actual != ExchangeAddress || (int)response.StatusCode is >= 300 and < 400)
                throw Failure("OpenRouter redirected the key exchange. The connection was not saved.");
            if (!response.IsSuccessStatusCode)
                throw Failure(response.StatusCode == HttpStatusCode.TooManyRequests ? "OpenRouter is busy. Try connecting again later." : "OpenRouter could not authorize this connection. Start a new sign-in attempt.");
            string? mediaType = response.Content.Headers.ContentType?.MediaType;
            if (!string.Equals(mediaType, "application/json", StringComparison.OrdinalIgnoreCase) || response.Content.Headers.ContentEncoding.Count > 0 || response.Content.Headers.ContentLength is > MaxReplyBytes)
                throw Failure("OpenRouter returned an invalid sign-in response. The connection was not saved.");
            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token).WaitAsync(timeout.Token).ConfigureAwait(false);
            using var output = new MemoryStream(); byte[] buffer = new byte[2048];
            while (true)
            {
                int maximum = Math.Min(buffer.Length, MaxReplyBytes + 1 - checked((int)output.Length));
                int read = await stream.ReadAsync(buffer.AsMemory(0, maximum), timeout.Token).AsTask().WaitAsync(timeout.Token).ConfigureAwait(false);
                if (read == 0) break;
                output.Write(buffer, 0, read);
                if (output.Length > MaxReplyBytes) throw Failure("OpenRouter returned an oversized sign-in response. The connection was not saved.");
            }
            using var json = JsonDocument.Parse(output.ToArray(), new JsonDocumentOptions { MaxDepth = 8 });
            if (json.RootElement.ValueKind != JsonValueKind.Object || json.RootElement.TryGetProperty("error", out _)) throw Failure("OpenRouter returned an invalid sign-in response. The connection was not saved.");
            var keys = json.RootElement.EnumerateObject().Where(p => p.Name == "key").ToList();
            if (keys.Count != 1 || keys[0].Value.ValueKind != JsonValueKind.String || keys[0].Value.GetString() is not { } key ||
                key.Length is < 1 or > 4096 || key.Any(c => c <= ' ' || c > '~')) throw Failure("OpenRouter returned an invalid key. The connection was not saved.");
            cancellation.ThrowIfCancellationRequested(); return new(key);
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        { throw new SignInTimeout("OpenRouter did not finish the key exchange in time. Start a new sign-in attempt."); }
        catch (HttpRequestException) { throw Failure("OpenRouter could not be reached securely. Check your connection and try again."); }
        catch (IOException) { throw Failure("OpenRouter's sign-in response could not be read. Try connecting again."); }
        catch (JsonException) { throw Failure("OpenRouter returned an invalid sign-in response. The connection was not saved."); }
    }
}
