using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Ical.Net.CalendarComponents;
using Ical.Net.DataTypes;
using Ical.Net.Evaluation;

namespace Takt.Core.Calendar;

public static class CalendarIcs
{
    public const int MaxBytes = 8 * 1024 * 1024;
    public const int MaxInstances = 20000;
    public static Ical.Net.Calendar Parse(string text)
    {
        if (Encoding.UTF8.GetByteCount(text) > MaxBytes) throw new InvalidDataException("Choose an ICS file smaller than 8 MiB.");
        try
        {
            var parsed = Ical.Net.Calendar.Load(text) ?? throw new InvalidDataException("No calendar was found in this file.");
            if (parsed.Events.Count > 10000 || parsed.Events.Any(e => e.DtStart is null)) throw new InvalidDataException("This calendar is too large or contains events without a start.");
            return parsed;
        }
        catch (Exception e) when (e is not InvalidDataException) { throw new InvalidDataException("The ICS calendar could not be read.", e); }
    }
    public static IReadOnlyList<CalendarEntry> Expand(CalendarDefinition definition, DateOnly first, DateOnly endExclusive, string displayZone)
    {
        var calendar = Parse(definition.SnapshotIcs ?? throw new InvalidDataException("The calendar snapshot is missing."));
        var from = CalendarDates.Resolve(first.ToDateTime(TimeOnly.MinValue), displayZone);
        var end = CalendarDates.Resolve(endExclusive.ToDateTime(TimeOnly.MinValue), displayZone);
        // Back up by the longest nominal event duration, including continuing multi-day events.
        // The margin covers offset/DST differences and floating/date-only timestamps.
        double durationDays = calendar.Events.Select(e => e.EffectiveDuration.ToTimeSpanUnspecified().TotalDays)
            .Concat(calendar.Events.SelectMany(e => e.RecurrenceDates.GetAllPeriods()).Select(p => p.EffectiveDuration?.ToTimeSpanUnspecified().TotalDays ?? 0)).DefaultIfEmpty(0).Max();
        if (!double.IsFinite(durationDays) || durationDays > 36600) throw new InvalidDataException("An ICS event duration exceeds the supported 100-year range.");
        var lookback = from.AddDays(-Math.Ceiling(Math.Max(0, durationDays)) - 2);
        var occurrences = calendar.GetOccurrences<CalendarEvent>(new CalDateTime(lookback.UtcDateTime, "UTC", true), new EvaluationOptions { MaxUnmatchedIncrementsLimit = 10000 });
        var result = new List<CalendarEntry>(); int examined = 0;
        try
        {
            foreach (var occurrence in occurrences)
            {
                if (++examined > MaxInstances) throw new InvalidDataException("This ICS period contains too many occurrences. Import a smaller calendar.");
                if (occurrence.Source is not CalendarEvent source || !source.IsActive) continue;
                var begin = occurrence.Period.StartTime; var finish = occurrence.Period.EffectiveEndTime ?? begin;
                // Calendar.GetOccurrences is ordered; use a two-day margin for floating values.
                if (begin.Value > end.UtcDateTime.AddDays(2)) break;
                bool allDay = !begin.HasTime;
                var startDate = allDay ? DateOnly.FromDateTime(begin.Value) : (DateOnly?)null;
                var endDate = allDay ? DateOnly.FromDateTime(finish.Value) : (DateOnly?)null;
                if (allDay && endDate <= startDate) endDate = startDate!.Value.AddDays(1);
                string zone = allDay || begin.IsFloating ? displayZone : begin.TzId ?? "UTC";
                DateTimeOffset Instant(CalDateTime value) => !value.HasTime || value.IsFloating ? CalendarDates.Resolve(value.Value, displayZone) : new DateTimeOffset(value.AsUtc);
                var start = Instant(begin); var stop = allDay ? CalendarDates.Resolve(endDate!.Value.ToDateTime(TimeOnly.MinValue), displayZone) : Instant(finish);
                string uid = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(source.Uid ?? "")))[..24];
                long identityTicks = allDay || begin.IsFloating ? DateTime.SpecifyKind(begin.Value, DateTimeKind.Utc).Ticks : start.UtcTicks;
                string id = $"ics|{definition.Id}|{uid}|{identityTicks.ToString(CultureInfo.InvariantCulture)}";
                bool recurring = source.RecurrenceIdentifier is not null || source.RecurrenceRule is not null || source.RecurrenceDates.GetAllDates().Any() || source.RecurrenceDates.GetAllPeriods().Any() || calendar.Events.Any(e => e.Uid == source.Uid && e.RecurrenceIdentifier is not null);
                var entry = new CalendarEntry(id, definition.Id, string.IsNullOrWhiteSpace(source.Summary) ? "Untitled event" : source.Summary, start, stop, zone,
                    allDay, startDate, endDate, source.Description ?? "", source.Location ?? "", ReadOnly: true, Recurring: recurring);
                if (allDay ? startDate < endExclusive && endDate > first : start < end && (stop > from || start == stop && start >= from)) result.Add(entry);
            }
        }
        catch (Exception e) when (e is not InvalidDataException) { throw new InvalidDataException("The calendar's recurrence or time zone could not be evaluated. The original snapshot has been retained.", e); }
        return result.OrderBy(e => e.Start).ThenBy(e => e.Id, StringComparer.Ordinal).ToList();
    }
    public static string Export(CalendarDefinition definition, IEnumerable<CalendarEntry> entries)
    {
        if (definition.SnapshotIcs is { } original) return original;
        var lines = new List<string> { "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Takt//Windows Local Calendar//EN", "CALSCALE:GREGORIAN", "X-WR-CALNAME:" + Escape(definition.Name) };
        static string Utc(DateTimeOffset value) => value.UtcDateTime.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
        foreach (var entry in entries.OrderBy(e => e.Start))
        {
            entry.Validate();
            lines.AddRange(["BEGIN:VEVENT", "UID:" + entry.Id + "@takt.local", "DTSTAMP:" + Utc(DateTimeOffset.UtcNow), "SUMMARY:" + Escape(entry.Title)]);
            if (entry.AllDay) lines.AddRange(["DTSTART;VALUE=DATE:" + entry.StartDate!.Value.ToString("yyyyMMdd", CultureInfo.InvariantCulture), "DTEND;VALUE=DATE:" + entry.EndDateExclusive!.Value.ToString("yyyyMMdd", CultureInfo.InvariantCulture)]);
            else lines.AddRange(["DTSTART:" + Utc(entry.Start), "DTEND:" + Utc(entry.End)]);
            if (entry.Notes.Length > 0) lines.Add("DESCRIPTION:" + Escape(entry.Notes));
            if (entry.Location.Length > 0) lines.Add("LOCATION:" + Escape(entry.Location));
            // Task IDs stay device-private; exporting an event never exports task identity.
            foreach (var alarm in entry.Alarms)
            {
                lines.AddRange(["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:" + Escape(entry.Title)]);
                lines.Add(alarm.Absolute is { } absolute ? "TRIGGER;VALUE=DATE-TIME:" + Utc(absolute) : "TRIGGER:" + (alarm.OffsetMinutes < 0 ? "-" : "") + "PT" + Math.Abs((long)alarm.OffsetMinutes!.Value).ToString(CultureInfo.InvariantCulture) + "M");
                lines.Add("END:VALARM");
            }
            lines.Add("END:VEVENT");
        }
        lines.Add("END:VCALENDAR");
        return string.Join("\r\n", lines.Select(Fold)) + "\r\n";
    }
    private static string Escape(string text) => text.Replace("\\", "\\\\").Replace("\r\n", "\n").Replace("\r", "\n").Replace("\n", "\\n").Replace(";", "\\;").Replace(",", "\\,");
    private static string Fold(string line)
    {
        var output = new StringBuilder(); int bytes = 0;
        foreach (var rune in line.EnumerateRunes())
        {
            int length = rune.Utf8SequenceLength;
            if (bytes + length > 75) { output.Append("\r\n "); bytes = 1; }
            output.Append(rune.ToString()); bytes += length;
        }
        return output.ToString();
    }
}
