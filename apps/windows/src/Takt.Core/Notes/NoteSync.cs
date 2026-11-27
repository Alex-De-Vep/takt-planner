using System.Text.Json;
using System.Text.Json.Serialization;
using Takt.Core.Models;
using Takt.Core.Sync;

namespace Takt.Core.Notes;

public sealed record NoteIndexEntry([property: JsonRequired] string Id, [property: JsonRequired] string Revision);
public sealed record NoteIndex([property: JsonRequired] List<NoteIndexEntry> Notes);
public sealed record NoteDownload([property: JsonRequired] string Revision, [property: JsonRequired] string Data);
public sealed record NoteReceipt([property: JsonRequired] string Revision);

public sealed class NoteSync(NoteStore store)
{
    public delegate Task<T> Request<T>(string path, object? body, CancellationToken cancellation);
    public async Task SynchronizeAsync(string workspace, int? serverLimit, int formatVersion,
        Func<string, object?, CancellationToken, Task<JsonElement>> request, CancellationToken ct = default)
    {
        int limit = Math.Clamp(serverLimit ?? 0, 0, NoteCodec.MaxBytes);
        await store.ConfigureAsync(workspace, limit, formatVersion); await store.PurgeExpiredAsync(workspace, NoteDocument.Now);
        if (limit == 0) { await store.ErrorAsync(workspace, "This server does not support notes. Local notes have been kept."); return; }
        if (formatVersion < 1) { await store.ErrorAsync(workspace, "The server must support shared note format version 1."); return; }
        var index = Decode<NoteIndex>(await request("/v1/notes", null, ct));
        if (index.Notes is null || index.Notes.Count > 10000) throw new InvalidDataException("Invalid note index.");
        Dictionary<string, string> remote = [];
        foreach (var entry in index.Notes)
        {
            if (entry is null || !Guid.TryParseExact(entry.Id, "D", out var id) || !Revision(entry.Revision) || !remote.TryAdd(id.ToString("D"), entry.Revision)) throw new InvalidDataException("Invalid note index identifiers or revisions.");
        }
        var known = await store.RevisionsAsync(workspace); List<string> errors = [];
        foreach (var (id, revision) in remote.ToArray())
        {
            ct.ThrowIfCancellationRequested(); if (known.GetValueOrDefault(id) == revision) continue;
            try
            {
                var downloaded = Decode<NoteDownload>(await request("/v1/notes/" + id, null, ct));
                if (!Revision(downloaded.Revision) || downloaded.Data is null || downloaded.Data.Length > (limit + 2) / 3 * 4) throw new InvalidDataException("Invalid downloaded note size.");
                var bytes = Convert.FromBase64String(downloaded.Data);
                if (Convert.ToBase64String(bytes) != downloaded.Data) throw new InvalidDataException("Invalid downloaded note encoding.");
                if (bytes.Length == 0 || bytes.Length > limit) throw new InvalidDataException("Invalid downloaded note size.");
                await store.ReceiveAsync(workspace, id, downloaded.Revision, bytes); remote[id] = downloaded.Revision;
            }
            catch (Exception e) when (e is InvalidDataException or JsonException or FormatException)
            { errors.Add("One note could not be read. Its local content has not been replaced."); }
        }
        foreach (var pending in await store.PendingAsync(workspace))
        {
            ct.ThrowIfCancellationRequested();
            var document = NoteCodec.Decode(pending.Bytes, pending.Id);
            if (pending.Bytes.Length > limit) { errors.Add("A note exceeds the server size limit."); continue; }
            if (document.RichText is not null && formatVersion < 1) { errors.Add("Update the server to sync formatted notes."); continue; }
            // Use the revision held by this document. Failed downloads must never
            // authorize overwriting a newer server note from the index alone.
            var body = new Dictionary<string, JsonElement> { ["baseRevision"] = pending.Revision is null ? Wire.Null : Wire.Value(pending.Revision), ["data"] = Wire.Value(Convert.ToBase64String(pending.Bytes)) };
            try
            {
                var receipt = Decode<NoteReceipt>(await request("/v1/notes/" + pending.Id, body, ct));
                if (receipt.Revision != pending.Digest) throw new InvalidDataException("Invalid note upload receipt.");
                await store.AcknowledgeAsync(workspace, pending);
            }
            catch (ApiException e) when (e.Code == "note_conflict") { errors.Add("A note changed elsewhere. Both versions will be kept on the next sync."); }
            catch (ApiException e) when (e.Code is "note_quota" or "note_format_requires_update" || e.Status == 413)
            { errors.Add(e.Code == "note_quota" ? "Cloud space for notes is full." : "A note cannot be uploaded in this format or size."); }
        }
        await store.ErrorAsync(workspace, errors.Count == 0 ? null : string.Join(" ", errors.Distinct()));
    }
    public static bool Revision(string? value) => value is { Length: 64 } && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
    private static T Decode<T>(JsonElement data) => data.Deserialize<T>(Wire.Json) ?? throw new InvalidDataException("Invalid note response.");
}
