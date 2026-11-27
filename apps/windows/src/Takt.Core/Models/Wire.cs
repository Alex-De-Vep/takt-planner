using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Takt.Core.Models;

public static class Wire
{
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };
    public static JsonElement Value<T>(T value) => JsonSerializer.SerializeToElement(value, Json);
    public static JsonElement Null => Value<string?>(null);
    public static string Id() => Guid.NewGuid().ToString("D");
    // The protocol accepts UTC timestamps with at most three fractional digits.
    public static string Time(DateTimeOffset? value = null) => (value ?? DateTimeOffset.UtcNow)
        .UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
    public static long Revision(string text) => long.TryParse(text, NumberStyles.None,
        CultureInfo.InvariantCulture, out var result) && result >= 0 ? result : throw new InvalidDataException("Invalid revision.");
}

public sealed record Stamp(long PhysicalMillis, int LogicalCounter, string DeviceId, string OperationId) : IComparable<Stamp>
{
    public int CompareTo(Stamp? other)
    {
        if (other is null) return 1;
        int n = PhysicalMillis.CompareTo(other.PhysicalMillis);
        if (n != 0) return n;
        n = LogicalCounter.CompareTo(other.LogicalCounter);
        if (n != 0) return n;
        n = StringComparer.Ordinal.Compare(DeviceId, other.DeviceId);
        return n != 0 ? n : StringComparer.Ordinal.Compare(OperationId, other.OperationId);
    }
}

public sealed record Entity(string Id, string Type, Dictionary<string, JsonElement> Fields,
    Dictionary<string, Stamp> Versions, bool Deleted = false, string Revision = "0", bool? FileReady = null)
{
    public string? Text(string key) => Fields.TryGetValue(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    public bool Flag(string key) => Fields.TryGetValue(key, out var value) && value.ValueKind == JsonValueKind.True;
    public int Number(string key) => Fields.TryGetValue(key, out var value) && value.TryGetInt32(out int n) ? n : 0;
    [JsonIgnore] public bool Completed => Text("completedAt") is not null;
    public bool Focused(DateOnly today) => Text("focusDay") is "9999-12-31" || Text("focusDay") == today.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    [JsonIgnore] public string Placement => Fields.TryGetValue("placement", out var value) && value.ValueKind == JsonValueKind.Object
        ? (value.TryGetProperty("folderId", out var folder) ? folder.GetString() : value.GetProperty("kind").GetString()) ?? "inbox" : "inbox";
    [JsonIgnore] public Deadline? Deadline => Fields.TryGetValue("deadline", out var value) && value.ValueKind == JsonValueKind.Object
        ? JsonSerializer.Deserialize<Deadline>(value, Wire.Json) : null;
}

public sealed record FieldChange(JsonElement Value, Stamp Version);
public sealed record Mutation(string OperationId, string LibraryId, string DeviceId, string EntityId,
    string EntityType, string Kind, Dictionary<string, FieldChange>? Changes = null, Stamp? DeleteVersion = null)
{
    public Entity? Overlay(Entity? original)
    {
        if (original?.Deleted == true || (original is null && Kind == "update")) return original;
        var entity = original ?? new Entity(EntityId, EntityType, [], []);
        if (Kind == "delete") return entity with { Deleted = true };
        var fields = new Dictionary<string, JsonElement>(entity.Fields);
        var versions = new Dictionary<string, Stamp>(entity.Versions);
        foreach (var (key, field) in Changes ?? [])
            if (!versions.TryGetValue(key, out var old) || field.Version.CompareTo(old) > 0)
            {
                fields[key] = field.Value.Clone();
                versions[key] = field.Version;
            }
        return entity with { Fields = fields, Versions = versions };
    }
}

public sealed record Edit(string Id, string Type, string Kind, Dictionary<string, JsonElement>? Fields = null);
public sealed record Profile(string Origin, string Email, string LibraryId)
{
    [JsonIgnore] public string Workspace => Origin + "|" + LibraryId;
}
public sealed record Connection(Profile Profile, string? Credential, string? RefreshOperationId = null, bool LegacyRefreshPending = false);
public sealed record Snapshot(int ProtocolVersion, string LibraryId, string Cursor, bool Initialized, List<Entity> Entities);
public sealed record Change(string Revision, Entity Entity);
public sealed record ChangePage(string LibraryId, List<Change> Changes, string NextCursor, bool HasMore);
public sealed record Problem(string Code, long? RetryAfterSeconds = null);
public sealed record MutationResult(string? OperationId, string Status, Entity? Entity, Problem? Error);
public sealed record MutationResults(List<MutationResult> Results);
public sealed record Config(int ProtocolVersion, DateTimeOffset ServerTime, Capabilities? Limits);
public sealed record Capabilities(int MaxBatchOperations = 100, int MaxRequestBytes = 4194304, int? RefreshOperationVersion = null, int? MaxNoteBytes = null, int? MaxNoteFormatVersion = null, int? NoteEventsVersion = null, int? TaskEventsVersion = null);
public sealed record Tokens(string AccessToken, string RefreshToken, int ExpiresIn);
public sealed record Account(string Email, string LibraryId);
public sealed record Queued(Mutation Mutation, string? Error);
public sealed record Library(string Workspace, Profile? Profile, List<Entity> Entities, List<Queued> Queue)
{
    public static Library Empty => new("local", null, [], []);
    public IEnumerable<Entity> Live => Entities.Where(e => !e.Deleted);
    public IEnumerable<Entity> Folders => Live.Where(e => e.Type == "folder").OrderBy(e => e.Number("sortOrder")).ThenBy(e => e.Id, StringComparer.Ordinal);
    public IEnumerable<Entity> Tasks => Live.Where(e => e.Type == "task").OrderByDescending(e => e.Text("createdAt"), StringComparer.Ordinal);
    public IEnumerable<Entity> Items(string taskId) => Live.Where(e => e.Type == "checklistItem" && e.Text("taskId") == taskId)
        .OrderBy(e => e.Number("sortOrder")).ThenBy(e => e.Id, StringComparer.Ordinal);
    public string Location(Entity task) => task.Placement is "inbox" or "week" or "month" || Folders.Any(f => f.Id == task.Placement) ? task.Placement : "inbox";
    public IEnumerable<Entity> InSection(string section, string search, DateOnly today) => Tasks.Where(task =>
        (section == "all" || (section == "today" ? task.Focused(today) : Location(task) == section)) &&
        (task.Text("title")?.Contains(search, StringComparison.CurrentCultureIgnoreCase) == true ||
         task.Text("description")?.Contains(search, StringComparison.CurrentCultureIgnoreCase) == true || search.Length == 0));
}
