using Microsoft.Data.Sqlite;
using Takt.Core.Models;

namespace Takt.Core.Notes;

// Independent database: adding notes never changes the task schema or its outbox.
public sealed class NoteStore(string path, bool pooling = true) : IDisposable
{
    private readonly SqliteConnection db = new(new SqliteConnectionStringBuilder { DataSource = path, Pooling = pooling }.ToString());
    private readonly SemaphoreSlim gate = new(1, 1);
    public async Task InitializeAsync()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!); await db.OpenAsync();
        await Locked(async () =>
        {
            long version = (long)(await Scalar("PRAGMA user_version"))!;
            if (version > 1) throw new InvalidDataException("These notes require a newer Takt version.");
            await Execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;");
            using var tx = db.BeginTransaction();
            await Execute("""
                CREATE TABLE IF NOT EXISTS notes(workspace TEXT NOT NULL,id TEXT NOT NULL,body BLOB NOT NULL,digest TEXT NOT NULL,revision TEXT,conflict_of TEXT,PRIMARY KEY(workspace,id));
                CREATE TABLE IF NOT EXISTS note_config(workspace TEXT PRIMARY KEY,byte_limit INTEGER NOT NULL,format_version INTEGER NOT NULL,error TEXT);
                PRAGMA user_version=1;
                """, tx); tx.Commit(); return true;
        });
    }
    public Task ConfigureAsync(string workspace, int? limit, int format) => Locked(async () =>
    {
        await Execute("INSERT INTO note_config(workspace,byte_limit,format_version) VALUES($w,$l,$f) ON CONFLICT(workspace) DO UPDATE SET byte_limit=excluded.byte_limit,format_version=excluded.format_version", null,
            ("$w", workspace), ("$l", Math.Clamp(limit ?? 0, 0, NoteCodec.MaxBytes)), ("$f", Math.Clamp(format, 0, 1))); return true;
    });
    public Task ErrorAsync(string workspace, string? error) => Locked(async () =>
    { await Execute("UPDATE note_config SET error=$e WHERE workspace=$w", null, ("$w", workspace), ("$e", error)); return true; });
    public Task<NotesState> ReadAsync(string workspace) => Locked(async () =>
    {
        var rows = await ReadAll(workspace); NoteCapabilities? caps = workspace == "local" ? new(NoteCodec.MaxBytes, 1) : null; string? error = null;
        using var command = Command("SELECT byte_limit,format_version,error FROM note_config WHERE workspace=$w", null, ("$w", workspace));
        using var reader = await command.ExecuteReaderAsync();
        if (await reader.ReadAsync()) { caps = new(reader.GetInt32(0), reader.GetInt32(1)); error = reader.IsDBNull(2) ? null : reader.GetString(2); }
        return new NotesState(workspace, rows, workspace == "local" ? 0 : rows.Count(n => n.Digest != n.Revision), rows.Count(n => n.ConflictOf is not null && !n.Document.IsPurged), error, caps);
    });
    public Task<StoredNote?> FindAsync(string workspace, string id) => Locked(() => Read(workspace, CanonicalId(id)));
    public Task<StoredNote> SaveAsync(string workspace, string? expectedDigest, NoteDocument note) => Locked(async () =>
    {
        NoteCodec.Validate(note);
        note = note with { Id = Guid.Parse(note.Id).ToString("D") };
        using var tx = db.BeginTransaction(); var old = await Read(workspace, note.Id, tx);
        if (old is not null && (old.Document.IsPurged || old.Document.Expired(NoteDocument.Now))) throw new InvalidOperationException("This note was permanently removed. Recover your draft as a new note.");
        bool conflict = old?.Digest != expectedDigest;
        var next = conflict ? note.Copy() : note;
        byte[] bytes = NoteCodec.Encode(next); await CheckLimit(workspace, bytes.Length, tx);
        var saved = new StoredNote(next, NoteCodec.Digest(bytes), conflict ? null : old?.Revision, conflict ? note.Id : old?.ConflictOf);
        await Write(workspace, saved, bytes, tx); tx.Commit(); return saved;
    });
    public Task ImportAsync(string workspace, IReadOnlyList<NoteDocument> notes) => Locked(async () =>
    {
        if (notes is null || notes.Count > 10000) throw new InvalidDataException("Invalid number of imported notes.");
        using var tx = db.BeginTransaction();
        foreach (var note in notes)
        {
            NoteCodec.Validate(note);
            if (note.IsPurged || note.Expired(NoteDocument.Now)) throw new InvalidDataException("Permanently removed notes cannot be imported.");
            var next = note.Copy(); var bytes = NoteCodec.Encode(next); await CheckLimit(workspace, bytes.Length, tx);
            await Write(workspace, new(next, NoteCodec.Digest(bytes), null), bytes, tx);
        }
        tx.Commit(); return true;
    });
    public Task RestoreLocalAsync(IReadOnlyList<NoteDocument> documents) => Locked(async () =>
    {
        if (documents.Count > 10000 || documents.Select(note => note.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != documents.Count)
            throw new InvalidDataException("The backup contains invalid or duplicate notes.");
        if ((await ReadAll("local")).Count != 0) throw new InvalidOperationException("Restore requires a fresh note library.");

        using var tx = db.BeginTransaction();
        foreach (var document in documents.Where(note => !note.IsPurged && !note.Expired(NoteDocument.Now)))
        {
            var note = document with { Id = CanonicalId(document.Id) };
            var bytes = NoteCodec.Encode(note);
            await Write("local", new(note, NoteCodec.Digest(bytes), null), bytes, tx);
        }
        tx.Commit();
        return true;
    });

    public Task<List<PendingNote>> PendingAsync(string workspace) => Locked(async () =>
    {
        List<PendingNote> result = [];
        using var command = Command("SELECT id,body,digest,revision FROM notes WHERE workspace=$w AND (revision IS NULL OR revision<>digest) ORDER BY id", null, ("$w", workspace));
        using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync()) result.Add(new(reader.GetString(0), (byte[])reader[1], reader.GetString(2), reader.IsDBNull(3) ? null : reader.GetString(3)));
        return result;
    });
    public Task<Dictionary<string, string?>> RevisionsAsync(string workspace) => Locked(async () =>
    {
        Dictionary<string, string?> result = [];
        using var command = Command("SELECT id,revision FROM notes WHERE workspace=$w", null, ("$w", workspace));
        using var reader = await command.ExecuteReaderAsync(); while (await reader.ReadAsync()) result.Add(reader.GetString(0), reader.IsDBNull(1) ? null : reader.GetString(1));
        return result;
    });
    public Task<string?> ReceiveAsync(string workspace, string id, string revision, byte[] bytes) => Locked(async () =>
    {
        if (NoteCodec.Digest(bytes) != revision) throw new InvalidDataException("The downloaded note failed its SHA-256 check.");
        id = CanonicalId(id);
        var received = NoteCodec.Decode(bytes, id); bool expired = received.Expired(NoteDocument.Now);
        var incoming = received.IsPurged || expired ? received.WithoutContent() : received;
        var data = expired && !received.IsPurged ? NoteCodec.Encode(incoming) : bytes;
        using var tx = db.BeginTransaction(); var old = await Read(workspace, id, tx); string? copyId = null;
        if (old?.Digest == revision && data.AsSpan().SequenceEqual(bytes))
        {
            await Execute("UPDATE notes SET revision=$r WHERE workspace=$w AND id=$i", tx, ("$r", revision), ("$w", workspace), ("$i", id));
        }
        else
        {
            if (old is not null && old.Digest != old.Revision && !old.Document.IsPurged && !old.Document.Expired(NoteDocument.Now) && !incoming.IsPurged)
            {
                var copy = old.Document.Copy(); copyId = copy.Id; var copied = NoteCodec.Encode(copy);
                await Write(workspace, new(copy, NoteCodec.Digest(copied), null, id), copied, tx);
            }
            await Write(workspace, new(incoming, NoteCodec.Digest(data), revision), data, tx);
        }
        tx.Commit(); return copyId;
    });
    // Acknowledge the uploaded bytes, not the current local digest. An edit made
    // during upload must remain pending against the newly accepted server revision.
    public Task AcknowledgeAsync(string workspace, PendingNote sent) => Locked(async () =>
    {
        if (NoteCodec.Digest(sent.Bytes) != sent.Digest) throw new InvalidDataException("The uploaded note bytes no longer match their digest.");
        string id = CanonicalId(sent.Id); _ = NoteCodec.Decode(sent.Bytes, id);
        using var tx = db.BeginTransaction(); var current = await Read(workspace, id, tx);
        if (current is not null && current.Revision == sent.Revision)
            await Execute("UPDATE notes SET revision=$r WHERE workspace=$w AND id=$i", tx, ("$r", sent.Digest), ("$w", workspace), ("$i", id));
        tx.Commit(); return true;
    });
    public Task RehomeFolderAsync(string workspace, string folder) => Locked(async () =>
    {
        var rows = await ReadAll(workspace); using var tx = db.BeginTransaction();
        foreach (var old in rows.Where(n => n.Document.Folder == folder && !n.Document.IsPurged))
        {
            var next = old.Document with { Folder = "inbox", UpdatedAt = NoteDocument.Now }; var bytes = NoteCodec.Encode(next);
            await Write(workspace, new(next, NoteCodec.Digest(bytes), old.Revision, old.ConflictOf), bytes, tx);
        }
        tx.Commit(); return true;
    });
    public Task<List<string>> PurgeExpiredAsync(string workspace, double now) => Locked(async () =>
    {
        var notes = await ReadAll(workspace); List<string> purged = [];
        using var tx = db.BeginTransaction();
        foreach (var old in notes.Where(n => !n.Document.IsPurged && n.Document.Expired(now)))
        {
            var next = old.Document.WithoutContent(); var bytes = NoteCodec.Encode(next);
            await Write(workspace, new(next, NoteCodec.Digest(bytes), old.Revision), bytes, tx); purged.Add(next.Id);
        }
        tx.Commit(); return purged;
    });
    private async Task CheckLimit(string workspace, int length, SqliteTransaction tx)
    {
        var value = await Scalar("SELECT byte_limit FROM note_config WHERE workspace=$w", tx, ("$w", workspace));
        int limit = workspace == "local" || value is null ? NoteCodec.MaxBytes : Math.Clamp(Convert.ToInt32(value), 0, NoteCodec.MaxBytes);
        if (limit > 0 && length > limit) throw new InvalidDataException("This note exceeds the server's document limit.");
    }
    private async Task<List<StoredNote>> ReadAll(string workspace)
    {
        List<StoredNote> result = []; using var command = Command("SELECT id,body,digest,revision,conflict_of FROM notes WHERE workspace=$w", null, ("$w", workspace));
        using var reader = await command.ExecuteReaderAsync(); while (await reader.ReadAsync()) result.Add(Row(reader)); return result;
    }
    private async Task<StoredNote?> Read(string workspace, string id, SqliteTransaction? tx = null)
    {
        using var command = Command("SELECT id,body,digest,revision,conflict_of FROM notes WHERE workspace=$w AND id=$i", tx, ("$w", workspace), ("$i", id));
        using var reader = await command.ExecuteReaderAsync(); return await reader.ReadAsync() ? Row(reader) : null;
    }
    private static StoredNote Row(SqliteDataReader reader)
    {
        var bytes = (byte[])reader[1]; string digest = reader.GetString(2);
        if (NoteCodec.Digest(bytes) != digest) throw new InvalidDataException("A cached note failed its integrity check.");
        return new(NoteCodec.Decode(bytes, reader.GetString(0)), digest, reader.IsDBNull(3) ? null : reader.GetString(3), reader.IsDBNull(4) ? null : reader.GetString(4));
    }
    private static string CanonicalId(string id) => Guid.TryParseExact(id, "D", out var value) ? value.ToString("D") : throw new InvalidDataException("Invalid note identifier.");
    private Task Write(string workspace, StoredNote note, byte[] bytes, SqliteTransaction tx) => Execute(
        "INSERT INTO notes(workspace,id,body,digest,revision,conflict_of) VALUES($w,$i,$b,$d,$r,$c) ON CONFLICT(workspace,id) DO UPDATE SET body=excluded.body,digest=excluded.digest,revision=excluded.revision,conflict_of=excluded.conflict_of", tx,
        ("$w", workspace), ("$i", note.Document.Id), ("$b", bytes), ("$d", note.Digest), ("$r", note.Revision), ("$c", note.ConflictOf));
    private SqliteCommand Command(string sql, SqliteTransaction? tx, params (string, object?)[] parameters)
    {
        var command = db.CreateCommand(); command.CommandText = sql; command.Transaction = tx;
        foreach (var (key, value) in parameters) command.Parameters.AddWithValue(key, value ?? DBNull.Value); return command;
    }
    private async Task Execute(string sql, SqliteTransaction? tx = null, params (string, object?)[] parameters)
    { using var command = Command(sql, tx, parameters); await command.ExecuteNonQueryAsync(); }
    private async Task<object?> Scalar(string sql, SqliteTransaction? tx = null, params (string, object?)[] parameters)
    { using var command = Command(sql, tx, parameters); return await command.ExecuteScalarAsync(); }
    private async Task<T> Locked<T>(Func<Task<T>> action)
    { await gate.WaitAsync(); try { return await action(); } finally { gate.Release(); } }
    public void Dispose() { db.Dispose(); gate.Dispose(); }
}
