using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Takt.Core.Assistant;
using Xunit;

namespace Takt.Core.Tests;

// Fixtures use an injected in-memory HTTP handler and literal-loopback TCP only.
// These test sources have not been executed; they never need a real provider key.
public sealed class OpenRouterOAuthTests
{
    private const string FixtureKey = "fixture-key-not-a-credential";
    private sealed record BrowserRequest(Uri Authorize, Uri Callback, string State, string Challenge);
    private static BrowserRequest Browser(Uri uri)
    {
        var values = Query(uri);
        return new(uri, new(values["callback_url"]), values["state"], values["code_challenge"]);
    }
    private static Dictionary<string, string> Query(Uri uri) => uri.Query.TrimStart('?').Split('&').Select(value => value.Split('=', 2))
        .ToDictionary(value => Uri.UnescapeDataString(value[0]), value => Uri.UnescapeDataString(value[1].Replace('+', ' ')), StringComparer.Ordinal);
    private sealed class Transport(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>>? send = null) : HttpMessageHandler
    {
        public int Calls;
        public HttpRequestMessage? LastRequest;
        public byte[]? LastBody;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation)
        {
            Interlocked.Increment(ref Calls); LastRequest = request;
            LastBody = request.Content is null ? null : await request.Content.ReadAsByteArrayAsync(cancellation);
            var result = send is null ? Json("{\"key\":\"" + FixtureKey + "\",\"user_id\":\"fixture-user\"}") : await send(request, cancellation);
            result.RequestMessage = request; return result;
        }
    }
    private static HttpResponseMessage Json(string text, HttpStatusCode status = HttpStatusCode.OK) => new(status) { Content = new StringContent(text, Encoding.UTF8, "application/json") };
    private static Task<string> Callback(BrowserRequest browser, string query, CancellationToken cancellation) =>
        Request(browser.Callback, $"GET {browser.Callback.AbsolutePath}?{query} HTTP/1.1\r\nHost: {browser.Callback.Authority}\r\n\r\n", cancellation);
    private static async Task<string> Request(Uri callback, string request, CancellationToken cancellation)
    {
        using var client = new TcpClient(AddressFamily.InterNetwork);
        await client.ConnectAsync(IPAddress.Loopback, callback.Port, cancellation);
        var stream = client.GetStream();
        try
        {
            await stream.WriteAsync(Encoding.ASCII.GetBytes(request), cancellation);
            using var output = new MemoryStream(); byte[] buffer = new byte[2048];
            while (output.Length < 32768)
            {
                int count = await stream.ReadAsync(buffer, cancellation);
                if (count == 0) break;
                output.Write(buffer, 0, count);
            }
            return Encoding.UTF8.GetString(output.ToArray());
        }
        catch (IOException) { return ""; } // Oversized/incomplete requests can be closed without a reply.
    }
    private static string Success(BrowserRequest browser, string code = "fixture-code") => "code=" + Uri.EscapeDataString(code) + "&state=" + Uri.EscapeDataString(browser.State);
    [Fact] public void PkceS256MatchesTheRfc7636KnownVector()
    {
        var method = typeof(OpenRouterOAuth).GetMethod("Challenge", BindingFlags.Static | BindingFlags.NonPublic)!;
        Assert.Equal("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", method.Invoke(null, ["dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"]));
    }
    [Fact] public async Task FlowUsesVerifiedOriginsFreshPkceStateAndNoBrowserCredentials()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var handler = new Transport(); using var http = new HttpClient(handler); var oauth = new OpenRouterOAuth(http);
        BrowserRequest? captured = null;
        var grant = await oauth.ConnectAsync(async uri =>
        {
            captured = Browser(uri); var query = Query(uri);
            Assert.Equal("https://openrouter.ai/auth", uri.GetLeftPart(UriPartial.Path));
            Assert.Equal("S256", query["code_challenge_method"]); Assert.Equal("Takt for Windows", query["key_label"]);
            Assert.Equal("http", captured.Callback.Scheme); Assert.Equal("127.0.0.1", captured.Callback.Host);
            Assert.InRange(captured.Callback.Port, 1, 65535);
            Assert.Matches("^/oauth/callback/[A-Za-z0-9_-]{22}$", captured.Callback.AbsolutePath);
            Assert.Matches("^[A-Za-z0-9_-]{43}$", captured.State); Assert.Matches("^[A-Za-z0-9_-]{43}$", captured.Challenge);
            Assert.DoesNotContain("code_verifier", query.Keys); Assert.DoesNotContain("key", query.Keys);
            string response = await Callback(captured, Success(captured), timeout.Token);
            Assert.StartsWith("HTTP/1.1 200", response); Assert.Contains("Cache-Control: no-store", response); Assert.Contains("Referrer-Policy: no-referrer", response);
            Assert.DoesNotContain(captured.State, response); Assert.DoesNotContain("fixture-code", response);
        }, timeout.Token);
        Assert.Equal(FixtureKey, grant.Key); Assert.Equal(1, handler.Calls);
        Assert.Equal("https://openrouter.ai/api/v1/auth/keys", handler.LastRequest!.RequestUri!.AbsoluteUri);
        Assert.Equal(HttpMethod.Post, handler.LastRequest.Method); Assert.Null(handler.LastRequest.Headers.Authorization);
        using var body = JsonDocument.Parse(handler.LastBody!);
        var verifier = body.RootElement.GetProperty("code_verifier").GetString()!;
        string expected = Convert.ToBase64String(SHA256.HashData(Encoding.ASCII.GetBytes(verifier))).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        Assert.Equal(expected, captured!.Challenge); Assert.NotEqual(verifier, captured.State);
        Assert.Equal("S256", body.RootElement.GetProperty("code_challenge_method").GetString());
        Assert.Equal("fixture-code", body.RootElement.GetProperty("code").GetString());
    }
    [Theory]
    [InlineData("missing-state")]
    [InlineData("wrong-state")]
    [InlineData("duplicate-state")]
    [InlineData("duplicate-code")]
    [InlineData("malformed-escape")]
    [InlineData("invalid-utf8")]
    [InlineData("encoded-control")]
    public async Task InvalidCallbacksDoNotConsumeTheConnectionAttempt(string kind)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)); using var handler = new Transport(); using var http = new HttpClient(handler);
        var grant = await new OpenRouterOAuth(http).ConnectAsync(async uri =>
        {
            var browser = Browser(uri);
            string query = kind switch
            {
                "missing-state" => "code=fixture-code",
                "wrong-state" => "code=fixture-code&state=wrong",
                "duplicate-state" => Success(browser) + "&state=" + browser.State,
                "duplicate-code" => Success(browser) + "&code=other",
                "malformed-escape" => "code=%GG&state=" + browser.State,
                "invalid-utf8" => "code=%FF&state=" + browser.State,
                _ => "code=bad%0Acode&state=" + browser.State
            };
            Assert.StartsWith("HTTP/1.1 400", await Callback(browser, query, timeout.Token));
            Assert.Equal(0, handler.Calls);
            Assert.StartsWith("HTTP/1.1 200", await Callback(browser, Success(browser), timeout.Token));
        }, timeout.Token);
        Assert.Equal(FixtureKey, grant.Key); Assert.Equal(1, handler.Calls);
    }
    [Theory]
    [InlineData("favicon")]
    [InlineData("wrong-nonce")]
    [InlineData("wrong-host")]
    [InlineData("duplicate-host")]
    [InlineData("body")]
    [InlineData("absolute-target")]
    public async Task ForeignPathsHostsAndBodyRequestsCannotCompleteOAuth(string kind)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)); using var handler = new Transport(); using var http = new HttpClient(handler);
        await new OpenRouterOAuth(http).ConnectAsync(async uri =>
        {
            var browser = Browser(uri); string path = browser.Callback.AbsolutePath + "?" + Success(browser);
            string request = kind switch
            {
                "favicon" => $"GET /favicon.ico HTTP/1.1\r\nHost: {browser.Callback.Authority}\r\n\r\n",
                "wrong-nonce" => $"GET /oauth/callback/wrong?error=access_denied HTTP/1.1\r\nHost: {browser.Callback.Authority}\r\n\r\n",
                "wrong-host" => $"GET {path} HTTP/1.1\r\nHost: localhost:{browser.Callback.Port}\r\n\r\n",
                "duplicate-host" => $"GET {path} HTTP/1.1\r\nHost: {browser.Callback.Authority}\r\nHost: {browser.Callback.Authority}\r\n\r\n",
                "body" => $"GET {path} HTTP/1.1\r\nHost: {browser.Callback.Authority}\r\nContent-Length: 5\r\n\r\n",
                _ => $"GET {browser.Callback.AbsoluteUri}?{Success(browser)} HTTP/1.1\r\nHost: {browser.Callback.Authority}\r\n\r\n"
            };
            string response = await Request(browser.Callback, request, timeout.Token);
            Assert.True(response.StartsWith("HTTP/1.1 400", StringComparison.Ordinal) || response.StartsWith("HTTP/1.1 404", StringComparison.Ordinal));
            Assert.Equal(0, handler.Calls);
            await Callback(browser, Success(browser), timeout.Token);
        }, timeout.Token);
        Assert.Equal(1, handler.Calls);
    }
    [Fact] public async Task DenialWithoutStateRequiresTheExactNoncePathAndNeverExchanges()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)); using var handler = new Transport(); using var http = new HttpClient(handler);
        var error = await Assert.ThrowsAnyAsync<InvalidOperationException>(() => new OpenRouterOAuth(http).ConnectAsync(async uri =>
        {
            var browser = Browser(uri);
            string response = await Callback(browser, "error=access_denied&error_description=fixture-private-description", timeout.Token);
            Assert.StartsWith("HTTP/1.1 400", response); Assert.DoesNotContain("fixture-private-description", response);
        }, timeout.Token));
        Assert.Contains("not completed", error.Message); Assert.DoesNotContain("fixture-private-description", error.ToString()); Assert.Equal(0, handler.Calls);
    }
    [Fact] public async Task WrongStateCannotTurnAnErrorResponseIntoTerminalDenial()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)); using var handler = new Transport(); using var http = new HttpClient(handler);
        var grant = await new OpenRouterOAuth(http).ConnectAsync(async uri =>
        {
            var browser = Browser(uri); await Callback(browser, "error=access_denied&state=wrong", timeout.Token);
            await Callback(browser, Success(browser), timeout.Token);
        }, timeout.Token);
        Assert.Equal(FixtureKey, grant.Key);
    }
    [Fact] public async Task OpaqueAuthorizationCodeIsDecodedOnceAndSentInJsonOnly()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)); using var handler = new Transport(); using var http = new HttpClient(handler);
        const string code = "fixture+code%&=😀";
        await new OpenRouterOAuth(http).ConnectAsync(async uri => { var browser = Browser(uri); await Callback(browser, Success(browser, code), timeout.Token); }, timeout.Token);
        using var body = JsonDocument.Parse(handler.LastBody!); Assert.Equal(code, body.RootElement.GetProperty("code").GetString());
    }
    [Fact] public async Task OversizedCallbackHeadersDoNotBlockASubsequentValidResponse()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)); using var handler = new Transport(); using var http = new HttpClient(handler);
        await new OpenRouterOAuth(http).ConnectAsync(async uri =>
        {
            var browser = Browser(uri);
            await Request(browser.Callback, $"GET /favicon.ico HTTP/1.1\r\nHost: {browser.Callback.Authority}\r\nX-Padding: {new string('x', 9000)}\r\n\r\n", timeout.Token);
            await Callback(browser, Success(browser), timeout.Token);
        }, timeout.Token);
        Assert.Equal(1, handler.Calls);
    }
    [Fact] public async Task CancellationInterruptsAnIncompleteHeaderAndReleasesThePort()
    {
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(10)); using var handler = new Transport(); using var http = new HttpClient(handler);
        int port = 0;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new OpenRouterOAuth(http).ConnectAsync(async uri =>
        {
            var browser = Browser(uri); port = browser.Callback.Port;
            using var client = new TcpClient(AddressFamily.InterNetwork); await client.ConnectAsync(IPAddress.Loopback, port, cancellation.Token);
            await client.GetStream().WriteAsync(Encoding.ASCII.GetBytes("GET /oauth/"), cancellation.Token); cancellation.Cancel();
        }, cancellation.Token));
        using var probe = new TcpClient(AddressFamily.InterNetwork); using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(1));
        await Assert.ThrowsAnyAsync<SocketException>(async () => await probe.ConnectAsync(IPAddress.Loopback, port, timeout.Token));
        Assert.Equal(0, handler.Calls);
    }
    [Fact] public async Task AlreadyCancelledFlowDoesNotLaunchTheBrowser()
    {
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel(); using var handler = new Transport(); using var http = new HttpClient(handler); bool opened = false;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new OpenRouterOAuth(http).ConnectAsync(_ => { opened = true; return Task.CompletedTask; }, cancellation.Token));
        Assert.False(opened); Assert.Equal(0, handler.Calls);
    }
    [Theory]
    [InlineData(302)]
    [InlineData(400)]
    [InlineData(403)]
    [InlineData(429)]
    [InlineData(500)]
    public async Task ExchangeFailureDoesNotFollowRedirectsOrExposeProviderMessages(int status)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var handler = new Transport((_, _) => Task.FromResult(Json("{\"error\":\"fixture-private-provider-detail\"}", (HttpStatusCode)status)));
        using var http = new HttpClient(handler);
        var error = await Assert.ThrowsAnyAsync<InvalidOperationException>(() => new OpenRouterOAuth(http).ConnectAsync(async uri =>
        { var browser = Browser(uri); await Callback(browser, Success(browser, "fixture-private-code"), timeout.Token); }, timeout.Token));
        Assert.DoesNotContain("fixture-private", error.ToString()); Assert.Null(error.InnerException); Assert.Equal(1, handler.Calls);
    }
    [Theory]
    [InlineData("{\"key\":\"one\",\"key\":\"two\"}")]
    [InlineData("{\"key\":\"\"}")]
    [InlineData("{\"key\":12}")]
    [InlineData("{\"key\":\"fixture bad key\"}")]
    [InlineData("{\"key\":\"bad\\nkey\"}")]
    [InlineData("[]")]
    [InlineData("{}")]
    [InlineData("{\"key\":\"fixture-key\",\"error\":{\"message\":\"fixture-private-error\"}}")]
    [InlineData("{malformed-private-detail")]
    public async Task MalformedOrAmbiguousKeysAreRejectedWithoutPayloadDisclosure(string payload)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)); using var handler = new Transport((_, _) => Task.FromResult(Json(payload))); using var http = new HttpClient(handler);
        var error = await Assert.ThrowsAnyAsync<InvalidOperationException>(() => new OpenRouterOAuth(http).ConnectAsync(async uri =>
        { var browser = Browser(uri); await Callback(browser, Success(browser), timeout.Token); }, timeout.Token));
        Assert.DoesNotContain(payload, error.ToString()); Assert.Null(error.InnerException);
    }
    private sealed class NonSeekableBody(byte[] bytes) : Stream
    {
        private int offset;
        public int ReadBytes => offset;
        public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException(); public override long Position { get => offset; set => throw new NotSupportedException(); }
        public override int Read(byte[] buffer, int start, int count) { int size = Math.Min(count, bytes.Length - offset); bytes.AsSpan(offset, size).CopyTo(buffer.AsSpan(start)); offset += size; return size; }
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellation = default)
        { cancellation.ThrowIfCancellationRequested(); int size = Math.Min(buffer.Length, bytes.Length - offset); bytes.AsMemory(offset, size).CopyTo(buffer); offset += size; return ValueTask.FromResult(size); }
        public override void Flush() { } public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException(); public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
    [Fact] public async Task UnknownLengthExchangeBodyIsBoundedBeforeJsonParsing()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)); var body = new NonSeekableBody(Encoding.ASCII.GetBytes(new string('x', 20000)));
        using var handler = new Transport((_, _) =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(body) }; response.Content.Headers.ContentType = new("application/json"); return Task.FromResult(response);
        });
        using var http = new HttpClient(handler);
        var error = await Assert.ThrowsAnyAsync<InvalidOperationException>(() => new OpenRouterOAuth(http).ConnectAsync(async uri =>
        { var browser = Browser(uri); await Callback(browser, Success(browser), timeout.Token); }, timeout.Token));
        Assert.Contains("oversized", error.Message); Assert.InRange(body.ReadBytes, 16385, 16385);
    }
    [Fact] public async Task BrowserFailureIsRedactedAndClosesTheListener()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)); using var handler = new Transport(); using var http = new HttpClient(handler);
        var error = await Assert.ThrowsAnyAsync<InvalidOperationException>(() => new OpenRouterOAuth(http).ConnectAsync(_ => throw new IOException("fixture-private-browser-url"), timeout.Token));
        Assert.DoesNotContain("fixture-private-browser-url", error.ToString()); Assert.Null(error.InnerException); Assert.Equal(0, handler.Calls);
    }
    [Fact] public void CredentialsAreNotIncludedInRecordDiagnosticsOrInjectedHeaders()
    {
        Assert.DoesNotContain(FixtureKey, new OpenRouterGrant(FixtureKey).ToString());
        using var http = new HttpClient(); http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", FixtureKey);
        var error = Assert.Throws<ArgumentException>(() => new OpenRouterOAuth(http)); Assert.DoesNotContain(FixtureKey, error.ToString());
    }
    [Fact] public async Task SlowIncompleteClientsDoNotBlockTheActualBrowserCallback()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)); using var handler = new Transport(); using var http = new HttpClient(handler);
        await new OpenRouterOAuth(http).ConnectAsync(async uri =>
        {
            var browser = Browser(uri); var clients = new List<TcpClient>();
            try
            {
                for (int i = 0; i < 7; ++i)
                {
                    var client = new TcpClient(AddressFamily.InterNetwork); clients.Add(client);
                    await client.ConnectAsync(IPAddress.Loopback, browser.Callback.Port, timeout.Token);
                    await client.GetStream().WriteAsync(Encoding.ASCII.GetBytes("GET /partial"), timeout.Token);
                }
                Assert.StartsWith("HTTP/1.1 200", await Callback(browser, Success(browser), timeout.Token));
            }
            finally { foreach (var client in clients) client.Dispose(); }
        }, timeout.Token);
        Assert.Equal(1, handler.Calls);
    }
    [Fact] public async Task CancellationDuringExchangeStopsTheRequestAfterTheListenerWasReleased()
    {
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var handler = new Transport(async (_, token) => { started.SetResult(); await Task.Delay(Timeout.InfiniteTimeSpan, token); return Json("{}"); });
        using var http = new HttpClient(handler); int port = 0;
        var flow = new OpenRouterOAuth(http).ConnectAsync(async uri =>
        { var browser = Browser(uri); port = browser.Callback.Port; await Callback(browser, Success(browser), cancellation.Token); }, cancellation.Token);
        await started.Task.WaitAsync(cancellation.Token);
        try
        {
            using var probe = new TcpClient(AddressFamily.InterNetwork);
            await Assert.ThrowsAnyAsync<SocketException>(async () => await probe.ConnectAsync(IPAddress.Loopback, port, cancellation.Token));
        }
        finally { cancellation.Cancel(); }
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => flow); Assert.Equal(1, handler.Calls);
    }
    [Fact] public async Task EachAttemptGeneratesFreshStateChallengeAndCallbackNonce()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)); using var handler = new Transport(); using var http = new HttpClient(handler);
        var oauth = new OpenRouterOAuth(http); var attempts = new List<BrowserRequest>();
        for (int i = 0; i < 2; ++i)
            await oauth.ConnectAsync(async uri => { var browser = Browser(uri); attempts.Add(browser); await Callback(browser, Success(browser), timeout.Token); }, timeout.Token);
        Assert.NotEqual(attempts[0].State, attempts[1].State); Assert.NotEqual(attempts[0].Challenge, attempts[1].Challenge);
        Assert.NotEqual(attempts[0].Callback.AbsolutePath, attempts[1].Callback.AbsolutePath); Assert.Equal(2, handler.Calls);
    }

}
