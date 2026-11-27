using Microsoft.Data.Sqlite;
using System.Globalization;
using System.Text.Json;
using Takt.Core.Models;

namespace Takt.Core.Storage;

// One connection behind a gate; every data/outbox/cursor transition is atomic.
public sealed partial class PlannerStore(string path, bool pooling = true) : IDisposable
{
    private readonly SqliteConnection db = new(new SqliteConnectionStringBuilder { DataSource = path, Pooling = pooling }.ToString());
    private readonly SemaphoreSlim gate = new(1, 1);
    public async Task InitializeAsync()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        await db.OpenAsync();
        await Locked(async () =>
        {
            await Execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;");
            long version = (long)(await Scalar("PRAGMA user_version;"))!;
            if (version > 1) throw new InvalidDataException("This library needs a newer Takt version.");
            using var tx = db.BeginTransaction();
            await Execute("""
                CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS entities(workspace TEXT NOT NULL,id TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(workspace,id));
                CREATE TABLE IF NOT EXISTS outbox(sequence INTEGER PRIMARY KEY AUTOINCREMENT,workspace TEXT NOT NULL,id TEXT NOT NULL UNIQUE,body TEXT NOT NULL,error TEXT);
                CREATE INDEX IF NOT EXISTS workspace_queue ON outbox(workspace,sequence);
                PRAGMA user_version=1;
                """, tx);
            if (await Setting("device", tx) is null) await Set("device", Wire.Id(), tx);
            if (await Setting("localLibrary", tx) is null) await Set("localLibrary", Wire.Id(), tx);
            tx.Commit();
            return true;
        });
    }
    public Task<string> DeviceIdAsync() => Locked(async () => (await Setting("device"))!);
    public Task<Connection?> ConnectionAsync() => Locked(async () => Deserialize<Connection>(await Setting("connection")));
    public Task<string?> CursorAsync(string workspace) => Locked(() => Setting("cursor:" + workspace));
    public Task SaveConnectionAsync(Connection connection) => Locked(async () => { await Set("connection", Serialize(connection)); return true; });
    public Task ActivateAsync(Connection connection, Snapshot snapshot) => Locked(async () =>
    {
        using var tx = db.BeginTransaction();
        await Set("connection", Serialize(connection), tx);
        await Set("active", connection.Profile.Workspace, tx);
        await Replace(snapshot, connection.Profile.Workspace, tx);
        tx.Commit(); return true;
    });
    public Task UseLocalAsync() => Locked(async () =>
    {
        using var tx = db.BeginTransaction();
        await Execute("DELETE FROM settings WHERE key IN ('connection','active');", tx);
        tx.Commit(); return true;
    });
    public Task<Library> ReadAsync() => Locked(ReadCoreAsync);
    private async Task<Library> ReadCoreAsync()
    {
        var connection = Deserialize<Connection>(await Setting("connection"));
        var workspace = await Setting("active") ?? "local";
        var profile = connection?.Profile.Workspace == workspace ? connection.Profile : null;
        var entities = new Dictionary<string, Entity>();
        using (var command = Command("SELECT body FROM entities WHERE workspace=$w", null, ("$w", workspace)))
        using (var reader = await command.ExecuteReaderAsync())
            while (await reader.ReadAsync()) { var e = Deserialize<Entity>(reader.GetString(0))!; entities[e.Id] = e; }
        var queue = await Queue(workspace);
        foreach (var pending in queue)
        {
            entities.TryGetValue(pending.Mutation.EntityId, out var original);
            var e = pending.Mutation.Overlay(original);
            if (e is not null) entities[e.Id] = e;
        }
        return new Library(workspace, profile, entities.Values.ToList(), queue);
    }
    public Task EditAsync(string workspace, IReadOnlyList<Edit> edits, long clockOffset) => Locked(() => EditCoreAsync(workspace, edits, clockOffset));
    private async Task<bool> EditCoreAsync(string workspace, IReadOnlyList<Edit> edits, long clockOffset)
    {
        using var tx = db.BeginTransaction();
        var active = await Setting("active", tx) ?? "local";
        if (active != workspace) throw new InvalidOperationException("The active account changed. Reopen the task.");
        var connection = Deserialize<Connection>(await Setting("connection", tx));
        string library = workspace == "local" ? (await Setting("localLibrary", tx))! : connection!.Profile.LibraryId;
        string device = (await Setting("device", tx))!;
        var clock = Deserialize<Stamp>(await Setting("clock:" + workspace, tx));
        foreach (var edit in edits)
        {
            TaskRules.Validate(edit);
            string id = Wire.Id();
            long millis = Math.Max(Math.Max(0, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + clockOffset), clock?.PhysicalMillis ?? 0);
            int counter = clock?.PhysicalMillis == millis ? checked(clock.LogicalCounter + 1) : 0;
            var stamp = new Stamp(millis, counter, device, id); clock = stamp;
            var mutation = new Mutation(id, library, device, edit.Id, edit.Type, edit.Kind,
                edit.Kind == "delete" ? null : edit.Fields!.ToDictionary(p => p.Key, p => new FieldChange(p.Value, stamp)),
                edit.Kind == "delete" ? stamp : null);
            if (workspace == "local")
            {
                var original = Deserialize<Entity>(await Scalar("SELECT body FROM entities WHERE workspace=$w AND id=$i", tx, ("$w", workspace), ("$i", edit.Id)) as string);
                var entity = mutation.Overlay(original);
                if (entity is not null) await Save(workspace, entity, tx);
            }
            else await Execute("INSERT INTO outbox(workspace,id,body) VALUES($w,$i,$b)", tx,
                ("$w", workspace), ("$i", id), ("$b", Serialize(mutation)));
        }
        if (clock is not null) await Set("clock:" + workspace, Serialize(clock), tx);
        tx.Commit(); return true;
    }
    public Task<List<Mutation>> BatchAsync(string workspace) => Locked(async () => (await Queue(workspace))
        .Where(q => q.Error is null).Select(q => q.Mutation).ToList());
    public Task SnapshotAsync(string workspace, Snapshot snapshot) => Locked(async () =>
    {
        using var tx = db.BeginTransaction(); await Replace(snapshot, workspace, tx); tx.Commit(); return true;
    });
    public Task ChangesAsync(string workspace, ChangePage page) => Locked(async () =>
    {
        using var tx = db.BeginTransaction();
        foreach (var change in page.Changes) await Receive(workspace, change.Entity, tx);
        await Set("cursor:" + workspace, page.NextCursor, tx); tx.Commit(); return true;
    });
    public Task AcceptAsync(string workspace, List<MutationResult> results) => Locked(async () =>
    {
        using var tx = db.BeginTransaction();
        foreach (var result in results)
            if (result.Status == "rejected") await Execute("UPDATE outbox SET error=$e WHERE workspace=$w AND id=$i", tx,
                ("$e", result.Error!.Code), ("$w", workspace), ("$i", result.OperationId!));
            else
            {
                await Receive(workspace, result.Entity!, tx);
                await Execute("DELETE FROM outbox WHERE workspace=$w AND id=$i", tx, ("$w", workspace), ("$i", result.OperationId!));
            }
        tx.Commit(); return true;
    });
    public Task DiscardRejectedAsync(string workspace) => Locked(async () =>
    {
        await Execute("DELETE FROM outbox WHERE workspace=$w AND error IS NOT NULL", null, ("$w", workspace)); return true;
    });
    private async Task Replace(Snapshot snapshot, string workspace, SqliteTransaction tx)
    {
        await Execute("DELETE FROM entities WHERE workspace=$w", tx, ("$w", workspace));
        foreach (var e in snapshot.Entities) await Receive(workspace, e, tx);
        await Set("cursor:" + workspace, snapshot.Cursor, tx);
    }
    private async Task Receive(string workspace, Entity incoming, SqliteTransaction tx)
    {
        var previous = Deserialize<Entity>(await Scalar("SELECT body FROM entities WHERE workspace=$w AND id=$i", tx, ("$w", workspace), ("$i", incoming.Id)) as string);
        if (previous is not null && Wire.Revision(previous.Revision) >= Wire.Revision(incoming.Revision)) return;
        await Save(workspace, incoming, tx);
        var clock = Deserialize<Stamp>(await Setting("clock:" + workspace, tx));
        var newest = incoming.Versions.Values.OrderByDescending(v => v).FirstOrDefault();
        if (newest is not null && newest.CompareTo(clock) > 0) await Set("clock:" + workspace, Serialize(newest), tx);
    }
    private Task Save(string workspace, Entity e, SqliteTransaction tx) => Execute(
        "INSERT INTO entities(workspace,id,body) VALUES($w,$i,$b) ON CONFLICT(workspace,id) DO UPDATE SET body=excluded.body", tx,
        ("$w", workspace), ("$i", e.Id), ("$b", Serialize(e)));
    private async Task<List<Queued>> Queue(string workspace)
    {
        List<Queued> result = [];
        using var command = Command("SELECT body,error FROM outbox WHERE workspace=$w ORDER BY sequence", null, ("$w", workspace));
        using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync()) result.Add(new(Deserialize<Mutation>(reader.GetString(0))!, reader.IsDBNull(1) ? null : reader.GetString(1)));
        return result;
    }
    private Task<string?> Setting(string key, SqliteTransaction? tx = null) => ReadSetting(key, tx);
    private async Task<string?> ReadSetting(string key, SqliteTransaction? tx) => await Scalar("SELECT value FROM settings WHERE key=$k", tx, ("$k", key)) as string;
    private Task Set(string key, string value, SqliteTransaction? tx = null) => Execute(
        "INSERT INTO settings(key,value) VALUES($k,$v) ON CONFLICT(key) DO UPDATE SET value=excluded.value", tx, ("$k", key), ("$v", value));
    private SqliteCommand Command(string sql, SqliteTransaction? tx, params (string, object)[] parameters)
    {
        var command = db.CreateCommand(); command.CommandText = sql; command.Transaction = tx;
        foreach (var (key, value) in parameters) command.Parameters.AddWithValue(key, value);
        return command;
    }
    private async Task Execute(string sql, SqliteTransaction? tx = null, params (string, object)[] parameters)
    { using var command = Command(sql, tx, parameters); await command.ExecuteNonQueryAsync(); }
    private async Task<object?> Scalar(string sql, SqliteTransaction? tx = null, params (string, object)[] parameters)
    { using var command = Command(sql, tx, parameters); return await command.ExecuteScalarAsync(); }
    private async Task<T> Locked<T>(Func<Task<T>> action)
    { await gate.WaitAsync(); try { return await action(); } finally { gate.Release(); } }
    private static string Serialize<T>(T value) => JsonSerializer.Serialize(value, Wire.Json);
    private static T? Deserialize<T>(string? value) => value is null ? default : JsonSerializer.Deserialize<T>(value, Wire.Json);
    public void Dispose() { db.Dispose(); gate.Dispose(); }
}
