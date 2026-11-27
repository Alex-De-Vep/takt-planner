using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Takt.Core.Models;

namespace Takt.Core.Notes;

public sealed record NoteSpan([property: JsonRequired] int Start, [property: JsonRequired] int End, bool? Bold = null, bool? Italic = null, bool? Underline = null,
    int? Size = null, string? Link = null, string? Image = null)
{
    [JsonIgnore] public bool Styled => Bold == true || Italic == true || Underline == true || Size is not null || Link is not null || Image is not null;
}
public sealed record SharedNoteText([property: JsonRequired] int Version, [property: JsonRequired] List<NoteSpan> Spans)
{
    public const int CurrentVersion = 1;
    public const int ImageLimit = 2 * 1024 * 1024;
    public static SharedNoteText Empty => new(CurrentVersion, []);
    public void Validate(string text)
    {
        if (text is null || Version != CurrentVersion || Spans is null || Spans.Count > 4096) throw new InvalidDataException("Unsupported note formatting.");
        bool Boundary(int at) => at == text.Length || !char.IsLowSurrogate(text[at]);
        int previous = 0; HashSet<int> images = [];
        foreach (var span in Spans)
        {
            if (span is null) throw new InvalidDataException("Invalid note formatting range.");
            if (span.Start < previous || span.End <= span.Start || span.End > text.Length || !Boundary(span.Start) || !Boundary(span.End) ||
                span.Size is < 8 or > 72 || (span.Link is not null && !ValidLink(span.Link))) throw new InvalidDataException("Invalid note formatting ranges.");
            if (span.Image is { } image)
            {
                if (span.End - span.Start != 1 || text[span.Start] != '\uFFFC' || image.Length > (ImageLimit + 2) / 3 * 4)
                    throw new InvalidDataException("Invalid inline image.");
                byte[] data;
                try { data = Convert.FromBase64String(image); }
                catch (FormatException error) { throw new InvalidDataException("Invalid inline image encoding.", error); }
                if (Convert.ToBase64String(data) != image) throw new InvalidDataException("Inline images must use canonical base64 encoding.");
                ValidatePng(data); images.Add(span.Start);
            }
            previous = span.End;
        }
        for (int i = 0; i < text.Length; ++i)
            if (text[i] == '\uFFFC' && !images.Contains(i)) throw new InvalidDataException("An inline image has no saved data.");
        ValidateUnicode(text);
    }
    public static void ValidateUnicode(string text)
    {
        if (text is null) throw new InvalidDataException("Missing note text.");
        for (int i = 0; i < text.Length; ++i)
            if (char.IsHighSurrogate(text[i]) && (i + 1 >= text.Length || !char.IsLowSurrogate(text[i + 1])) ||
                char.IsLowSurrogate(text[i]) && (i == 0 || !char.IsHighSurrogate(text[i - 1]))) throw new InvalidDataException("Invalid Unicode note text.");
    }
    public static bool ValidLink(string link) => Encoding.UTF8.GetByteCount(link) <= 2048 && !link.Any(c => char.IsControl(c) || char.IsWhiteSpace(c) || c is '\"' or '\\' or '<' or '>') &&
        Uri.TryCreate(link, UriKind.Absolute, out var uri) && (uri.Scheme is "http" or "https" && uri.Host.Length > 0 || uri.Scheme == "mailto" && uri.AbsolutePath.Length > 0);
    public static (int Width, int Height) ValidatePng(byte[] data)
    {
        byte[] signature = [137, 80, 78, 71, 13, 10, 26, 10];
        if (data.Length < 24 || data.Length > ImageLimit || !data.AsSpan(0, 8).SequenceEqual(signature) ||
            !data.AsSpan(12, 4).SequenceEqual("IHDR"u8)) throw new InvalidDataException("Use a PNG image of at most 2 MiB.");
        uint width = BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(16, 4)), height = BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(20, 4));
        if (width is < 1 or > 2500 || height is < 1 or > 2500) throw new InvalidDataException("Images must be at most 2500 × 2500 pixels.");
        return ((int)width, (int)height);
    }
}

public sealed record NoteDocument([property: JsonRequired] string Id, [property: JsonRequired] string Folder,
    [property: JsonRequired] string Title, [property: JsonRequired] string Text, [property: JsonRequired] string Document,
    [property: JsonRequired] bool Pinned, [property: JsonRequired] double CreatedAt, [property: JsonRequired] double UpdatedAt,
    double? DeletedAt = null, [property: JsonRequired] SharedNoteText? RichText = null, bool? Purged = null)
{
    [JsonExtensionData] public Dictionary<string, JsonElement>? AdditionalFields { get; init; }
    [JsonIgnore] public bool IsPurged => Purged == true;
    public bool Expired(double now) => DeletedAt is { } deleted && now - deleted >= 30 * 24 * 60 * 60;
    public static double Now => (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - 978307200000L) / 1000d;
    public static DateTimeOffset Date(double seconds)
    {
        if (!double.IsFinite(seconds)) throw new InvalidDataException("Invalid note timestamp.");
        try { return DateTimeOffset.FromUnixTimeMilliseconds(checked((long)Math.Round(seconds * 1000) + 978307200000L)); }
        catch (Exception error) when (error is OverflowException or ArgumentOutOfRangeException)
        { throw new InvalidDataException("The note timestamp is outside the supported range.", error); }
    }
    public static NoteDocument Create(string folder = "inbox")
    {
        double now = Now; return new(Wire.Id(), folder, "", "", "", false, now, now, RichText: SharedNoteText.Empty);
    }
    public NoteDocument WithoutContent()
    {
        double time = DeletedAt ?? UpdatedAt;
        return new(Id, "inbox", "", "", "", false, time, time, time, SharedNoteText.Empty, true);
    }
    public NoteDocument Copy(string? id = null)
    {
        var extra = AdditionalFields?.Where(p => p.Key is not ("syncVersion" or "lastVoiceTranscriptID" or "appliedVoiceTranscriptIDs")).ToDictionary(p => p.Key, p => p.Value.Clone());
        return this with { Id = id ?? Wire.Id(), UpdatedAt = Now, AdditionalFields = extra };
    }
    public static string FolderKey(string id) => id == "inbox" ? id : "folder-" + Guid.Parse(id).ToString("D").ToUpperInvariant();
    public string? FolderId() => Folder.StartsWith("folder-", StringComparison.Ordinal) && Guid.TryParse(Folder[7..], out var id) ? id.ToString("D") : null;
}
public static class NoteCodec
{
    public const int MaxBytes = 8 * 1024 * 1024;
    public static string Digest(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    public static byte[] Encode(NoteDocument note)
    {
        Validate(note); var bytes = JsonSerializer.SerializeToUtf8Bytes(note, Wire.Json);
        if (bytes.Length > MaxBytes) throw new InvalidDataException("This note exceeds the 8 MiB document limit.");
        return bytes;
    }
    public static NoteDocument Decode(byte[] bytes, string expectedId)
    {
        if (bytes.Length is 0 or > MaxBytes) throw new InvalidDataException("Invalid note size.");
        NoteDocument note;
        try { note = JsonSerializer.Deserialize<NoteDocument>(bytes, Wire.Json) ?? throw new InvalidDataException("Invalid note document."); }
        catch (JsonException error) { throw new InvalidDataException("Invalid shared note document or missing required fields.", error); }
        if (!Guid.TryParse(note.Id, out var id) || id.ToString("D") != expectedId.ToLowerInvariant()) throw new InvalidDataException("The note identifier does not match its response.");
        Validate(note); return note with { Id = id.ToString("D") };
    }
    public static void Validate(NoteDocument note)
    {
        if (note is null || !Guid.TryParseExact(note.Id, "D", out _) || note.Folder is null || note.Title is null || note.Text is null || note.Document is null ||
            !double.IsFinite(note.CreatedAt) || !double.IsFinite(note.UpdatedAt) || note.DeletedAt is { } deleted && !double.IsFinite(deleted))
            throw new InvalidDataException("Invalid note metadata.");
        _ = NoteDocument.Date(note.CreatedAt); _ = NoteDocument.Date(note.UpdatedAt);
        if (note.DeletedAt is { } date) _ = NoteDocument.Date(date);
        if (note.Folder != "inbox" && (note.FolderId() is not { } folderId || note.Folder != NoteDocument.FolderKey(folderId)))
            throw new InvalidDataException("Invalid shared note folder key.");
        SharedNoteText.ValidateUnicode(note.Title);
        if (note.Document.Length != 0 || note.RichText is null) throw new InvalidDataException("Only the current shared note format (version 1) is supported.");
        note.RichText.Validate(note.Text);
        if (note.IsPurged && (note.DeletedAt is null || note.Title.Length != 0 || note.Text.Length != 0 || note.Document.Length != 0 || note.Pinned ||
            note.RichText?.Spans.Count > 0 || note.AdditionalFields?.ContainsKey("lastVoiceTranscriptID") == true)) throw new InvalidDataException("A purged note must not retain content.");
    }
}
public sealed record StoredNote(NoteDocument Document, string Digest, string? Revision, string? ConflictOf = null);
public sealed record PendingNote(string Id, byte[] Bytes, string Digest, string? Revision);
public sealed record NoteCapabilities(int ByteLimit, int FormatVersion);
public sealed record NotesState(string Workspace, List<StoredNote> Notes, int Pending, int Conflicts, string? Error, NoteCapabilities? Capabilities)
{
    public static NotesState Empty => new("local", [], 0, 0, null, new(NoteCodec.MaxBytes, 1));
    public IEnumerable<StoredNote> InSection(string section, string search, double now) => Notes
        .Where(n => !n.Document.IsPurged && !n.Document.Expired(now) && (n.Document.DeletedAt is not null) == (section == "notes:trash") &&
            (section is "notes:all" or "notes:trash" || n.Document.Folder == section) &&
            (n.Document.Title.Contains(search, StringComparison.CurrentCultureIgnoreCase) || n.Document.Text.Contains(search, StringComparison.CurrentCultureIgnoreCase)))
        .OrderByDescending(n => n.Document.Pinned).ThenByDescending(n => n.Document.UpdatedAt).ThenBy(n => n.Document.Id, StringComparer.Ordinal);
}
