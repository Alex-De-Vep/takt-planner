using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Takt.Core.Assistant;

namespace Takt.Core.Calendar;

public enum CalendarAccountKind { Google, Outlook }

public sealed record CalendarRegistration(CalendarAccountKind Kind, string ClientId, string? DesktopSecret = null)
{
    public string Name => Kind == CalendarAccountKind.Google ? "Google Calendar" : "Outlook";
    public override string ToString() => Name;

    public void Validate()
    {
        if (Kind is not (CalendarAccountKind.Google or CalendarAccountKind.Outlook) ||
            !CalendarAccountOAuth.SafeValue(ClientId, 256) ||
            (Kind == CalendarAccountKind.Google
                ? !ClientId.EndsWith(".apps.googleusercontent.com", StringComparison.Ordinal) ||
                  DesktopSecret is not null && !CalendarAccountOAuth.SafeValue(DesktopSecret, 512)
                : !Guid.TryParseExact(ClientId, "D", out _) || DesktopSecret is not null))
            throw new ArgumentException("Enter the desktop application's OAuth client ID and its Google desktop secret, if supplied.");
    }
}

public sealed record CalendarAuthorization(CalendarRegistration Registration, string AccessToken, string RefreshToken, DateTimeOffset Expires)
{
    public override string ToString() => Registration.Name + " authorization";
}

public sealed class CalendarAccountOAuth(HttpClient? http = null)
{
    private const string GoogleScopes = "https://www.googleapis.com/auth/calendar.calendarlist.readonly https://www.googleapis.com/auth/calendar.events";
    private const string OutlookScopes = "offline_access https://graph.microsoft.com/Calendars.ReadWrite";
    private static readonly HttpClient Transport = CalendarAccountClient.CreateTransport();

    public async Task<CalendarAuthorization> SignInAsync(CalendarRegistration registration,
        Func<Uri, Task> openBrowser, CancellationToken cancellation)
    {
        registration.Validate();
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromMinutes(4));
        bool google = registration.Kind == CalendarAccountKind.Google;
        string state = Random(), verifier = Random();
        try
        {
            var callback = await OpenRouterOAuth.ReceiveLoopbackCodeAsync(state, google ? "127.0.0.1" : "localhost", "/", redirect =>
            {
                var fields = new Dictionary<string, string>
                {
                    ["client_id"] = registration.ClientId, ["redirect_uri"] = redirect.AbsoluteUri,
                    ["response_type"] = "code", ["state"] = state, ["scope"] = google ? GoogleScopes : OutlookScopes,
                    ["code_challenge_method"] = "S256",
                    ["code_challenge"] = Encode(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)))
                };
                fields["prompt"] = google ? "consent select_account" : "select_account";
                if (google) fields["access_type"] = "offline";
                else fields["response_mode"] = "query";
                string endpoint = google ? "https://accounts.google.com/o/oauth2/v2/auth" :
                    "https://login.microsoftonline.com/common/oauth2/v2.0/authorize";
                return openBrowser(CalendarAccountClient.WithQuery(endpoint, fields));
            }, deadline.Token);
            return await ExchangeAsync(registration, new()
            {
                ["grant_type"] = "authorization_code", ["code"] = callback.Code,
                ["redirect_uri"] = callback.Redirect.AbsoluteUri, ["code_verifier"] = verifier
            }, null, deadline.Token);
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        { throw new TimeoutException("Calendar sign-in timed out. Start again from Calendar accounts."); }
    }

    public Task<CalendarAuthorization> RefreshAsync(CalendarAuthorization authorization, CancellationToken cancellation)
        => ExchangeAsync(authorization.Registration, new()
        {
            ["grant_type"] = "refresh_token", ["refresh_token"] = authorization.RefreshToken
        }, authorization.RefreshToken, cancellation);

    private async Task<CalendarAuthorization> ExchangeAsync(CalendarRegistration registration,
        Dictionary<string, string> fields, string? oldRefresh, CancellationToken cancellation)
    {
        registration.Validate();
        bool google = registration.Kind == CalendarAccountKind.Google;
        fields["client_id"] = registration.ClientId;
        if (google && registration.DesktopSecret is { } secret) fields["client_secret"] = secret;
        if (!google && oldRefresh is not null) fields["scope"] = OutlookScopes;
        var uri = new Uri(google ? "https://oauth2.googleapis.com/token" :
            "https://login.microsoftonline.com/common/oauth2/v2.0/token");
        using var request = new HttpRequestMessage(HttpMethod.Post, uri) { Content = new FormUrlEncodedContent(fields) };
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        try
        {
            using var response = await (http ?? Transport).SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            if (response.RequestMessage?.RequestUri is { } actual && actual != uri ||
                response.StatusCode != HttpStatusCode.OK)
                throw new InvalidOperationException($"{registration.Name} could not authorize Takt. Check the desktop registration or sign in again.");
            using var json = await CalendarAccountClient.ReadJsonAsync(response.Content, 96 * 1024, timeout.Token).ConfigureAwait(false);
            var root = json.RootElement;
            string? access = CalendarAccountClient.Text(root, "access_token");
            string? refresh = CalendarAccountClient.Text(root, "refresh_token") ?? oldRefresh;
            var scopes = CalendarAccountClient.Text(root, "scope")?.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (!SafeValue(access, 16384) || !SafeValue(refresh, 16384) ||
                !string.Equals(CalendarAccountClient.Text(root, "token_type"), "Bearer", StringComparison.OrdinalIgnoreCase) ||
                !root.TryGetProperty("expires_in", out var ttl) || ttl.ValueKind != JsonValueKind.Number ||
                !ttl.TryGetInt32(out int seconds) || seconds is < 1 or > 86400)
                throw new InvalidDataException($"{registration.Name} did not return a renewable calendar authorization.");
            if (scopes is not null && (google ? !GoogleScopes.Split(' ').All(scopes.Contains) :
                !scopes.Any(s => s.Equals("Calendars.ReadWrite", StringComparison.OrdinalIgnoreCase) ||
                    s.Equals("https://graph.microsoft.com/Calendars.ReadWrite", StringComparison.OrdinalIgnoreCase))))
                throw new InvalidOperationException($"Grant the requested calendar permissions for {registration.Name}.");
            return new(registration, access!, refresh!, DateTimeOffset.UtcNow.AddSeconds(seconds));
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        { throw new TimeoutException($"{registration.Name} authorization timed out."); }
    }

    internal static bool SafeValue(string? value, int limit) => value is { Length: > 0 } && value.Length <= limit &&
        value.All(c => c is >= '!' and <= '~');
    private static string Random() => Encode(RandomNumberGenerator.GetBytes(32));
    private static string Encode(byte[] data) => Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
