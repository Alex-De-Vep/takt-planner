using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Takt.Core.Models;

public sealed record Deadline(string TimeZoneId, bool IncludesTime, string? Date = null, string? Instant = null)
{
    public static Deadline FromLocal(DateOnly date, TimeOnly? time, TimeZoneInfo zone)
    {
        string iana = zone.Id == "UTC" || zone.HasIanaId ? zone.Id : TimeZoneInfo.TryConvertWindowsIdToIanaId(zone.Id, out var id)
            ? id : throw new ArgumentException("This time zone cannot be synchronized.");
        if (time is null) return new(iana, false, date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
        var local = date.ToDateTime(time.Value, DateTimeKind.Unspecified);
        if (zone.IsInvalidTime(local)) throw new ArgumentException("This time does not exist because the clock moves forward.");
        // A repeated DST time would otherwise silently pick one of two instants.
        if (zone.IsAmbiguousTime(local)) throw new ArgumentException("This time occurs twice. Choose a time outside the daylight-saving transition.");
        return new(iana, true, Instant: Wire.Time(new DateTimeOffset(TimeZoneInfo.ConvertTimeToUtc(local, zone))));
    }
    public (DateOnly Date, TimeOnly? Time) LocalParts()
    {
        if (!IncludesTime) return (DateOnly.ParseExact(Date!, "yyyy-MM-dd", CultureInfo.InvariantCulture), null);
        var zone = TimeZoneInfo.FindSystemTimeZoneById(TimeZoneId);
        var local = TimeZoneInfo.ConvertTime(DateTimeOffset.Parse(Instant!, CultureInfo.InvariantCulture), zone);
        return (DateOnly.FromDateTime(local.DateTime), TimeOnly.FromDateTime(local.DateTime));
    }
}

public static class TaskRules
{
    public static void Text(string text, int bytes, bool required = false)
    {
        if ((required && string.IsNullOrWhiteSpace(text)) || text.Contains('\0') || Encoding.UTF8.GetByteCount(text) > bytes)
            throw new ArgumentException("The text is empty or exceeds the supported size.");
    }
    public static void Validate(Edit edit)
    {
        if (!Guid.TryParseExact(edit.Id, "D", out _) || edit.Type is not ("task" or "folder" or "checklistItem" or "attachment") || edit.Kind is not ("create" or "update" or "delete"))
            throw new ArgumentException("Invalid task operation.");
        if (edit.Kind == "delete") return;
        var fields = edit.Fields ?? throw new ArgumentException("The edit has no fields.");
        string[] allowed = edit.Type switch
        {
            "task" => ["title", "description", "createdAt", "completedAt", "focusDay", "placement", "deadline", "planning"],
            "folder" => ["name", "sortOrder"],
            "checklistItem" => ["taskId", "title", "isCompleted", "sortOrder"],
            _ => throw new ArgumentException("Attachment uploads are not part of this client yet.")
        };
        if (fields.Count == 0 || fields.Keys.Any(k => !allowed.Contains(k)) ||
            (edit.Kind == "update" && (fields.ContainsKey("createdAt") || fields.ContainsKey("taskId"))))
            throw new ArgumentException("Unsupported task fields.");
        if (edit.Kind == "create")
        {
            string[] required = edit.Type switch { "task" => ["title", "createdAt", "placement"], "folder" => ["name", "sortOrder"], _ => ["taskId", "title", "isCompleted", "sortOrder"] };
            if (required.Any(k => !fields.ContainsKey(k))) throw new ArgumentException("The task backup is missing required fields.");
        }
        foreach (var (key, value) in fields)
        {
            bool nullable = value.ValueKind == JsonValueKind.Null;
            switch (key)
            {
                case "title": case "description": case "name":
                    if (value.ValueKind != JsonValueKind.String) throw new ArgumentException("Invalid task text.");
                    string text = value.GetString()!; Text(text, key == "description" ? 1048576 : key == "name" ? 320 : 16384, key == "name");
                    if (key == "name" && text.EnumerateRunes().Count() > 80) throw new ArgumentException("Use at most 80 characters for a folder name.");
                    break;
                case "sortOrder":
                    if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out int order) || order < 0) throw new ArgumentException("Invalid item order.");
                    break;
                case "isCompleted":
                    if (value.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw new ArgumentException("Invalid completion state.");
                    break;
                case "taskId":
                    if (value.ValueKind != JsonValueKind.String || !Guid.TryParseExact(value.GetString(), "D", out _)) throw new ArgumentException("Invalid parent task.");
                    break;
                case "createdAt": case "completedAt":
                    if (key == "completedAt" && nullable) break;
                    ValidateTime(value.GetString()); break;
                case "focusDay":
                    if (!nullable && !DateOnly.TryParseExact(value.GetString(), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out _)) throw new ArgumentException("Invalid focus date.");
                    break;
                case "placement":
                    if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty("kind", out var kind)) throw new ArgumentException("Invalid folder.");
                    string destination = kind.GetString()!;
                    if (destination == "folder") destination = value.GetProperty("folderId").GetString()!;
                    if (Placement(destination).GetRawText() != value.GetRawText())
                    {
                        var expected = Placement(destination);
                        if (expected.EnumerateObject().Count() != value.EnumerateObject().Count() || expected.EnumerateObject().Any(p => !value.TryGetProperty(p.Name, out var actual) || p.Value.GetString() != actual.GetString()))
                            throw new ArgumentException("Invalid folder fields.");
                    }
                    break;
                case "deadline":
                    if (nullable) break;
                    var deadline = JsonSerializer.Deserialize<Deadline>(value, Wire.Json) ?? throw new ArgumentException("Invalid deadline.");
                    var zone = TimeZoneInfo.FindSystemTimeZoneById(deadline.TimeZoneId);
                    if (!zone.HasIanaId && deadline.TimeZoneId != "UTC") throw new ArgumentException("Use an IANA time zone.");
                    string[] names = deadline.IncludesTime ? ["instant", "timeZoneId", "includesTime"] : ["date", "timeZoneId", "includesTime"];
                    if (value.EnumerateObject().Count() != 3 || value.EnumerateObject().Any(p => !names.Contains(p.Name))) throw new ArgumentException("Invalid deadline fields.");
                    if (deadline.IncludesTime) ValidateTime(deadline.Instant);
                    else if (!DateOnly.TryParseExact(deadline.Date, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out _)) throw new ArgumentException("Invalid deadline date.");
                    break;
                case "planning":
                    if (nullable) break;
                    if (value.ValueKind != JsonValueKind.Object || value.EnumerateObject().Count() != 2 || value.GetProperty("kind").GetString() is not ("week" or "month")) throw new ArgumentException("Invalid planning field.");
                    ValidateTime(value.GetProperty("anchor").GetString()); break;
            }
        }
    }
    private static void ValidateTime(string? time)
    {
        if (time is null || !System.Text.RegularExpressions.Regex.IsMatch(time, @"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,3})?Z$") ||
            !DateTimeOffset.TryParse(time, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out _)) throw new ArgumentException("Invalid UTC timestamp.");
    }
    public static JsonElement Placement(string section) => section switch
    {
        "today" or "all" or "inbox" => Wire.Value(new { kind = "inbox" }),
        "week" or "month" => Wire.Value(new { kind = section }),
        _ when Guid.TryParseExact(section, "D", out _) => Wire.Value(new { kind = "folder", folderId = section }),
        _ => throw new ArgumentException("Choose an existing folder.")
    };
    public static Edit CreateTask(string title, string section)
    {
        Text(title, 16384, true);
        return new(Wire.Id(), "task", "create", new()
        {
            ["title"] = Wire.Value(title.Trim()), ["description"] = Wire.Value(""), ["createdAt"] = Wire.Value(Wire.Time()),
            ["placement"] = Placement(section), ["focusDay"] = section == "today" ? Wire.Value("9999-12-31") : Wire.Null,
            ["completedAt"] = Wire.Null, ["deadline"] = Wire.Null
        });
    }
    public static Edit CreateFolder(string name, int sortOrder)
    {
        name = name.Trim(); Text(name, 320, true);
        if (name.EnumerateRunes().Count() > 80) throw new ArgumentException("Use at most 80 characters for a folder name.");
        return new(Wire.Id(), "folder", "create", new() { ["name"] = Wire.Value(name), ["sortOrder"] = Wire.Value(sortOrder) });
    }
    public static Edit CreateItem(string taskId, string title, int order)
    {
        Text(title, 16384, true);
        return new(Wire.Id(), "checklistItem", "create", new()
        { ["taskId"] = Wire.Value(taskId), ["title"] = Wire.Value(title.Trim()), ["isCompleted"] = Wire.Value(false), ["sortOrder"] = Wire.Value(order) });
    }
    public static Edit Update(Entity entity, string key, JsonElement value) => new(entity.Id, entity.Type, "update", new() { [key] = value });
    public static List<Edit> DeleteTask(Library library, Entity task) => library.Live
        .Where(e => (e.Type is "checklistItem" or "attachment") && e.Text("taskId") == task.Id)
        .Select(e => new Edit(e.Id, e.Type, "delete")).Append(new Edit(task.Id, "task", "delete")).ToList();
    // Rehome tasks first: no orphaned tasks and no implicit movement to Today.
    public static List<Edit> DeleteFolder(Library library, Entity folder) => library.Tasks.Where(t => t.Placement == folder.Id)
        .Select(t => Update(t, "placement", Placement("inbox"))).Append(new Edit(folder.Id, "folder", "delete")).ToList();
    public static IEnumerable<Edit> Move(Library library, IEnumerable<string> ids, string destination) => ids.Distinct()
        .Select(id => library.Tasks.Single(t => t.Id == id)).Select(task => destination == "today"
            ? Update(task, "focusDay", Wire.Value("9999-12-31")) : Update(task, "placement", Placement(destination)));
}
