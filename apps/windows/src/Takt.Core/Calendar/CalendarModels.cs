using System.Globalization;
using System.Text.Json;

namespace Takt.Core.Calendar;

public enum CalendarAgendaMode { Day = 1, ThreeDays = 3, Week = 7 }
public sealed record CalendarDefinition(string Id, string Name, bool Writable, bool Visible = true, string? SnapshotIcs = null, CalendarFeed? Feed = null, ConnectedCalendar? Connected = null);
public sealed record CalendarAlarm(string Id, int? OffsetMinutes = -15, DateTimeOffset? Absolute = null)
{
    public DateTimeOffset Due(CalendarEntry entry) => Absolute ?? entry.Start.AddMinutes(OffsetMinutes ?? 0);
}
public sealed record CalendarEntry(
    string Id, string CalendarId, string Title, DateTimeOffset Start, DateTimeOffset End,
    string Zone, bool AllDay = false, DateOnly? StartDate = null, DateOnly? EndDateExclusive = null,
    string Notes = "", string Location = "", string? TaskId = null, CalendarAlarm[]? Alerts = null,
    long Revision = 0, bool ReadOnly = false, bool Recurring = false, ConnectedEvent? Connected = null)
{
    [System.Text.Json.Serialization.JsonIgnore]
    public CalendarAlarm[] Alarms => Alerts ?? [];
    public bool CanEdit => !ReadOnly && !Recurring;
    public string? ReadOnlyReason => Recurring ? "Recurring events and exceptions can only be viewed." : ReadOnly ? "This calendar or event is read-only in Takt." : null;
    public static CalendarEntry Create(string calendarId, string title, DateOnly date, string? taskId = null)
    {
        var zone = TimeZoneInfo.Local.Id;
        var start = CalendarDates.Resolve(date.ToDateTime(new TimeOnly(9, 0)), zone);
        return new(Guid.NewGuid().ToString("D"), calendarId, title, start, start.AddHours(1), zone, TaskId: taskId);
    }
    public void Validate(bool allowZeroDuration = false)
    {
        if (!Guid.TryParseExact(Id, "D", out _) || string.IsNullOrWhiteSpace(CalendarId) || string.IsNullOrWhiteSpace(Title)) throw new InvalidDataException("An event needs a title and calendar.");
        if (Title.Length > 4096 || Notes.Length > 262144 || Location.Length > 4096 || Alarms.Length > 32) throw new InvalidDataException("The event exceeds the local calendar limits.");
        _ = CalendarDates.TimeZone(Zone);
        if (AllDay)
        {
            if (StartDate is null || EndDateExclusive is null || EndDateExclusive <= StartDate) throw new InvalidDataException("Choose an inclusive last day on or after the first day.");
            if (Start != CalendarDates.Resolve(StartDate.Value.ToDateTime(TimeOnly.MinValue), Zone) || End != CalendarDates.Resolve(EndDateExclusive.Value.ToDateTime(TimeOnly.MinValue), Zone)) throw new InvalidDataException("All-day boundaries do not match their calendar dates.");
        }
        else if (End < Start || End == Start && !allowZeroDuration) throw new InvalidDataException("The end must be after the start.");
        foreach (var alarm in Alarms)
        {
            try { _ = alarm.Due(this); }
            catch (ArgumentOutOfRangeException) { throw new InvalidDataException("An alert date is outside the supported range."); }
        }
        if (Alarms.Any(a => string.IsNullOrWhiteSpace(a.Id) || (a.Absolute is null) == (a.OffsetMinutes is null) || a.OffsetMinutes is < -525600 or > 525600) || Alarms.Select(a => a.Id).Distinct().Count() != Alarms.Length) throw new InvalidDataException("Each alert needs either a relative offset or an absolute date.");
    }
}
public sealed record CalendarSnapshot(CalendarDefinition[] Calendars, CalendarEntry[] Events, string DefaultCalendarId)
{
    public static CalendarSnapshot Empty => new([new("local", "Takt on this device", true)], [], "local");
}
public sealed record CalendarMove(CalendarEntry Before, CalendarEntry After);
public sealed class CalendarConflictException(string message) : InvalidOperationException(message) { }

public static class CalendarDates
{
    public static TimeZoneInfo TimeZone(string id) => TimeZoneInfo.FindSystemTimeZoneById(id);
    internal static string? TryIanaZone(string id)
    {
        if (TimeZoneInfo.TryConvertWindowsIdToIanaId(id, out var iana)) return iana;
        return TimeZoneInfo.TryConvertIanaIdToWindowsId(id, out _) ? id : null;
    }
    // Keep wall-clock minutes through spring gaps, e.g. 02:30 becomes 03:30.
    // The earlier instant is deterministic when an autumn wall time occurs twice.
    public static DateTimeOffset Resolve(DateTime local, string zone)
    {
        var tz = TimeZone(zone); local = DateTime.SpecifyKind(local, DateTimeKind.Unspecified);
        if (tz.IsInvalidTime(local))
        {
            var before = local; var after = local;
            for (int i = 0; i < 1440 && tz.IsInvalidTime(before); ++i) before = before.AddMinutes(-1);
            for (int i = 0; i < 1440 && tz.IsInvalidTime(after); ++i) after = after.AddMinutes(1);
            if (tz.IsInvalidTime(before) || tz.IsInvalidTime(after)) throw new InvalidDataException("This local date does not exist in the selected time zone.");
            local = local.Add(tz.GetUtcOffset(after) - tz.GetUtcOffset(before));
            if (tz.IsInvalidTime(local)) throw new InvalidDataException("Choose a valid local time.");
        }
        var offset = tz.IsAmbiguousTime(local) ? tz.GetAmbiguousTimeOffsets(local).Max() : tz.GetUtcOffset(local);
        return new DateTimeOffset(local, offset);
    }
    public static DateOnly LocalDate(DateTimeOffset instant, string zone) => DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(instant, TimeZone(zone)).DateTime);
    public static bool OccursOn(CalendarEntry entry, DateOnly date, string zone)
    {
        if (entry.AllDay) return date >= entry.StartDate && date < entry.EndDateExclusive;
        var begin = Resolve(date.ToDateTime(TimeOnly.MinValue), zone);
        var end = Resolve(date.AddDays(1).ToDateTime(TimeOnly.MinValue), zone);
        return entry.Start < end && (entry.End > begin || entry.Start == entry.End && entry.Start >= begin);
    }
    public static DateOnly PeriodStart(DateOnly selected, CalendarAgendaMode mode, DayOfWeek firstDay) => mode == CalendarAgendaMode.Week ? selected.AddDays(-((7 + (int)selected.DayOfWeek - (int)firstDay) % 7)) : selected;
    public static CalendarEntry Move(CalendarEntry entry, DateOnly sourceDay, DateOnly targetDay, string displayZone)
    {
        if (!entry.CanEdit) throw new InvalidOperationException(entry.ReadOnlyReason);
        if (!OccursOn(entry, sourceDay, displayZone)) throw new CalendarConflictException("The event is no longer on the dragged day.");
        int days = targetDay.DayNumber - sourceDay.DayNumber;
        if (entry.AllDay)
        {
            var first = entry.StartDate!.Value.AddDays(days); var last = entry.EndDateExclusive!.Value.AddDays(days);
            return entry with { StartDate = first, EndDateExclusive = last, Start = Resolve(first.ToDateTime(TimeOnly.MinValue), entry.Zone), End = Resolve(last.ToDateTime(TimeOnly.MinValue), entry.Zone) };
        }
        var wall = TimeZoneInfo.ConvertTime(entry.Start, TimeZone(entry.Zone)).DateTime;
        var start = Resolve(wall.AddDays(days), entry.Zone);
        return entry with { Start = start, End = start.Add(entry.End - entry.Start) };
    }
    public static bool SameDates(CalendarEntry a, CalendarEntry b) => a.Start == b.Start && a.End == b.End && a.AllDay == b.AllDay && a.StartDate == b.StartDate && a.EndDateExclusive == b.EndDateExclusive && a.Zone == b.Zone;
    public static CalendarEntry Merge(CalendarEntry original, CalendarEntry edited, CalendarEntry current)
    {
        if (original.Id != edited.Id || original.Id != current.Id || original.TaskId != edited.TaskId || original.ReadOnly != edited.ReadOnly || original.Recurring != edited.Recurring) throw new InvalidDataException("Event identity cannot be changed.");
        if (!current.CanEdit) throw new InvalidOperationException(current.ReadOnlyReason);
        T Field<T>(T before, T desired, T latest)
        {
            if (EqualityComparer<T>.Default.Equals(before, desired)) return latest;
            if (!EqualityComparer<T>.Default.Equals(before, latest) && !EqualityComparer<T>.Default.Equals(desired, latest)) throw new CalendarConflictException("This event changed while it was open. Reopen it before applying the same field.");
            return desired;
        }
        bool changedDates = !SameDates(original, edited);
        if (changedDates && !SameDates(original, current) && !SameDates(edited, current)) throw new CalendarConflictException("The event's dates changed. Reopen it before rescheduling.");
        var merged = current with
        {
            Title = Field(original.Title, edited.Title, current.Title), CalendarId = Field(original.CalendarId, edited.CalendarId, current.CalendarId),
            Notes = Field(original.Notes, edited.Notes, current.Notes), Location = Field(original.Location, edited.Location, current.Location)
        };
        string beforeAlarms = JsonSerializer.Serialize(original.Alarms), editedAlarms = JsonSerializer.Serialize(edited.Alarms), currentAlarms = JsonSerializer.Serialize(current.Alarms);
        if (beforeAlarms != editedAlarms) { _ = Field(beforeAlarms, editedAlarms, currentAlarms); merged = merged with { Alerts = edited.Alarms }; }
        if (changedDates) merged = merged with { Start = edited.Start, End = edited.End, Zone = edited.Zone, AllDay = edited.AllDay, StartDate = edited.StartDate, EndDateExclusive = edited.EndDateExclusive };
        merged.Validate(); return merged;
    }
}

public sealed class CalendarQueryResult(IReadOnlyList<CalendarEntry> events, IReadOnlyList<string> warnings) : IReadOnlyList<CalendarEntry>
{
    public IReadOnlyList<string> Warnings { get; } = warnings;
    public int Count => events.Count;
    public CalendarEntry this[int index] => events[index];
    public IEnumerator<CalendarEntry> GetEnumerator() => events.GetEnumerator();
    System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();
}
