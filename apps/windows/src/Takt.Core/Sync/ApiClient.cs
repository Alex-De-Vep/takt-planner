using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Takt.Core.Models;

namespace Takt.Core.Sync;

public sealed class ApiException(int status, string code, long? retryAfter = null) : Exception(code)
{
    public int Status { get; } = status;
    public string Code { get; } = code;
    public long? RetryAfter { get; } = retryAfter;
}
public interface IApiClient
{
    Task<T> SendAsync<T>(string origin, string path, object? body = null, string? token = null, CancellationToken cancellation = default);
    Task<T> PutAsync<T>(string origin, string path, object body, string? token = null, CancellationToken cancellation = default)
        => Task.FromException<T>(new NotSupportedException("This transport does not support PUT."));
    Task WatchChangesAsync(string origin, string token, bool tasks, Action signal, CancellationToken cancellation)
        => Task.FromException(new NotSupportedException("This transport does not support live change signals."));
}
public sealed partial class ApiClient(HttpClient http) : IApiClient
{
    public static HttpClient CreateHttpClient() => new(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { Timeout = TimeSpan.FromSeconds(30) };
    public static string NormalizeOrigin(string value)
    {
        if (!Uri.TryCreate(value.Trim(), UriKind.Absolute, out var uri) || uri.Scheme != "https" ||
            uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0 || uri.AbsolutePath != "/")
            throw new ArgumentException("Enter an HTTPS server address without a path.");
        return uri.GetLeftPart(UriPartial.Authority).ToLowerInvariant();
    }
    public Task<T> SendAsync<T>(string origin, string path, object? body = null, string? token = null, CancellationToken cancellation = default)
        => ExchangeAsync<T>(body is null ? HttpMethod.Get : HttpMethod.Post, origin, path, body, token, cancellation);
    public Task<T> PutAsync<T>(string origin, string path, object body, string? token = null, CancellationToken cancellation = default)
        => ExchangeAsync<T>(HttpMethod.Put, origin, path, body, token, cancellation);
    private async Task<T> ExchangeAsync<T>(HttpMethod method, string origin, string path, object? body, string? token, CancellationToken cancellation)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromSeconds(30));
        cancellation = deadline.Token;
        using var request = new HttpRequestMessage(method, NormalizeOrigin(origin) + path);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (token is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (body is not null) request.Content = new StringContent(JsonSerializer.Serialize(body, Wire.Json), Encoding.UTF8, "application/json");
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
        int limit = response.IsSuccessStatusCode ? 64 * 1024 * 1024 : 16384;
        if (response.Content.Headers.ContentLength > limit) throw new InvalidDataException("Server response exceeds the supported size.");
        await using var input = await response.Content.ReadAsStreamAsync(cancellation);
        using var output = new MemoryStream(); byte[] buffer = new byte[8192];
        while (true)
        {
            int count = await input.ReadAsync(buffer, cancellation);
            if (count == 0) break;
            if (output.Length + count > limit) throw new InvalidDataException("Server response exceeds the supported size.");
            output.Write(buffer, 0, count);
        }
        var data = output.ToArray();
        if (response.IsSuccessStatusCode) return JsonSerializer.Deserialize<T>(data, Wire.Json) ?? throw new InvalidDataException("Empty server response.");
        string code = "http_error"; long? retry = null;
        try
        {
            using var json = JsonDocument.Parse(data);
            var error = json.RootElement.GetProperty("error"); code = error.GetProperty("code").GetString() ?? code;
            if (error.TryGetProperty("retryAfterSeconds", out var seconds) && seconds.TryGetInt64(out var n)) retry = n;
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException) { }
        var header = response.Headers.RetryAfter;
        if (header?.Delta is { } delta) retry = (long)Math.Ceiling(delta.TotalSeconds);
        else if (header?.Date is { } date) retry = Math.Max(1, (long)Math.Ceiling((date - DateTimeOffset.UtcNow).TotalSeconds));
        throw new ApiException((int)response.StatusCode, code, retry);
    }
}
