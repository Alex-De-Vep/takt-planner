using System.Text.Json;
using Takt.Core.Models;

namespace Takt.Core.Sync;

public static class SyncValidation
{
    private static void Require(bool condition) { if (!condition) throw new InvalidDataException("The server returned an inconsistent sync response."); }
    public static void Entity(Entity entity, long upper)
    {
        Require(Guid.TryParseExact(entity.Id, "D", out _) && entity.Id == entity.Id.ToLowerInvariant());
        Require(entity.Type is "task" or "folder" or "checklistItem" or "attachment");
        Require(entity.Fields is not null && entity.Versions is not null && Wire.Revision(entity.Revision) <= upper);
        foreach (var stamp in entity.Versions.Values)
            Require(stamp.PhysicalMillis >= 0 && stamp.LogicalCounter >= 0 && Guid.TryParseExact(stamp.DeviceId, "D", out _) && Guid.TryParseExact(stamp.OperationId, "D", out _));
    }
    public static void Snapshot(Snapshot snapshot, Profile profile)
    {
        Require(snapshot.ProtocolVersion == 1 && snapshot.LibraryId == profile.LibraryId && snapshot.Entities is not null);
        if (!snapshot.Initialized) throw new ApiException(409, "library_not_initialized");
        long cursor = Wire.Revision(snapshot.Cursor);
        Require(snapshot.Entities.Select(e => e.Id).Distinct(StringComparer.Ordinal).Count() == snapshot.Entities.Count);
        foreach (var e in snapshot.Entities) Entity(e, cursor);
    }
    public static void Page(ChangePage page, Profile profile, string cursor)
    {
        long previous = Wire.Revision(cursor), next = Wire.Revision(page.NextCursor);
        Require(page.LibraryId == profile.LibraryId && next >= previous && (!page.HasMore || next > previous) && page.Changes is not null);
        long revision = previous;
        foreach (var change in page.Changes)
        {
            long value = Wire.Revision(change.Revision);
            Require(value > revision && value <= next && change.Entity.Revision == change.Revision);
            Entity(change.Entity, next); revision = value;
        }
    }
    public static void Results(IReadOnlyList<Mutation> batch, IReadOnlyList<MutationResult> results)
    {
        Require(batch.Count == results.Count);
        for (int i = 0; i < batch.Count; ++i)
        {
            var result = results[i]; var sent = batch[i];
            Require(result.OperationId == sent.OperationId);
            if (result.Status == "rejected") Require(result.Error is not null);
            else
            {
                Require(result.Status is "applied" or "deleted");
                Require(result.Entity is not null && result.Entity.Id == sent.EntityId && result.Entity.Type == sent.EntityType);
                Entity(result.Entity!, long.MaxValue);
            }
        }
    }
    public static List<Mutation> Batch(IEnumerable<Mutation> queue, Capabilities? limits)
    {
        int max = Math.Clamp(limits?.MaxBatchOperations ?? 100, 1, 100);
        int bytes = Math.Clamp(limits?.MaxRequestBytes ?? 4194304, 1024, 4194304);
        List<Mutation> result = [];
        foreach (var mutation in queue.Take(max))
        {
            result.Add(mutation);
            if (JsonSerializer.SerializeToUtf8Bytes(new { mutations = result }, Wire.Json).Length <= bytes) continue;
            result.RemoveAt(result.Count - 1);
            if (result.Count == 0) throw new InvalidDataException("A queued edit exceeds the server request limit.");
            break;
        }
        return result;
    }
}
