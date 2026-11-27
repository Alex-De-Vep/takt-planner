using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Takt.Core.Calendar;

namespace Takt.Windows.Services;

internal sealed class ConnectedCalendars(string directory)
{
    private sealed record Connection(Guid Id, CalendarAccountKind Kind, string Credential, RemoteCalendar[] Calendars, string[] Visible);
    private readonly CalendarAccountOAuth oauth = new();
    private readonly CalendarAccountClient client = new();
    private readonly WindowsVault vault = new();
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly SemaphoreSlim downloads = new(4, 4);
    private const int MaxSettingsBytes = 4 * 1024 * 1024;

    public CalendarDefinition[] Definitions(string workspace) => Read(workspace).SelectMany(account =>
        account.Calendars.Select(calendar => new CalendarDefinition(DisplayId(account.Id, calendar.Id),
            calendar.Name + (account.Kind == CalendarAccountKind.Google ? " · Google" : " · Outlook"),
            calendar.Writable, account.Visible.Contains(calendar.Id, StringComparer.Ordinal),
            Connected: new(account.Id, account.Kind, calendar)))).ToArray();

    public CalendarAccountKind[] Kinds(string workspace) => Read(workspace).Select(account => account.Kind).ToArray();

    public CalendarRegistration? Registration(string workspace, CalendarAccountKind kind)
    {
        var connection = Read(workspace).SingleOrDefault(item => item.Kind == kind);
        return connection is null ? null : Open(workspace, connection).Registration;
    }

    public async Task ConnectAsync(string workspace, CalendarRegistration registration, Func<Uri, Task> openBrowser,
        CancellationToken cancellation)
    {
        var authorization = await oauth.SignInAsync(registration, openBrowser, cancellation);
        var calendars = await client.ListCalendarsAsync(authorization, cancellation);
        if (calendars.Length == 0) throw new InvalidOperationException($"{registration.Name} returned no calendars.");
        var id = Guid.NewGuid();
        var primary = calendars.FirstOrDefault(item => item.Primary) ?? calendars[0];
        await gate.WaitAsync(cancellation);
        try
        {
            var accounts = Read(workspace);
            var previous = accounts.SingleOrDefault(item => item.Kind == registration.Kind);
            var visible = primary.Primary && previous?.Calendars.Any(item => item.Primary && item.Id == primary.Id) == true
                ? previous.Visible.Where(previousId => calendars.Any(item => item.Id == previousId)).ToArray()
                : [primary.Id];
            var account = new Connection(id, registration.Kind, Seal(workspace, id, authorization), calendars, visible);
            Write(workspace, accounts.Where(item => item.Kind != account.Kind).Append(account).ToArray(), cancellation);
        }
        finally { gate.Release(); }
    }

    public async Task DisconnectAsync(string workspace, CalendarAccountKind kind, CancellationToken cancellation)
    {
        await gate.WaitAsync(cancellation);
        try { Write(workspace, Read(workspace).Where(item => item.Kind != kind).ToArray(), cancellation); }
        finally { gate.Release(); }
    }

    public async Task SetVisibilityAsync(string workspace, IReadOnlySet<string> visible, CancellationToken cancellation)
    {
        await gate.WaitAsync(cancellation);
        try
        {
            var accounts = Read(workspace);
            if (accounts.Length > 0)
                Write(workspace, accounts.Select(account => account with
                {
                    Visible = account.Calendars.Where(item => visible.Contains(DisplayId(account.Id, item.Id)))
                        .Select(item => item.Id).ToArray()
                }).ToArray(), cancellation);
        }
        finally { gate.Release(); }
    }

    public async Task<string[]> RefreshCalendarListsAsync(string workspace, CancellationToken cancellation)
    {
        var failures = new List<string>();
        foreach (var account in Read(workspace))
        {
            try
            {
                var calendars = await ReadAuthorizedAsync(workspace, account.Id, auth => client.ListCalendarsAsync(auth, cancellation), cancellation);
                await gate.WaitAsync(cancellation);
                try
                {
                    var active = Read(workspace);
                    if (active.Any(item => item.Id == account.Id))
                        Write(workspace, active.Select(item => item.Id != account.Id ? item : item with
                        {
                            Calendars = calendars,
                            Visible = item.Visible.Where(id => calendars.Any(cal => cal.Id == id)).ToArray()
                        }).ToArray(), cancellation);
                }
                finally { gate.Release(); }
            }
            catch (Exception error) when (!cancellation.IsCancellationRequested)
            { failures.Add(ProviderName(account.Kind) + ": " + Describe(error)); }
        }
        return failures.ToArray();
    }

    public async Task<CalendarQueryResult> QueryAsync(string workspace, CalendarDefinition[] definitions, DateOnly first,
        DateOnly end, string zone, CancellationToken cancellation)
    {
        var results = await Task.WhenAll(definitions.Where(definition => definition.Visible && definition.Connected is not null)
            .Select(async definition =>
            {
                var reference = definition.Connected!;
                await downloads.WaitAsync(cancellation);
                try
                {
                    var entries = await ReadAuthorizedAsync(workspace, reference.ConnectionId,
                        auth => client.ListEventsAsync(auth, reference, definition.Id, first, end, zone, cancellation), cancellation);
                    return (Entries: entries, Warning: (string?)null);
                }
                catch (Exception error) when (!cancellation.IsCancellationRequested)
                { return (Entries: Array.Empty<CalendarEntry>(), Warning: definition.Name + ": " + Describe(error)); }
                finally { downloads.Release(); }
            }));
        return new(results.SelectMany(item => item.Entries).ToList(),
            results.Select(item => item.Warning).OfType<string>().Distinct().ToList());
    }

    public Task<CalendarEntry> GetAsync(string workspace, CalendarEntry original, CancellationToken cancellation)
    {
        var calendar = CalendarFor(workspace, original.CalendarId);
        var reference = original.Connected ?? throw new InvalidOperationException("Reopen this connected event.");
        return ReadAuthorizedAsync(workspace, calendar.ConnectionId,
            auth => client.GetAsync(auth, calendar, original.CalendarId, reference.Id, cancellation), cancellation);
    }

    public async Task SaveAsync(string workspace, CalendarEntry draft, CalendarEntry? original, CancellationToken cancellation)
    {
        var calendar = CalendarFor(workspace, draft.CalendarId);
        var authorization = await AuthorizeAsync(workspace, calendar.ConnectionId, null, cancellation);
        cancellation.ThrowIfCancellationRequested();
        await client.SaveAsync(authorization, calendar, draft, original, cancellation);
    }

    public async Task DeleteAsync(string workspace, CalendarEntry original, CancellationToken cancellation)
    {
        var calendar = CalendarFor(workspace, original.CalendarId);
        var authorization = await AuthorizeAsync(workspace, calendar.ConnectionId, null, cancellation);
        cancellation.ThrowIfCancellationRequested();
        await client.DeleteAsync(authorization, calendar, original, cancellation);
    }

    private ConnectedCalendar CalendarFor(string workspace, string id) =>
        Definitions(workspace).FirstOrDefault(item => item.Id == id)?.Connected ??
        throw new CalendarConflictException("This connected calendar is no longer available. Reopen the calendar.");

    private async Task<T> ReadAuthorizedAsync<T>(string workspace, Guid id, Func<CalendarAuthorization, Task<T>> request,
        CancellationToken cancellation)
    {
        var auth = await AuthorizeAsync(workspace, id, null, cancellation);
        try { return await request(auth); }
        catch (CalendarAuthorizationExpiredException)
        { return await request(await AuthorizeAsync(workspace, id, auth.AccessToken, cancellation)); }
    }

    private async Task<CalendarAuthorization> AuthorizeAsync(string workspace, Guid id, string? rejected, CancellationToken cancellation)
    {
        await gate.WaitAsync(cancellation);
        try
        {
            var accounts = Read(workspace);
            var account = accounts.SingleOrDefault(item => item.Id == id)
                ?? throw new CalendarConflictException("This calendar account was disconnected. Reopen the calendar.");
            var authorization = Open(workspace, account);
            if (authorization.Expires > DateTimeOffset.UtcNow.AddMinutes(1) && authorization.AccessToken != rejected)
                return authorization;
            // Finish a bounded refresh and save the new token even if the user navigates away.
            var renewed = await oauth.RefreshAsync(authorization, CancellationToken.None);
            var replacement = account with { Credential = Seal(workspace, id, renewed) };
            Write(workspace, accounts.Select(item => item.Id == id ? replacement : item).ToArray(), CancellationToken.None);
            cancellation.ThrowIfCancellationRequested();
            return renewed;
        }
        finally { gate.Release(); }
    }

    private string PathFor(string workspace) => Path.Combine(directory, "calendar-accounts-" +
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(workspace))) + ".json");

    private Connection[] Read(string workspace)
    {
        string path = PathFor(workspace);
        if (!File.Exists(path)) return [];
        if (new FileInfo(path).Length > MaxSettingsBytes) throw new InvalidDataException("Calendar connections exceed the supported size.");
        var accounts = JsonSerializer.Deserialize<Connection[]>(File.ReadAllText(path));
        if (accounts is null || accounts.Length > 2 || accounts.Any(account => account is null || account.Id == Guid.Empty ||
            account.Kind is not (CalendarAccountKind.Google or CalendarAccountKind.Outlook) ||
            account.Credential is not { Length: > 0 and <= 150000 } || account.Calendars is null || account.Visible is null ||
            account.Calendars.Any(item => item is null || item.Id is not { Length: > 0 and <= 1024 } || item.Name is not { Length: > 0 and <= 256 })))
            throw new InvalidDataException("Calendar connections could not be read.");
        if (accounts.Select(item => item.Kind).Distinct().Count() != accounts.Length ||
            accounts.Select(item => item.Id).Distinct().Count() != accounts.Length)
            throw new InvalidDataException("Calendar connections could not be read.");
        return accounts;
    }

    private void Write(string workspace, Connection[] accounts, CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();
        string path = PathFor(workspace);
        if (accounts.Length == 0) { File.Delete(path); return; }
        var bytes = JsonSerializer.SerializeToUtf8Bytes(accounts);
        if (bytes.Length > MaxSettingsBytes) throw new InvalidDataException("The connected calendars exceed the supported size.");
        Directory.CreateDirectory(directory);
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(temporary, bytes);
            cancellation.ThrowIfCancellationRequested();
            File.Move(temporary, path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private CalendarAuthorization Open(string workspace, Connection account)
    {
        try
        {
            var json = vault.Open(CredentialScope(workspace, account.Id), account.Credential);
            var auth = JsonSerializer.Deserialize<CalendarAuthorization>(json);
            if (auth?.Registration?.Kind != account.Kind || auth.AccessToken is not { Length: > 0 and <= 16384 } ||
                auth.RefreshToken is not { Length: > 0 and <= 16384 })
                throw new InvalidDataException("The calendar authorization is invalid.");
            auth.Registration.Validate();
            return auth;
        }
        catch (Exception error) when (error is CryptographicException or JsonException or FormatException or InvalidDataException or ArgumentException)
        { throw new CalendarAuthorizationExpiredException(); }
    }
    private string Seal(string workspace, Guid id, CalendarAuthorization authorization)
        => vault.Seal(CredentialScope(workspace, id), JsonSerializer.Serialize(authorization));
    private static string CredentialScope(string workspace, Guid id) => $"calendar-account:{workspace}:{id:D}";
    private static string DisplayId(Guid id, string calendar) => "connected:" + id.ToString("N") + ":" +
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(calendar)));
    public static string ProviderName(CalendarAccountKind kind) => kind == CalendarAccountKind.Google ? "Google Calendar" : "Outlook";
    public static string Describe(Exception error) => error is InvalidOperationException or InvalidDataException or TimeoutException
        ? error.Message : "The connected calendar could not be read.";
}
