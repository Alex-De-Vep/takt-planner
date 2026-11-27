using System.Net;
using System.Net.Http.Headers;
using System.Text;

namespace Takt.Core.Calendar;

public sealed record CalendarFeed(string ProtectedAddress, DateTimeOffset CheckedAt, string? ETag);
public sealed record CalendarFeedResponse(string? CalendarText, string? ETag);

public sealed class CalendarFeedClient(HttpClient? transport = null)
{
    private static readonly HttpClient DefaultTransport = new(new HttpClientHandler
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate
    });

    public static Uri ParseAddress(string input)
    {
        string address = input.Trim();
        if (address.StartsWith("webcal://", StringComparison.OrdinalIgnoreCase))
            address = "https://" + address[9..];
        if (address.Length > 8192 || !Uri.TryCreate(address, UriKind.Absolute, out var uri) ||
            uri.Scheme != "https" || uri.Host.Length == 0 || uri.UserInfo.Length > 0 || uri.Fragment.Length > 0)
            throw new ArgumentException("Enter an HTTPS or webcal calendar subscription link.");
        return uri;
    }

    public async Task<CalendarFeedResponse> FetchAsync(Uri address, string? etag, CancellationToken cancellation)
    {
        address = ParseAddress(address.AbsoluteUri);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(25));
        try
        {
            var current = address;
            for (int remaining = 3; ; remaining--)
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, current);
                request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/calendar"));
                if (EntityTagHeaderValue.TryParse(etag, out var tag)) request.Headers.IfNoneMatch.Add(tag);
                using var response = await (transport ?? DefaultTransport)
                    .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
                if (response.StatusCode == HttpStatusCode.NotModified && etag is not null)
                    return new(null, etag);
                if ((int)response.StatusCode is 301 or 302 or 303 or 307 or 308 && remaining > 0 && response.Headers.Location is { } redirected &&
                    Uri.TryCreate(current, redirected, out var next) && next.Scheme == "https" &&
                    next.IdnHost == address.IdnHost && next.Port == address.Port && next.UserInfo.Length == 0)
                {
                    current = next;
                    continue;
                }
                if (response.StatusCode != HttpStatusCode.OK)
                    throw new InvalidOperationException($"The calendar provider returned HTTP {(int)response.StatusCode}. Check the subscription link.");
                if (response.Content.Headers.ContentLength > CalendarIcs.MaxBytes)
                    throw new InvalidDataException("The external calendar exceeds 8 MiB.");

                await using var input = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
                using var data = new MemoryStream();
                byte[] buffer = new byte[8192];
                int count;
                while ((count = await input.ReadAsync(buffer, timeout.Token).ConfigureAwait(false)) != 0)
                {
                    if (data.Length + count > CalendarIcs.MaxBytes) throw new InvalidDataException("The external calendar exceeds 8 MiB.");
                    data.Write(buffer, 0, count);
                }
                string text = new UTF8Encoding(false, true).GetString(data.GetBuffer(), 0, (int)data.Length);
                return new(text.TrimStart('\uFEFF'), response.Headers.ETag?.ToString());
            }
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        {
            throw new TimeoutException("The calendar provider took too long to respond.");
        }
        catch (HttpRequestException)
        {
            throw new InvalidOperationException("The calendar provider could not be reached. Check the connection and try again.");
        }
    }
}
