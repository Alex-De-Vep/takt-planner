using System.Text.Json;
using Takt.Core.Models;

namespace Takt.Core.Storage;

public sealed record TaskBackup(int FormatVersion, string CreatedAt, List<Entity> Entities)
{
    public static string Export(Library library) => JsonSerializer.Serialize(new TaskBackup(1, Wire.Time(), library.Live
        .Where(e => e.Type is "task" or "folder" or "checklistItem").ToList()), new JsonSerializerOptions(Wire.Json) { WriteIndented = true });
    public static List<Edit> Import(string json, Library library)
    {
        if (library.Profile is not null) throw new InvalidOperationException("Switch to the local library before importing a task backup.");
        if (System.Text.Encoding.UTF8.GetByteCount(json) > 32 * 1024 * 1024) throw new InvalidDataException("Backup is too large.");
        var backup = JsonSerializer.Deserialize<TaskBackup>(json, Wire.Json) ?? throw new InvalidDataException("Invalid backup.");
        return Plan(backup, preserveIds: false);
    }

    public static List<Edit> Plan(TaskBackup backup, bool preserveIds)
    {
        if (backup.FormatVersion != 1 || backup.Entities is null || backup.Entities.Count > 100000 || backup.Entities.Any(e => e is null || e.Fields is null || !Guid.TryParseExact(e.Id, "D", out _) || e.Deleted || e.Type is not ("task" or "folder" or "checklistItem")))
            throw new InvalidDataException("Unsupported task backup.");
        if (backup.Entities.Select(e => e.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != backup.Entities.Count) throw new InvalidDataException("Duplicate task identifiers.");
        var entities = backup.Entities.ToDictionary(e => e.Id);
        var ids = backup.Entities.ToDictionary(e => e.Id, e => preserveIds ? e.Id : Wire.Id());
        List<Edit> edits = [];
        foreach (var e in backup.Entities.OrderBy(e => e.Type switch { "folder" => 0, "task" => 1, _ => 2 }))
        {
            var fields = new Dictionary<string, JsonElement>(e.Fields);
            if (e.Type == "folder") TaskRules.CreateFolder(e.Text("name") ?? "", e.Number("sortOrder"));
            else TaskRules.Text(e.Text("title") ?? "", 16384);
            if (e.Type == "task")
            {
                TaskRules.Text(e.Text("description") ?? "", 1048576);
                string placement = e.Placement;
                fields["placement"] = TaskRules.Placement(entities.TryGetValue(placement, out var folder) && folder.Type == "folder"
                    ? ids[placement] : placement is "inbox" or "week" or "month" ? placement : "inbox");
            }
            if (e.Type == "checklistItem")
            {
                if (!ids.TryGetValue(e.Text("taskId") ?? "", out var parent) || !entities.TryGetValue(e.Text("taskId") ?? "", out var task) || task.Type != "task")
                    throw new InvalidDataException("A checklist item has no task.");
                fields["taskId"] = Wire.Value(parent);
            }
            var edit = new Edit(ids[e.Id], e.Type, "create", fields);
            TaskRules.Validate(edit);
            edits.Add(edit);
        }
        return edits;
    }
}
