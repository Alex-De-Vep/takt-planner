using System.Text.Json;
using Takt.Core.Models;

namespace Takt.Core.Notes;

public sealed record NoteBackup(int FormatVersion, string CreatedAt, List<NoteDocument> Notes)
{
    public const int MaxBytes = 64 * 1024 * 1024;
    public static string Export(NotesState state)
    {
        var notes = state.Notes.Where(n => !n.Document.IsPurged && !n.Document.Expired(NoteDocument.Now)).Select(n => n.Document).ToList();
        foreach (var note in notes) NoteCodec.Validate(note);
        string json = JsonSerializer.Serialize(new NoteBackup(1, Wire.Time(), notes), Wire.Json);
        if (System.Text.Encoding.UTF8.GetByteCount(json) > MaxBytes) throw new InvalidDataException("Note backup exceeds 64 MiB.");
        return json;
    }
    public static List<NoteDocument> Import(string json, Library library)
    {
        if (library.Profile is not null) throw new InvalidOperationException("Import a note backup into the local library first.");
        if (System.Text.Encoding.UTF8.GetByteCount(json) > MaxBytes) throw new InvalidDataException("Note backup exceeds 64 MiB.");
        NoteBackup backup;
        try { backup = JsonSerializer.Deserialize<NoteBackup>(json, Wire.Json) ?? throw new InvalidDataException("Invalid note backup."); }
        catch (JsonException error) { throw new InvalidDataException("Invalid note backup.", error); }
        if (backup.FormatVersion != 1 || backup.Notes is null || backup.Notes.Count > 10000 || backup.Notes.Any(n => n is null) || backup.Notes.Select(n => n.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != backup.Notes.Count)
            throw new InvalidDataException("Invalid note backup version or identifiers.");
        List<NoteDocument> notes = [];
        foreach (var original in backup.Notes)
        {
            NoteCodec.Validate(original); if (original.IsPurged || original.Expired(NoteDocument.Now)) continue;
            string folder = original.FolderId() is { } id && library.Folders.Any(f => f.Id == id) ? NoteDocument.FolderKey(id) : "inbox";
            notes.Add(original with { Folder = folder });
        }
        return notes;
    }
}
