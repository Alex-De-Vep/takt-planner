namespace Takt.Core.Calendar;

// Provider boundaries deliberately exclude task sync and device accounts.
public interface ICalendarProvider : IAsyncDisposable
{
    Task<CalendarSnapshot> ReadAsync(string workspace, CancellationToken cancellation = default);
    Task<CalendarQueryResult> QueryAsync(string workspace, DateOnly first, DateOnly endExclusive, string displayZone, bool visibleOnly = true, CancellationToken cancellation = default);
    Task<CalendarEntry?> GetEventAsync(string workspace, string id, CancellationToken cancellation = default);
    Task<CalendarEntry> SaveAsync(string workspace, CalendarEntry draft, CalendarEntry? original = null, CancellationToken cancellation = default);
    Task DeleteAsync(string workspace, CalendarEntry original, CancellationToken cancellation = default);
    Task<CalendarMove> MoveAsync(string workspace, CalendarEntry original, DateOnly source, DateOnly target, string displayZone, CancellationToken cancellation = default);
    Task<CalendarEntry> UndoMoveAsync(string workspace, CalendarMove move, CancellationToken cancellation = default);
    Task ConfigureAsync(string workspace, IReadOnlyCollection<string> visible, string defaultCalendar, CancellationToken cancellation = default);
    Task<CalendarDefinition> ImportAsync(string workspace, string name, string ics, CancellationToken cancellation = default);
    Task<CalendarDefinition> SubscribeAsync(string workspace, string id, string name, string ics, CalendarFeed feed, CancellationToken cancellation = default);
    Task<bool> UpdateSubscriptionAsync(string workspace, CalendarDefinition previous, string? ics, CalendarFeed feed, CancellationToken cancellation = default);
    Task RemoveSnapshotAsync(string workspace, string calendarId, CancellationToken cancellation = default);
    Task DetachMissingTaskLinksAsync(string workspace, IReadOnlySet<string> existingTaskIds, CancellationToken cancellation = default);
    Task<string> ExportAsync(string workspace, string calendarId, CancellationToken cancellation = default);
}
