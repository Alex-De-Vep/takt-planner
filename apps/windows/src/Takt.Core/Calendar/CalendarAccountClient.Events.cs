using System.Globalization;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Takt.Core.Calendar;

public sealed partial class CalendarAccountClient
{
    private static CalendarEntry? ParseEvent(JsonElement row, ConnectedCalendar calendar, string calendarId)
    {
        bool google = calendar.Kind == CalendarAccountKind.Google;
        string? id = Text(row, "id");
        if (!IsId(id) || (google ? Text(row, "status") == "cancelled" : Flag(row, "isCancelled"))) return null;
        var startField = Property(row, "start");
        var endField = Property(row, "end");
        string zone = SupportedZone(google ? Text(startField, "timeZone") ?? calendar.Calendar.Zone : Text(row, "originalStartTimeZone"));
        bool allDay = google ? Text(startField, "date") is not null : Flag(row, "isAllDay");
        DateOnly? first = null, last = null;
        DateTimeOffset start, end;
        if (allDay)
        {
            if (google)
            {
                if (!DateOnly.TryParseExact(Text(startField, "date"), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var begin) ||
                    !DateOnly.TryParseExact(Text(endField, "date"), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var finish))
                    return null;
                first = begin; last = finish;
            }
            else
            {
                if (!ReadTime(startField, "UTC", out var begin) || !ReadTime(endField, "UTC", out var finish)) return null;
                // Graph can return all-day boundaries as UTC midnight even for an event made in another zone.
                first = begin.TimeOfDay == TimeSpan.Zero ? DateOnly.FromDateTime(begin.DateTime) : CalendarDates.LocalDate(begin, zone);
                last = finish.TimeOfDay == TimeSpan.Zero ? DateOnly.FromDateTime(finish.DateTime) : CalendarDates.LocalDate(finish, zone);
            }
            if (last <= first) return null;
            start = CalendarDates.Resolve(first.Value.ToDateTime(TimeOnly.MinValue), zone);
            end = CalendarDates.Resolve(last.Value.ToDateTime(TimeOnly.MinValue), zone);
        }
        else if (!ReadTime(startField, google ? zone : "UTC", out start) || !ReadTime(endField, google ? zone : "UTC", out end) || end < start) return null;
        string? tag = Text(row, google ? "etag" : "@odata.etag");
        if (tag is not { Length: <= 256 } || !EntityTagHeaderValue.TryParse(tag, out var parsed) || parsed.Tag == "*") tag = null;
        var organizer = Property(row, "organizer");
        bool recurring = google ? Text(row, "recurringEventId") is not null || Property(row, "recurrence").ValueKind == JsonValueKind.Array :
            Text(row, "type") != "singleInstance";
        bool organizerCanEdit = google ? Flag(organizer, "self") && !Flag(row, "locked") &&
            (Text(row, "eventType") is null or "default") : Flag(row, "isOrganizer");
        var locations = Property(row, "locations");
        bool locationEditable = google || locations.ValueKind != JsonValueKind.Array || locations.GetArrayLength() <= 1;
        string? title = Text(row, google ? "summary" : "subject");
        string location = google ? Text(row, "location") ?? "" : Text(Property(row, "location"), "displayName") ?? "";
        string notes = Text(row, google ? "description" : "bodyPreview") ?? "";
        return new(StableId(calendarId, id!), calendarId, string.IsNullOrWhiteSpace(title) ? "(No title)" : Shorten(title, 4096),
            start, end, zone, allDay, first, last, Shorten(notes, 262144), Shorten(location, 4096),
            ReadOnly: !calendar.Calendar.Writable || !organizerCanEdit || tag is null, Recurring: recurring,
            Connected: new(id!, tag, locationEditable));
    }

    private static bool ReadTime(JsonElement field, string fallbackZone, out DateTimeOffset value)
    {
        string? raw = Text(field, "dateTime");
        if (DateTime.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var wall) &&
            wall.Kind == DateTimeKind.Unspecified)
        {
            value = CalendarDates.Resolve(wall, SupportedZone(Text(field, "timeZone") ?? fallbackZone));
            return true;
        }
        return DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out value);
    }

    private static string SupportedZone(string? id)
    {
        if (id is null or { Length: > 128 }) return "UTC";
        try { return CalendarDates.TimeZone(id).Id; }
        catch (Exception error) when (error is TimeZoneNotFoundException or InvalidTimeZoneException) { return "UTC"; }
    }

    private static string StableId(string calendar, string id) =>
        new Guid(SHA256.HashData(Encoding.UTF8.GetBytes(calendar + ":" + id)).AsSpan(0, 16)).ToString("D");

    private static Dictionary<string, object?> Fields(CalendarAccountKind kind, CalendarEntry draft, CalendarEntry? original)
    {
        bool google = kind == CalendarAccountKind.Google;
        var fields = new Dictionary<string, object?>();
        if (original is null || draft.Title != original.Title) fields[google ? "summary" : "subject"] = draft.Title;
        if (original is null || !CalendarDates.SameDates(draft, original))
        {
            fields["start"] = DateValue(draft.Start, draft.StartDate);
            fields["end"] = DateValue(draft.End, draft.EndDateExclusive);
            if (!google) fields["isAllDay"] = draft.AllDay;
        }
        if (original is null || draft.Location != original.Location)
        {
            if (original?.Connected is { CanEditLocation: false })
                throw new InvalidOperationException("Use Outlook to change this event's multiple locations.");
            fields["location"] = google ? draft.Location : new { displayName = draft.Location };
        }
        if ((original is null && draft.Notes.Length > 0) || (google && original is not null && draft.Notes != original.Notes))
            fields[google ? "description" : "body"] = google ? draft.Notes : new { contentType = "text", content = draft.Notes };
        return fields;

        object DateValue(DateTimeOffset value, DateOnly? date)
        {
            if (google)
            {
                if (date is { } wholeDay) return new { date = wholeDay.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) };
                string? iana = CalendarDates.TryIanaZone(draft.Zone);
                return iana is null ? new { dateTime = value.ToString("O") } :
                    (object)new { dateTime = value.ToString("O"), timeZone = iana };
            }
            var zone = CalendarDates.TimeZone(draft.Zone);
            string graphZone = TimeZoneInfo.TryConvertIanaIdToWindowsId(zone.Id, out var windows) ? windows : zone.Id;
            if (date is { } whole)
                return new { dateTime = whole.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) + "T00:00:00", timeZone = graphZone };
            var wall = TimeZoneInfo.ConvertTime(value, zone).DateTime;
            // UTC preserves the chosen instant when a local wall time occurs twice.
            if (zone.IsAmbiguousTime(wall)) { wall = value.UtcDateTime; graphZone = "UTC"; }
            return new { dateTime = wall.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff", CultureInfo.InvariantCulture), timeZone = graphZone };
        }
    }
}
