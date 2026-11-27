using Microsoft.Data.Sqlite;
using System.Text.Json;
using Takt.Core.Models;

namespace Takt.Core.Assistant;

// Local-only history. Account keys never enter this database; every row has an explicit workspace.
public sealed class ChatStore(string databasePath, bool pooling = true) : IDisposable
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private SqliteConnection? db;
    private bool disposed;
    private const int MaxThreads = 200;
    private const long MaxWorkspaceBytes = 64 * 1024 * 1024;
    public Task<IReadOnlyList<ChatThread>> ListAsync(string workspace) => Locked(async () =>
    {
        ChatRules.Workspace(workspace); List<ChatThread> result = [];
        using var command = Command("SELECT id,body FROM chat_threads WHERE workspace=$w ORDER BY updated_at DESC,id", ("$w", workspace));
        using var reader = await command.ExecuteReaderAsync().ConfigureAwait(false);
        while (await reader.ReadAsync().ConfigureAwait(false))
        {
            if (result.Count >= MaxThreads) throw new InvalidDataException("The local chat history exceeds its thread limit.");
            var thread = Decode(reader.GetString(1));
            if (thread.Workspace != workspace || ChatRules.Id(thread.Id) != reader.GetString(0)) throw new InvalidDataException("A chat row belongs to another workspace or thread.");
            result.Add(thread);
        }
        return (IReadOnlyList<ChatThread>)result;
    });
    public Task SaveAsync(ChatThread thread)
    {
        // Snapshot mutable arrays before the first await, including review context and Applied IDs.
        var snapshot = Decode(Encode(thread));
        return Locked(async () =>
        {
            using var tx = db!.BeginTransaction();
            string id = ChatRules.Id(snapshot.Id);
            ChatThread next = snapshot with { Id = id };
            using (var previous = Command("SELECT body FROM chat_threads WHERE workspace=$w AND id=$i", ("$w", next.Workspace), ("$i", id)))
            {
                previous.Transaction = tx;
                if (await previous.ExecuteScalarAsync().ConfigureAwait(false) is string body) next = Merge(Decode(body), next);
            }
            string json = Encode(next);
            using (var size = Command("SELECT COUNT(*),COALESCE(SUM(length(CAST(body AS BLOB))),0) FROM chat_threads WHERE workspace=$w AND id<>$i", ("$w", next.Workspace), ("$i", id)))
            {
                size.Transaction = tx;
                using var reader = await size.ExecuteReaderAsync().ConfigureAwait(false);
                await reader.ReadAsync().ConfigureAwait(false);
                if (reader.GetInt64(0) >= MaxThreads || reader.GetInt64(1) + System.Text.Encoding.UTF8.GetByteCount(json) > MaxWorkspaceBytes)
                    throw new InvalidDataException("The local chat history is full. Remove old threads before saving more.");
            }
            using var save = Command("INSERT INTO chat_threads(workspace,id,body,updated_at) VALUES($w,$i,$b,$u) ON CONFLICT(workspace,id) DO UPDATE SET body=excluded.body,updated_at=excluded.updated_at",
                ("$w", next.Workspace), ("$i", id), ("$b", json), ("$u", next.UpdatedAt.ToUnixTimeMilliseconds()));
            save.Transaction = tx; await save.ExecuteNonQueryAsync().ConfigureAwait(false); tx.Commit(); return true;
        });
    }
    public Task DeleteAsync(string workspace, string threadId) => Locked(async () =>
    {
        ChatRules.Workspace(workspace);
        using var command = Command("DELETE FROM chat_threads WHERE workspace=$w AND id=$i", ("$w", workspace), ("$i", ChatRules.Id(threadId)));
        await command.ExecuteNonQueryAsync().ConfigureAwait(false); return true;
    });
    public Task ClearAsync(string workspace) => Locked(async () =>
    {
        ChatRules.Workspace(workspace);
        using var command = Command("DELETE FROM chat_threads WHERE workspace=$w", ("$w", workspace));
        await command.ExecuteNonQueryAsync().ConfigureAwait(false); return true;
    });
    private static ChatThread Merge(ChatThread old, ChatThread next)
    {
        // Save is append/update, never an implicit history deletion. Explicit Delete/Clear are separate.
        // This prevents a late autosave from erasing a newly received message or applied proposal marker.
        var messages = old.Messages.ToList();
        foreach (var incoming in next.Messages)
        {
            int index = messages.FindIndex(m => ChatRules.Id(m.Id) == ChatRules.Id(incoming.Id));
            if (index < 0) { messages.Add(incoming); continue; }
            var previous = messages[index];
            if (previous.Role != incoming.Role || previous.CreatedAt != incoming.CreatedAt ||
                JsonSerializer.Serialize(previous.Context, Wire.Json) != JsonSerializer.Serialize(incoming.Context, Wire.Json) ||
                JsonSerializer.Serialize(previous.Proposals, Wire.Json) != JsonSerializer.Serialize(incoming.Proposals, Wire.Json))
                throw new InvalidDataException("An existing message's captured context and proposals cannot be replaced. Create a new message.");
            // Completed replies are immutable; a streamed draft should remain in memory until complete.
            if (previous.Text != incoming.Text) throw new InvalidDataException("An existing chat message cannot be replaced. Create a new message.");
            var applied = (previous.Applied ?? []).Union(incoming.Applied ?? [], StringComparer.OrdinalIgnoreCase).ToArray();
            var dismissed = (previous.Dismissed ?? []).Union(incoming.Dismissed ?? [], StringComparer.OrdinalIgnoreCase)
                .Except(applied, StringComparer.OrdinalIgnoreCase).ToArray();
            messages[index] = incoming with { Applied = applied, Dismissed = dismissed };
        }
        return next with { Title = old.UpdatedAt > next.UpdatedAt ? old.Title : next.Title, UpdatedAt = old.UpdatedAt > next.UpdatedAt ? old.UpdatedAt : next.UpdatedAt, Messages = messages.ToArray() };
    }
    private static string Encode(ChatThread thread)
    {
        ChatRules.Thread(thread); string json = JsonSerializer.Serialize(thread, Wire.Json);
        if (System.Text.Encoding.UTF8.GetByteCount(json) > ChatRules.MaxThreadBytes) throw new InvalidDataException("This chat thread exceeds the 8 MiB history limit.");
        return json;
    }
    private static ChatThread Decode(string json)
    {
        if (System.Text.Encoding.UTF8.GetByteCount(json) > ChatRules.MaxThreadBytes) throw new InvalidDataException("This chat thread exceeds the history limit.");
        try
        {
            var thread = JsonSerializer.Deserialize<ChatThread>(json, Wire.Json) ?? throw new InvalidDataException("Invalid saved chat thread.");
            ChatRules.Thread(thread); return thread;
        }
        catch (JsonException error) { throw new InvalidDataException("The saved chat history cannot be read.", error); }
    }
    private async Task EnsureAsync()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (db is not null) return;
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(databasePath))!);
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = databasePath, Pooling = pooling }.ToString());
        try
        {
            await connection.OpenAsync().ConfigureAwait(false);
            using var version = connection.CreateCommand(); version.CommandText = "PRAGMA user_version";
            if (Convert.ToInt64(await version.ExecuteScalarAsync().ConfigureAwait(false)) > 1) throw new InvalidDataException("This chat history requires a newer Takt version.");
            using var command = connection.CreateCommand();
            command.CommandText = "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS chat_threads(workspace TEXT NOT NULL,id TEXT NOT NULL,body TEXT NOT NULL,updated_at INTEGER NOT NULL,PRIMARY KEY(workspace,id)); PRAGMA user_version=1;";
            await command.ExecuteNonQueryAsync().ConfigureAwait(false); db = connection;
        }
        catch { connection.Dispose(); throw; }
    }
    private SqliteCommand Command(string sql, params (string Name, object Value)[] values)
    {
        var command = db!.CreateCommand(); command.CommandText = sql;
        foreach (var (name, value) in values) command.Parameters.AddWithValue(name, value); return command;
    }
    private async Task<T> Locked<T>(Func<Task<T>> action)
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try { await EnsureAsync().ConfigureAwait(false); return await action().ConfigureAwait(false); }
        finally { gate.Release(); }
    }
    public void Dispose()
    {
        gate.Wait();
        try { if (!disposed) { disposed = true; db?.Dispose(); db = null; } }
        finally { gate.Release(); }
        // Keep the tiny gate alive so already queued callers can observe ObjectDisposedException safely.
    }
}
