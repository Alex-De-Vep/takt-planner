using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace Takt.Core.Calendar;

public sealed record RemoteCalendar(string Id, string Name, bool Writable, bool Primary, string? Zone);
public sealed record ConnectedCalendar(Guid ConnectionId, CalendarAccountKind Kind, RemoteCalendar Calendar);
public sealed record ConnectedEvent(string Id, string? Version, bool CanEditLocation);

public sealed partial class CalendarAccountClient(HttpClient? http = null)
{
    private const string Google = "https://www.googleapis.com/calendar/v3/";
    private const string Graph = "https://graph.microsoft.com/v1.0/";
    private const int MaxPages = 8;
    private const string GraphFields = "id,subject,start,end,originalStartTimeZone,isAllDay,isCancelled,isOrganizer,type,bodyPreview,location,locations";
    private static readonly HttpClient Transport = CreateTransport();

    internal static HttpClient CreateTransport() => new(new HttpClientHandler
    {
        AllowAutoRedirect = false, UseCookies = false,
        AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate
    });

    public async Task<RemoteCalendar[]> ListCalendarsAsync(CalendarAuthorization auth, CancellationToken cancellation)
    {
        bool google = auth.Registration.Kind == CalendarAccountKind.Google;
        var url = new Uri(google ? Google + "users/me/calendarList?maxResults=250" :
            Graph + "me/calendars?$select=id,name,canEdit,isDefaultCalendar&$top=100");
        var rows = await ListAsync(auth, url, google ? "items" : "value", cancellation).ConfigureAwait(false);
        return rows.Select(row =>
        {
            string? id = Text(row, "id");
            if (!IsId(id) || google && Text(row, "accessRole") == "freeBusyReader" || google && Flag(row, "deleted")) return null;
            string? name = google ? Text(row, "summaryOverride") ?? Text(row, "summary") : Text(row, "name");
            bool write = google ? Text(row, "accessRole") is "owner" or "writer" : Flag(row, "canEdit");
            string? zone = google ? Text(row, "timeZone") : null;
            return new RemoteCalendar(id!, string.IsNullOrWhiteSpace(name) ? "Calendar" : Shorten(name, 256),
                write, Flag(row, google ? "primary" : "isDefaultCalendar"), zone is { Length: <= 128 } ? zone : null);
        }).OfType<RemoteCalendar>().DistinctBy(row => row.Id).OrderByDescending(row => row.Primary)
          .ThenBy(row => row.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
    }

    public async Task<CalendarEntry[]> ListEventsAsync(CalendarAuthorization auth, ConnectedCalendar calendar,
        string calendarId, DateOnly first, DateOnly end, string zone, CancellationToken cancellation)
    {
        bool google = CheckKind(auth, calendar);
        if (end <= first || end.DayNumber - first.DayNumber > 62) throw new ArgumentException("Choose a period of 1–62 days.");
        string from = CalendarDates.Resolve(first.AddDays(-1).ToDateTime(TimeOnly.MinValue), zone).ToString("O");
        string to = CalendarDates.Resolve(end.AddDays(1).ToDateTime(TimeOnly.MinValue), zone).ToString("O");
        string url = google ? Collection(calendar) : Collection(calendar) + "/calendarView";
        var rows = await ListAsync(auth, WithQuery(url, google ? new Dictionary<string, string>
        {
            ["timeMin"] = from, ["timeMax"] = to, ["singleEvents"] = "true", ["showDeleted"] = "false", ["maxResults"] = "250"
        } : new()
        {
            ["startDateTime"] = from, ["endDateTime"] = to, ["$select"] = GraphFields, ["$top"] = "250"
        }), google ? "items" : "value", cancellation).ConfigureAwait(false);
        var result = new List<CalendarEntry>();
        var start = CalendarDates.Resolve(first.ToDateTime(TimeOnly.MinValue), zone);
        var finish = CalendarDates.Resolve(end.ToDateTime(TimeOnly.MinValue), zone);
        foreach (var row in rows)
        {
            cancellation.ThrowIfCancellationRequested();
            var entry = ParseEvent(row, calendar, calendarId);
            if (entry is not null && (entry.AllDay
                ? entry.StartDate < end && entry.EndDateExclusive > first
                : entry.Start < finish && (entry.End > start || entry.Start == entry.End && entry.Start >= start)))
                result.Add(entry);
        }
        return result.DistinctBy(item => item.Id).ToArray();
    }

    public async Task<CalendarEntry> GetAsync(CalendarAuthorization auth, ConnectedCalendar calendar, string calendarId,
        string eventId, CancellationToken cancellation)
    {
        bool google = CheckKind(auth, calendar);
        string url = EventUrl(calendar, eventId);
        var address = google ? new Uri(url) : WithQuery(url, new() { ["$select"] = GraphFields });
        using var result = await SendAsync(auth, HttpMethod.Get, address, null, null, cancellation).ConfigureAwait(false);
        return ParseEvent(result.RootElement, calendar, calendarId) ?? throw Missing();
    }

    public async Task SaveAsync(CalendarAuthorization auth, ConnectedCalendar calendar, CalendarEntry draft, CalendarEntry? original,
        CancellationToken cancellation)
    {
        bool google = CheckKind(auth, calendar);
        if (!calendar.Calendar.Writable || draft.TaskId is not null || draft.Alarms.Length > 0 ||
            original is not null && (draft.Id != original.Id || draft.CalendarId != original.CalendarId || draft.Connected != original.Connected) ||
            original is null && draft.Connected is not null)
            throw new InvalidOperationException("Choose a writable connected calendar for this event.");
        draft.Validate(allowZeroDuration: original is not null && CalendarDates.SameDates(draft, original));
        var uri = new Uri(google ? Collection(calendar) : Collection(calendar) + "/events");
        if (original is null)
        {
            var payload = Fields(calendar.Kind, draft, null);
            if (google) payload["id"] = Guid.Parse(draft.Id).ToString("N");
            else payload["transactionId"] = draft.Id;
            using var created = await SendAsync(auth, HttpMethod.Post, uri, payload, null, cancellation).ConfigureAwait(false);
            return;
        }

        var current = await VerifyCurrentAsync(auth, calendar, original, cancellation).ConfigureAwait(false);
        var changes = Fields(calendar.Kind, draft, original);
        if (changes.Count == 0) return;
        string url = EventUrl(calendar, current.Id);
        uri = google ? WithQuery(url, new() { ["sendUpdates"] = "all" }) : new Uri(url);
        using var saved = await SendAsync(auth, HttpMethod.Patch, uri, changes, current.Version, cancellation).ConfigureAwait(false);
    }

    public async Task DeleteAsync(CalendarAuthorization auth, ConnectedCalendar calendar, CalendarEntry original, CancellationToken cancellation)
    {
        bool google = CheckKind(auth, calendar);
        var current = await VerifyCurrentAsync(auth, calendar, original, cancellation).ConfigureAwait(false);
        string url = EventUrl(calendar, current.Id);
        using var deleted = await SendAsync(auth, HttpMethod.Delete,
            google ? WithQuery(url, new() { ["sendUpdates"] = "all" }) : new Uri(url),
            null, current.Version, cancellation).ConfigureAwait(false);
    }

    private async Task<ConnectedEvent> VerifyCurrentAsync(CalendarAuthorization auth, ConnectedCalendar calendar,
        CalendarEntry original, CancellationToken cancellation)
    {
        if (!calendar.Calendar.Writable || !original.CanEdit ||
            original.Connected is not { Version: not null } previous)
            throw new InvalidOperationException("This event is read-only in Takt.");
        var current = await GetAsync(auth, calendar, original.CalendarId, previous.Id, cancellation).ConfigureAwait(false);
        if (current.Connected != previous || !current.CanEdit)
            throw new CalendarConflictException("This event changed in the connected calendar. Close and reopen it before saving.");
        return previous;
    }

    private async Task<List<JsonElement>> ListAsync(CalendarAuthorization auth, Uri first, string collection, CancellationToken cancellation)
    {
        bool google = auth.Registration.Kind == CalendarAccountKind.Google;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(22));
        var result = new List<JsonElement>();
        Uri? address = first;
        var visited = new HashSet<Uri>();
        try
        {
            while (address is not null)
            {
                if (visited.Count == MaxPages || !visited.Add(address))
                    throw new InvalidDataException("Too many results from this calendar for the selected period.");
                using var response = await SendAsync(auth, HttpMethod.Get, address, null, null, timeout.Token).ConfigureAwait(false);
                var root = response.RootElement;
                var rows = Property(root, collection);
                if (rows.ValueKind == JsonValueKind.Array && rows.GetArrayLength() <= 250)
                    result.AddRange(rows.EnumerateArray().Select(row => row.Clone()));
                else if (!google || root.ValueKind != JsonValueKind.Object || rows.ValueKind != JsonValueKind.Undefined)
                    throw new InvalidDataException("The provider returned an invalid calendar list.");
                if (google)
                {
                    string? next = Text(root, "nextPageToken");
                    address = next is null ? null : WithQuery(first.AbsoluteUri, new() { ["pageToken"] = next });
                }
                else
                {
                    string? next = Text(root, "@odata.nextLink");
                    address = next is null ? null : GraphPage(first, next);
                }
            }
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        { throw new TimeoutException("The connected calendar took too long to load."); }
        return result;
    }

    private async Task<JsonDocument> SendAsync(CalendarAuthorization auth, HttpMethod method, Uri address,
        Dictionary<string, object?>? body, string? version, CancellationToken cancellation)
    {
        bool google = auth.Registration.Kind == CalendarAccountKind.Google;
        var root = new Uri(google ? Google : Graph);
        if (!IsOrigin(address, root) || !address.AbsolutePath.StartsWith(root.AbsolutePath, StringComparison.Ordinal) ||
            !CalendarAccountOAuth.SafeValue(auth.AccessToken, 16384))
            throw new InvalidOperationException("The calendar request does not match the connected provider.");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        using var request = new HttpRequestMessage(method, address);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", auth.AccessToken);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (!google) request.Headers.Add("Prefer", "IdType=\"ImmutableId\", outlook.timezone=\"UTC\"");
        if (version is not null) request.Headers.IfMatch.Add(EntityTagHeaderValue.Parse(version));
        if (body is not null) request.Content = JsonContent.Create(body);
        try
        {
            using var response = await (http ?? Transport).SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            if (response.RequestMessage?.RequestUri is { } actual && actual != address)
                throw new InvalidOperationException("The calendar provider returned an unexpected address.");
            if (response.StatusCode is HttpStatusCode.PreconditionFailed or HttpStatusCode.Conflict)
                throw new CalendarConflictException("The provider reported a conflict. Reload the calendar before trying again.");
            if (response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.Gone) throw Missing();
            if (response.StatusCode == HttpStatusCode.Unauthorized)
                throw new CalendarAuthorizationExpiredException();
            if (response.StatusCode == HttpStatusCode.Forbidden)
                throw new InvalidOperationException("The provider did not grant access to this calendar or event. Check its permissions.");
            if (!response.IsSuccessStatusCode)
                throw new InvalidOperationException($"The connected calendar could not complete the request (HTTP {(int)response.StatusCode}).");
            // A successful write is committed even if the provider's optional reply body cannot be read.
            return method != HttpMethod.Get ? JsonDocument.Parse("{}") :
                await ReadJsonAsync(response.Content, 8 * 1024 * 1024, timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        { throw new TimeoutException("The calendar request timed out. Refresh the calendar to check the result."); }
        catch (HttpRequestException)
        { throw new InvalidOperationException("Takt could not reach the calendar service. Check your connection, then refresh the calendar."); }
    }

    private static bool IsOrigin(Uri candidate, Uri expected) => candidate.Scheme == "https" &&
        string.Equals(candidate.IdnHost, expected.IdnHost, StringComparison.OrdinalIgnoreCase) &&
        candidate.Port == expected.Port && candidate.UserInfo.Length == 0 && candidate.Fragment.Length == 0;
    private static Uri GraphPage(Uri first, string next) =>
        next.Length <= 8192 && Uri.TryCreate(next, UriKind.Absolute, out var page) &&
        IsOrigin(page, first) && page.AbsolutePath == first.AbsolutePath ? page :
        throw new InvalidDataException("Outlook returned an unexpected address for the next page.");

    internal static Uri WithQuery(string address, Dictionary<string, string> values)
        => new(address + (address.Contains('?') ? "&" : "?") + string.Join("&", values.Select(field =>
            Uri.EscapeDataString(field.Key) + "=" + Uri.EscapeDataString(field.Value))));

    internal static async Task<JsonDocument> ReadJsonAsync(HttpContent content, int maximum, CancellationToken cancellation)
    {
        if (content.Headers.ContentLength > maximum) throw new InvalidDataException("The calendar reply exceeds the supported size.");
        await using var stream = await content.ReadAsStreamAsync(cancellation).ConfigureAwait(false);
        using var data = new MemoryStream();
        var buffer = new byte[16384];
        int count;
        while ((count = await stream.ReadAsync(buffer, cancellation).ConfigureAwait(false)) > 0)
        {
            if (data.Length + count > maximum) throw new InvalidDataException("The calendar reply exceeds the supported size.");
            data.Write(buffer, 0, count);
        }
        try { return JsonDocument.Parse(data.GetBuffer().AsMemory(0, (int)data.Length)); }
        catch (JsonException) { throw new InvalidDataException("The provider returned invalid calendar data."); }
    }

    private static bool CheckKind(CalendarAuthorization auth, ConnectedCalendar calendar) =>
        auth.Registration.Kind != calendar.Kind ? throw new InvalidOperationException("This calendar belongs to another provider.") :
        calendar.Kind == CalendarAccountKind.Google;
    private static CalendarConflictException Missing() => new("The calendar or event is no longer available. Refresh the calendar.");
    private static string Collection(ConnectedCalendar calendar) => calendar.Kind == CalendarAccountKind.Google
        ? Google + "calendars/" + Segment(calendar.Calendar.Id) + "/events"
        : Graph + "me/calendars/" + Segment(calendar.Calendar.Id);
    private static string EventUrl(ConnectedCalendar calendar, string id) => Collection(calendar) +
        (calendar.Kind == CalendarAccountKind.Google ? "/" : "/events/") + Segment(id);
    private static bool IsId(string? value) => CalendarAccountOAuth.SafeValue(value, 1024) && value is not ("." or "..");
    private static string Segment(string id) => IsId(id) ? Uri.EscapeDataString(id) : throw new InvalidDataException("Invalid calendar identifier.");
    internal static string? Text(JsonElement value, string name) => Property(value, name) is { ValueKind: JsonValueKind.String } field ? field.GetString() : null;
    private static JsonElement Property(JsonElement value, string name) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var field) ? field : default;
    private static bool Flag(JsonElement value, string name) => Property(value, name).ValueKind == JsonValueKind.True;
    private static string Shorten(string value, int length) => value.Length <= length ? value : value[..length];
}

public sealed class CalendarAuthorizationExpiredException() : InvalidOperationException("Sign in again from Calendar accounts to renew access.");
