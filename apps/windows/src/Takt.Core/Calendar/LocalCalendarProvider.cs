using Microsoft.Data.Sqlite;
using System.Globalization;
using System.Text.Json;

namespace Takt.Core.Calendar;

// A real, offline provider. No Windows account permissions, task API or network calls.
// Every mutation re-reads and writes under SQLite's immediate transaction, including
// cross-process writers; stale UI revisions cannot delete a freshly edited event.
public sealed class LocalCalendarProvider(string databasePath, bool pooling = true) : ICalendarProvider
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private bool disposed;
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private async Task<T> Access<T>(string workspace, Func<CalendarSnapshot, (CalendarSnapshot State, T Result)> operation, bool write, CancellationToken cancellation)
    {
        if (string.IsNullOrWhiteSpace(workspace) || workspace.Length > 4096) throw new ArgumentException("A calendar workspace is required.", nameof(workspace));
        await gate.WaitAsync(cancellation);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(databasePath))!);
            using var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = databasePath, Pooling = pooling, Mode = SqliteOpenMode.ReadWriteCreate, DefaultTimeout = 10 }.ToString());
            await connection.OpenAsync(cancellation);
            using (var schema = connection.CreateCommand()) { schema.CommandText = "CREATE TABLE IF NOT EXISTS calendar_documents(workspace TEXT PRIMARY KEY, payload TEXT NOT NULL)"; await schema.ExecuteNonQueryAsync(cancellation); }
            using var transaction = connection.BeginTransaction();
            using var read = connection.CreateCommand(); read.Transaction = transaction; read.CommandText = "SELECT payload FROM calendar_documents WHERE workspace=$scope"; read.Parameters.AddWithValue("$scope", workspace);
            var text = await read.ExecuteScalarAsync(cancellation) as string;
            var state = text is null ? CalendarSnapshot.Empty : JsonSerializer.Deserialize<CalendarSnapshot>(text, Json) ?? throw new InvalidDataException("The local calendar document is invalid.");
            var outcome = operation(state);
            if (write && !ReferenceEquals(outcome.State, state))
            {
                using var save = connection.CreateCommand(); save.Transaction = transaction;
                save.CommandText = "INSERT INTO calendar_documents(workspace,payload) VALUES($scope,$payload) ON CONFLICT(workspace) DO UPDATE SET payload=excluded.payload";
                save.Parameters.AddWithValue("$scope", workspace); save.Parameters.AddWithValue("$payload", JsonSerializer.Serialize(outcome.State, Json));
                await save.ExecuteNonQueryAsync(cancellation);
            }
            transaction.Commit(); return outcome.Result;
        }
        finally { gate.Release(); }
    }
    public Task<CalendarSnapshot> ReadAsync(string workspace, CancellationToken cancellation = default) => Access(workspace, s => (s, s), false, cancellation);
    public async Task<CalendarQueryResult> QueryAsync(string workspace, DateOnly first, DateOnly endExclusive, string displayZone, bool visibleOnly = true, CancellationToken cancellation = default)
    {
        if (endExclusive <= first || endExclusive.DayNumber - first.DayNumber > 400) throw new ArgumentException("Choose a calendar period of 1–400 days.");
        var state = await ReadAsync(workspace, cancellation);
        return await Task.Run<CalendarQueryResult>(() =>
        {
            var visible = state.Calendars.Where(c => !visibleOnly || c.Visible).Select(c => c.Id).ToHashSet();
            var entries = state.Events.Where(e => visible.Contains(e.CalendarId) && (e.AllDay ? e.StartDate < endExclusive && e.EndDateExclusive > first : e.Start < CalendarDates.Resolve(endExclusive.ToDateTime(TimeOnly.MinValue), displayZone) && (e.End > CalendarDates.Resolve(first.ToDateTime(TimeOnly.MinValue), displayZone) || e.Start == e.End && e.Start >= CalendarDates.Resolve(first.ToDateTime(TimeOnly.MinValue), displayZone)))).ToList();
            var warnings = new List<string>();
            foreach (var definition in state.Calendars.Where(c => visible.Contains(c.Id) && c.SnapshotIcs is not null))
            {
                cancellation.ThrowIfCancellationRequested();
                try { entries.AddRange(CalendarIcs.Expand(definition, first, endExclusive, displayZone)); }
                catch (InvalidDataException e) { warnings.Add(definition.Name + ": " + e.Message); }
            }
            return new(entries.OrderBy(e => e.Start).ThenBy(e => e.Id, StringComparer.Ordinal).ToList(), warnings);
        }, cancellation);
    }
    public async Task<CalendarEntry?> GetEventAsync(string workspace, string id, CancellationToken cancellation = default)
    {
        var state = await ReadAsync(workspace, cancellation);
        if (!id.StartsWith("ics|", StringComparison.Ordinal)) return state.Events.FirstOrDefault(e => e.Id == id);
        var parts = id.Split('|');
        if (parts.Length != 4 || !long.TryParse(parts[3], CultureInfo.InvariantCulture, out long ticks) || ticks < DateTimeOffset.MinValue.Ticks || ticks > DateTimeOffset.MaxValue.Ticks) return null;
        var day = DateOnly.FromDateTime(new DateTimeOffset(ticks, TimeSpan.Zero).UtcDateTime);
        var definition = state.Calendars.FirstOrDefault(c => c.Id == parts[1]);
        if (definition is null) return null;
        return (await Task.Run(() => CalendarIcs.Expand(definition, day.AddDays(-2), day.AddDays(3), TimeZoneInfo.Local.Id), cancellation)).FirstOrDefault(e => e.Id == id);
    }
    private static CalendarDefinition Writable(CalendarSnapshot s, string id) => s.Calendars.FirstOrDefault(c => c.Id == id && c.Writable && c.SnapshotIcs is null) ?? throw new InvalidOperationException("Choose a writable local calendar.");
    private static CalendarEntry Current(CalendarSnapshot state, string id) => state.Events.FirstOrDefault(e => e.Id == id) ?? throw new CalendarConflictException("The event was deleted. Your draft has not been saved.");
    public Task<CalendarEntry> SaveAsync(string workspace, CalendarEntry draft, CalendarEntry? original = null, CancellationToken cancellation = default) => Access(workspace, s =>
    {
        if (!draft.CanEdit || draft.Connected is not null || draft.Id.StartsWith("ics|", StringComparison.Ordinal)) throw new InvalidOperationException(draft.ReadOnlyReason ?? "Imported events cannot be changed.");
        CalendarEntry saved;
        if (original is null)
        {
            if (s.Events.Any(e => e.Id == draft.Id)) throw new CalendarConflictException("This event already exists.");
            saved = draft with { Revision = 1 };
        }
        else
        {
            var current = Current(s, original.Id); _ = Writable(s, current.CalendarId);
            saved = CalendarDates.Merge(original, draft, current) with { Revision = checked(current.Revision + 1) };
        }
        _ = Writable(s, saved.CalendarId); saved.Validate();
        return (s with { Events = s.Events.Where(e => e.Id != saved.Id).Append(saved).ToArray() }, saved);
    }, true, cancellation);
    public Task DeleteAsync(string workspace, CalendarEntry original, CancellationToken cancellation = default) => Access(workspace, s =>
    {
        var current = Current(s, original.Id); _ = Writable(s, current.CalendarId);
        if (!current.CanEdit) throw new InvalidOperationException(current.ReadOnlyReason);
        if (current.Revision != original.Revision) throw new CalendarConflictException("The event changed before deletion. Reopen it to review the latest version.");
        return (s with { Events = s.Events.Where(e => e.Id != current.Id).ToArray() }, true);
    }, true, cancellation);
    public Task<CalendarMove> MoveAsync(string workspace, CalendarEntry original, DateOnly source, DateOnly target, string displayZone, CancellationToken cancellation = default) => Access(workspace, s =>
    {
        var current = Current(s, original.Id); _ = Writable(s, current.CalendarId);
        if (!CalendarDates.SameDates(current, original)) throw new CalendarConflictException("The event's dates changed since dragging began.");
        var moved = CalendarDates.Move(current, source, target, displayZone) with { Revision = checked(current.Revision + 1) }; moved.Validate();
        return (s with { Events = s.Events.Select(e => e.Id == moved.Id ? moved : e).ToArray() }, new CalendarMove(current, moved));
    }, true, cancellation);
    public Task<CalendarEntry> UndoMoveAsync(string workspace, CalendarMove move, CancellationToken cancellation = default) => Access(workspace, s =>
    {
        var current = Current(s, move.After.Id); _ = Writable(s, current.CalendarId);
        if (!current.CanEdit || !CalendarDates.SameDates(current, move.After)) throw new CalendarConflictException("Undo is unavailable because the event was rescheduled again.");
        var restored = current with { Start = move.Before.Start, End = move.Before.End, Zone = move.Before.Zone, AllDay = move.Before.AllDay, StartDate = move.Before.StartDate, EndDateExclusive = move.Before.EndDateExclusive, Revision = checked(current.Revision + 1) };
        restored.Validate(); return (s with { Events = s.Events.Select(e => e.Id == restored.Id ? restored : e).ToArray() }, restored);
    }, true, cancellation);
    public Task ConfigureAsync(string workspace, IReadOnlyCollection<string> visible, string defaultCalendar, CancellationToken cancellation = default) => Access(workspace, s =>
    {
        _ = Writable(s, defaultCalendar);
        if (visible.Any(id => !s.Calendars.Any(c => c.Id == id))) throw new InvalidDataException("A selected calendar no longer exists.");
        return (s with { Calendars = s.Calendars.Select(c => c with { Visible = visible.Contains(c.Id) }).ToArray(), DefaultCalendarId = defaultCalendar }, true);
    }, true, cancellation);
    public Task<CalendarDefinition> ImportAsync(string workspace, string name, string ics, CancellationToken cancellation = default)
        => AddCalendarAsync(workspace, Guid.NewGuid().ToString("D"), name, ics, null, cancellation);

    public Task<CalendarDefinition> SubscribeAsync(string workspace, string id, string name, string ics, CalendarFeed feed, CancellationToken cancellation = default)
        => AddCalendarAsync(workspace, id, name, ics, feed, cancellation);

    private async Task<CalendarDefinition> AddCalendarAsync(string workspace, string id, string name, string ics, CalendarFeed? feed, CancellationToken cancellation)
    {
        if (!Guid.TryParseExact(id, "D", out _) || string.IsNullOrWhiteSpace(name) || name.Length > 256)
            throw new InvalidDataException("Choose a calendar name of at most 256 characters.");
        await Task.Run(() => CalendarIcs.Parse(ics), cancellation);
        return await Access(workspace, state =>
        {
            if (state.Calendars.Length >= 32 || state.Calendars.Any(item => item.Id == id))
                throw new InvalidDataException("Remove an imported calendar before adding another.");
            var calendar = new CalendarDefinition(id, name.Trim(), false, SnapshotIcs: ics, Feed: feed);
            var next = state.Calendars.Append(calendar).ToArray();
            ValidateCacheSize(next);
            return (state with { Calendars = next }, calendar);
        }, true, cancellation);
    }

    public async Task<bool> UpdateSubscriptionAsync(string workspace, CalendarDefinition previous, string? ics, CalendarFeed feed, CancellationToken cancellation = default)
    {
        if (previous.Feed is null || previous.Feed.ProtectedAddress != feed.ProtectedAddress)
            throw new InvalidDataException("The subscription no longer matches this update.");
        if (ics is not null) await Task.Run(() => CalendarIcs.Parse(ics), cancellation);
        return await Access(workspace, state =>
        {
            var current = state.Calendars.FirstOrDefault(item => item.Id == previous.Id);
            if (current is null || current.Feed != previous.Feed) return (state, false);
            var updated = current with { SnapshotIcs = ics ?? current.SnapshotIcs, Feed = feed };
            var next = state.Calendars.Select(item => item.Id == updated.Id ? updated : item).ToArray();
            ValidateCacheSize(next);
            return (state with { Calendars = next }, ics is not null && !string.Equals(ics, current.SnapshotIcs, StringComparison.Ordinal));
        }, true, cancellation);
    }

    private static void ValidateCacheSize(IEnumerable<CalendarDefinition> calendars)
    {
        long bytes = calendars.Sum(item => (long)System.Text.Encoding.UTF8.GetByteCount(item.SnapshotIcs ?? ""));
        if (bytes > 32 * 1024 * 1024)
            throw new InvalidDataException("Imported and subscribed calendars exceed the combined 32 MiB limit.");
    }
    public Task RemoveSnapshotAsync(string workspace, string calendarId, CancellationToken cancellation = default) => Access(workspace, s =>
    {
        if (!s.Calendars.Any(c => c.Id == calendarId && c.SnapshotIcs is not null)) throw new InvalidOperationException("Only imported snapshots can be removed.");
        return (s with { Calendars = s.Calendars.Where(c => c.Id != calendarId).ToArray() }, true);
    }, true, cancellation);
    public async Task<string> ExportAsync(string workspace, string calendarId, CancellationToken cancellation = default)
    {
        var s = await ReadAsync(workspace, cancellation); var definition = s.Calendars.FirstOrDefault(c => c.Id == calendarId) ?? throw new InvalidOperationException("The calendar no longer exists.");
        return CalendarIcs.Export(definition, s.Events.Where(e => e.CalendarId == calendarId));
    }
    public Task DetachMissingTaskLinksAsync(string workspace, IReadOnlySet<string> existingTaskIds, CancellationToken cancellation = default) => Access(workspace, state =>
    {
        bool IsMissing(CalendarEntry entry) => entry.TaskId is { } id && !existingTaskIds.Contains(id);
        if (!state.Events.Any(IsMissing)) return (state, false);
        var events = state.Events.Select(entry => IsMissing(entry)
            ? entry with { TaskId = null, Revision = checked(entry.Revision + 1) }
            : entry).ToArray();
        return (state with { Events = events }, true);
    }, true, cancellation);
    public async Task RestoreLocalAsync(CalendarSnapshot snapshot, IReadOnlySet<string> taskIds, CancellationToken cancellation)
    {
        if (snapshot.Calendars is not { Length: > 0 and <= 32 } || snapshot.Events is null ||
            snapshot.Events.Length > 100000 || snapshot.Calendars.Any(item => item is null ||
                item.Feed is not null || item.Connected is not null || string.IsNullOrWhiteSpace(item.Name) || item.Name.Length > 256 ||
                item.Id != "local" && !Guid.TryParseExact(item.Id, "D", out _) ||
                item.Writable != (item.Id == "local") || item.Writable == (item.SnapshotIcs is not null)) ||
            snapshot.Calendars.Select(item => item.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != snapshot.Calendars.Length ||
            snapshot.DefaultCalendarId != "local" || !snapshot.Calendars.Any(item => item.Id == "local"))
            throw new InvalidDataException("The calendar backup options are invalid.");

        ValidateCacheSize(snapshot.Calendars);
        foreach (var calendar in snapshot.Calendars)
            if (calendar.SnapshotIcs is { } ics)
                await Task.Run(() => CalendarIcs.Parse(ics), cancellation);

        if (snapshot.Events.Any(entry => entry is null || !entry.CanEdit || entry.Connected is not null || entry.CalendarId != "local") ||
            snapshot.Events.Select(entry => entry.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != snapshot.Events.Length)
            throw new InvalidDataException("The calendar backup contains invalid or duplicate events.");
        var events = snapshot.Events.Select(entry => entry with
        {
            TaskId = entry.TaskId is { } task && taskIds.Contains(task) ? task : null,
            Revision = 1
        }).ToArray();
        foreach (var entry in events) entry.Validate();
        await Access("local", state =>
        {
            if (state.Events.Length != 0 || state.Calendars.Length != 1)
                throw new InvalidOperationException("Restore requires a fresh calendar.");
            return (snapshot with { Events = events }, true);
        }, true, cancellation);
    }

    public async ValueTask DisposeAsync() { await gate.WaitAsync(); try { disposed = true; } finally { gate.Release(); } }
}
