using System.Security.Cryptography;
using System.Text.Json;
using Takt.Core.Models;

namespace Takt.Core.Storage;

public sealed partial class PlannerStore
{
    public static string TaskFingerprint(Entity task, IEnumerable<Entity> checklist)
    {
        var content = JsonSerializer.SerializeToElement(new
        {
            task.Id,
            Fields = task.Fields,
            Checklist = checklist.OrderBy(i => i.Number("sortOrder")).ThenBy(i => i.Id, StringComparer.Ordinal)
                .Select(i => new { i.Id, Fields = i.Fields }).ToArray()
        }, Wire.Json);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream)) WriteCanonical(writer, content);
        return Convert.ToHexString(SHA256.HashData(stream.ToArray()));
    }
    private static void WriteCanonical(Utf8JsonWriter writer, JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            writer.WriteStartObject();
            foreach (var property in value.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
            { writer.WritePropertyName(property.Name); WriteCanonical(writer, property.Value); }
            writer.WriteEndObject();
        }
        else if (value.ValueKind == JsonValueKind.Array)
        {
            writer.WriteStartArray(); foreach (var item in value.EnumerateArray()) WriteCanonical(writer, item); writer.WriteEndArray();
        }
        else value.WriteTo(writer);
    }

    // Compare and write under the same gate used by incoming sync. A proposal
    // cannot pass a check and then overwrite a newer edit in the gap before save.
    public Task EditTaskIfUnchangedAsync(string workspace, string id, string fingerprint,
        IReadOnlyList<Edit> edits, long clockOffset) => Locked(async () =>
    {
        if (edits.Count == 0 || edits.Any(e =>
            !(e.Type == "task" && e.Id == id && e.Kind == "update") &&
            !(e.Type == "checklistItem" && e.Kind == "create" && e.Fields is { } fields &&
                fields.TryGetValue("taskId", out var parent) && parent.ValueKind == JsonValueKind.String && parent.GetString() == id)))
            throw new InvalidDataException("A task proposal can only change its attached task and add its subtasks.");
        var current = await ReadCoreAsync();
        if (current.Workspace != workspace) throw new InvalidOperationException("The active library changed. Refresh the proposal context.");
        if (edits.Select(e => e.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != edits.Count ||
            edits.Where(e => e.Kind == "create").Any(e => current.Entities.Any(existing => string.Equals(existing.Id, e.Id, StringComparison.OrdinalIgnoreCase))))
            throw new InvalidDataException("A proposal cannot reuse an existing or duplicate subtask identifier.");
        var task = current.Tasks.FirstOrDefault(t => t.Id == id);
        if (task is null || TaskFingerprint(task, current.Items(id)) != fingerprint)
            throw new InvalidOperationException("The task changed after this proposal was prepared. Refresh the context and review the proposal again.");
        return await EditCoreAsync(workspace, edits, clockOffset);
    });
}
