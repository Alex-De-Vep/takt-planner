using System.Text.Json;
using Takt.Core.Models;
using Takt.Core.Storage;
using Takt.Core.Notes;

namespace Takt.Core.Sync;

public interface ICredentialVault
{
    string Seal(string scope, string plaintext);
    string Open(string scope, string ciphertext);
}

// Serializes all network operations, including refresh-token rotation. Local edits
// use the store independently, so they remain responsive while a request is pending.
public sealed partial class CloudSync(PlannerStore store, IApiClient api, ICredentialVault vault, NoteStore? notes = null)
{
    public const string DefaultOrigin = "https://takt-server.tail037e91.ts.net";
    private readonly SemaphoreSlim network = new(1, 1);
    private (Profile Profile, string Token, DateTimeOffset Expires)? access;
    private Capabilities? capabilities;
    private DateTimeOffset retryAfter;
    public bool NotesEnabled { get; set; } = notes is not null;
    public long ClockOffset { get; private set; }
    public async Task LoginAsync(string address, string email, string password, bool initializeEmpty, IReadOnlyList<Entity>? initialTasks = null, CancellationToken ct = default)
    {
        await network.WaitAsync(ct);
        try
        {
            CheckRateLimit();
            string origin = ApiClient.NormalizeOrigin(address);
            await Configure(origin, ct);
            var tokens = await api.SendAsync<Tokens>(origin, "/v1/auth/login", new
            { email = email.Trim(), password, deviceId = await store.DeviceIdAsync(), deviceName = Environment.MachineName + " (Windows)" }, cancellation: ct);
            ValidateTokens(tokens);
            var user = await api.SendAsync<Account>(origin, "/v1/me", token: tokens.AccessToken, cancellation: ct);
            if (!Guid.TryParseExact(user.LibraryId, "D", out _)) throw new InvalidDataException("Invalid library identifier.");
            var profile = new Profile(origin, user.Email, user.LibraryId);
            var snapshot = await api.SendAsync<Snapshot>(origin, "/v1/sync/snapshot", token: tokens.AccessToken, cancellation: ct);
            if (initialTasks is { Count: > 0 } && snapshot.Initialized) throw new ApiException(409, "library_exists");
            if (!snapshot.Initialized && initializeEmpty)
            {
                if (snapshot.LibraryId != profile.LibraryId || snapshot.ProtocolVersion != 1) throw new InvalidDataException("Invalid initial library.");
                string importId = Wire.Id();
                try
                {
                    await api.SendAsync<JsonElement>(origin, "/v1/library/imports", new { importId }, tokens.AccessToken, ct);
                    if (initialTasks is { Count: > 0 })
                    {
                        string device = await store.DeviceIdAsync();
                        var prepared = new List<Mutation>();
                        long millis = Math.Max(0, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + ClockOffset);
                        int logical = 0;
                        foreach (var entity in initialTasks.Where(e => !e.Deleted && e.Type is "folder" or "task" or "checklistItem")
                            .OrderBy(e => e.Type switch { "folder" => 0, "task" => 1, _ => 2 }))
                        {
                            var fields = new Dictionary<string, JsonElement>(entity.Fields);
                            if (entity.Type == "task" && entity.Placement is not ("inbox" or "week" or "month") &&
                                !initialTasks.Any(f => !f.Deleted && f.Type == "folder" && f.Id == entity.Placement))
                                fields["placement"] = TaskRules.Placement("inbox");
                            TaskRules.Validate(new(entity.Id, entity.Type, "create", fields));
                            string operation = Wire.Id(); var stamp = new Stamp(millis, logical++, device, operation);
                            prepared.Add(new(operation, profile.LibraryId, device, entity.Id, entity.Type, "create",
                                fields.ToDictionary(p => p.Key, p => new FieldChange(p.Value, stamp))));
                        }
                        while (prepared.Count > 0)
                        {
                            var batch = SyncValidation.Batch(prepared, capabilities);
                            await api.SendAsync<JsonElement>(origin, $"/v1/library/imports/{importId}/mutations", new { mutations = batch }, tokens.AccessToken, ct);
                            prepared.RemoveRange(0, batch.Count);
                        }
                    }
                    await api.SendAsync<JsonElement>(origin, $"/v1/library/imports/{importId}/commit", new { }, tokens.AccessToken, ct);
                }
                catch (ApiException e) when (e.Code == "library_exists" && initialTasks is not { Count: > 0 }) { }
                snapshot = await api.SendAsync<Snapshot>(origin, "/v1/sync/snapshot", token: tokens.AccessToken, cancellation: ct);
            }
            SyncValidation.Snapshot(snapshot, profile);
            await store.ActivateAsync(new(profile, vault.Seal(profile.Workspace, tokens.RefreshToken)), snapshot);
            Remember(profile, tokens);
            if (notes is not null && NotesEnabled) await notes.ConfigureAsync(profile.Workspace, capabilities?.MaxNoteBytes, capabilities?.MaxNoteFormatVersion ?? 0);
        }
        catch (ApiException e) { RateLimit(e); throw; }
        finally { network.Release(); }
    }
    public async Task SynchronizeAsync(CancellationToken ct = default)
    {
        await network.WaitAsync(ct);
        try
        {
            CheckRateLimit();
            var connection = await store.ConnectionAsync();
            if (connection is null) return;
            var profile = connection.Profile;
            await Configure(profile.Origin, ct);
            await Pull(profile, ct);
            while (true)
            {
                ct.ThrowIfCancellationRequested();
                var batch = SyncValidation.Batch(await store.BatchAsync(profile.Workspace), capabilities);
                if (batch.Count == 0) break;
                var response = await Authorized<MutationResults>(profile, "/v1/sync/mutations", new { mutations = batch }, ct);
                SyncValidation.Results(batch, response.Results);
                await store.AcceptAsync(profile.Workspace, response.Results);
            }
            await Pull(profile, ct);
            if (notes is not null && NotesEnabled)
            {
                try
                {
                    await new NoteSync(notes).SynchronizeAsync(profile.Workspace, capabilities?.MaxNoteBytes, capabilities?.MaxNoteFormatVersion ?? 0,
                        (path, body, token) => Authorized<JsonElement>(profile, path, body, token, put: body is not null), ct);
                }
                catch (ApiException e) when (e.Status == 401 || e.Status == 429) { throw; }
                catch (Exception e) when (e is not OperationCanceledException)
                {
                    await notes.ConfigureAsync(profile.Workspace, capabilities?.MaxNoteBytes, capabilities?.MaxNoteFormatVersion ?? 0);
                    await notes.ErrorAsync(profile.Workspace, "Notes could not sync. Saved notes and local changes have been kept.");
                }
            }
        }
        catch (ApiException e) { RateLimit(e); throw; }
        finally { network.Release(); }
    }
    public async Task LogoutAsync(CancellationToken ct = default)
    {
        await network.WaitAsync(ct);
        try
        {
            var connection = await store.ConnectionAsync();
            try
            {
                if (connection?.Credential is not null)
                {
                    await Configure(connection.Profile.Origin, ct);
                    await Authorized<JsonElement>(connection.Profile, "/v1/auth/logout", new { }, ct);
                }
            }
            finally { access = null; await store.UseLocalAsync(); }
        }
        finally { network.Release(); }
    }
    private async Task Configure(string origin, CancellationToken ct)
    {
        var config = await api.SendAsync<Config>(origin, "/v1/config", cancellation: ct);
        if (config.ProtocolVersion != 1) throw new ApiException(409, "incompatible_protocol");
        capabilities = config.Limits;
        ClockOffset = config.ServerTime.ToUnixTimeMilliseconds() - DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    }
    private async Task Pull(Profile profile, CancellationToken ct)
    {
        var cursor = await store.CursorAsync(profile.Workspace);
        if (cursor is not null)
            try
            {
                for (int n = 0; n < 10000; ++n)
                {
                    var page = await Authorized<ChangePage>(profile, "/v1/sync/changes?cursor=" + Uri.EscapeDataString(cursor), null, ct);
                    SyncValidation.Page(page, profile, cursor);
                    await store.ChangesAsync(profile.Workspace, page);
                    if (!page.HasMore) return;
                    cursor = page.NextCursor;
                }
                throw new InvalidDataException("The server did not finish paging changes.");
            }
            catch (ApiException e) when (e.Code is "cursor_expired" or "invalid_cursor") { }
        var snapshot = await Authorized<Snapshot>(profile, "/v1/sync/snapshot", null, ct);
        SyncValidation.Snapshot(snapshot, profile);
        await store.SnapshotAsync(profile.Workspace, snapshot);
    }
    private async Task<string> Access(Profile profile, CancellationToken ct)
    {
        if (access is { } saved && saved.Profile == profile && saved.Expires > DateTimeOffset.UtcNow) return saved.Token;
        var connection = await store.ConnectionAsync();
        if (connection?.Profile != profile || connection.Credential is null || connection.LegacyRefreshPending)
            throw new ApiException(401, "sign_in_required");
        string token;
        try { token = vault.Open(profile.Workspace, connection.Credential); }
        catch (Exception e) when (e is System.Security.Cryptography.CryptographicException or FormatException) { throw new ApiException(401, "sign_in_required"); }
        bool recoverable = capabilities?.RefreshOperationVersion == 1;
        string? operation = recoverable ? connection.RefreshOperationId ?? Wire.Id() : null;
        // Persist BEFORE the request. A timeout reuses the same operation ID;
        // a legacy server requires sign-in after an uncertain rotation.
        await store.SaveConnectionAsync(connection with { RefreshOperationId = operation, LegacyRefreshPending = !recoverable });
        try
        {
            object body = recoverable ? new { refreshToken = token, operationId = operation } : new { refreshToken = token };
            var tokens = await api.SendAsync<Tokens>(profile.Origin, "/v1/auth/refresh", body, cancellation: ct);
            ValidateTokens(tokens);
            await store.SaveConnectionAsync(new(profile, vault.Seal(profile.Workspace, tokens.RefreshToken)));
            Remember(profile, tokens); return tokens.AccessToken;
        }
        catch (ApiException e) when (e.Status == 429)
        {
            if (!recoverable) await store.SaveConnectionAsync(connection);
            throw;
        }
        catch (ApiException e) when (e.Status == 401)
        {
            await store.SaveConnectionAsync(connection with { Credential = null, RefreshOperationId = null, LegacyRefreshPending = false });
            throw new ApiException(401, "sign_in_required");
        }
    }
    private async Task<T> Authorized<T>(Profile profile, string path, object? body, CancellationToken ct, bool put = false)
    {
        string token = await Access(profile, ct);
        try { return await Exchange<T>(profile, path, body, token, ct, put); }
        catch (ApiException e) when (e.Status == 401)
        {
            access = null;
            string refreshed = await Access(profile, ct);
            try { return await Exchange<T>(profile, path, body, refreshed, ct, put); }
            catch (ApiException retry) when (retry.Status == 401)
            {
                access = null;
                var connection = await store.ConnectionAsync();
                if (connection?.Profile == profile) await store.SaveConnectionAsync(connection with { Credential = null });
                throw new ApiException(401, "sign_in_required");
            }
        }
    }
    private Task<T> Exchange<T>(Profile profile, string path, object? body, string token, CancellationToken ct, bool put) => put
        ? api.PutAsync<T>(profile.Origin, path, body!, token, ct) : api.SendAsync<T>(profile.Origin, path, body, token, ct);
    private static void ValidateTokens(Tokens tokens)
    {
        if (string.IsNullOrEmpty(tokens.AccessToken) || string.IsNullOrEmpty(tokens.RefreshToken) || tokens.ExpiresIn <= 0)
            throw new InvalidDataException("Invalid session response.");
    }
    private void Remember(Profile profile, Tokens tokens) => access = (profile, tokens.AccessToken, DateTimeOffset.UtcNow.AddSeconds(Math.Max(0, tokens.ExpiresIn - 30)));
    private void RateLimit(ApiException e) { if (e.RetryAfter is > 0) retryAfter = DateTimeOffset.UtcNow.AddSeconds(Math.Min(e.RetryAfter.Value, 86400)); }
    private void CheckRateLimit()
    {
        if (retryAfter > DateTimeOffset.UtcNow) throw new ApiException(429, "rate_limited", (long)Math.Ceiling((retryAfter - DateTimeOffset.UtcNow).TotalSeconds));
    }
}
