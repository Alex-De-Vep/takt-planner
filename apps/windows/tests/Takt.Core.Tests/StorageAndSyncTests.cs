using System.Text.Json;
using Takt.Core.Models;
using Takt.Core.Storage;
using Takt.Core.Sync;
using Xunit;

namespace Takt.Core.Tests;

public sealed class StorageAndSyncTests : IAsyncLifetime
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "takt-windows-test-" + Guid.NewGuid());
    private PlannerStore store = null!;
    public async Task InitializeAsync() { store = new(Path.Combine(directory, "tasks.sqlite")); await store.InitializeAsync(); }
    public Task DisposeAsync() { store.Dispose(); Directory.Delete(directory, true); return Task.CompletedTask; }
    private Task Connect() => store.ActivateAsync(new(TaskRulesTests.Profile, "sealed-fixture-refresh"), new(1, TaskRulesTests.LibraryId, "0", true, []));
    [Fact] public async Task LocalTaskSurvivesReopeningWithoutEnteringTheCloudQueue()
    {
        var edit = TaskRules.CreateTask("Local only", "today"); await store.EditAsync("local", [edit], 0);
        store.Dispose(); store = new(Path.Combine(directory, "tasks.sqlite")); await store.InitializeAsync();
        var library = await store.ReadAsync(); Assert.Single(library.Tasks); Assert.Empty(library.Queue); Assert.Null(library.Profile);
    }
    [Fact] public async Task FailedMultiEditTransactionLeavesNeitherTaskNorQueueEntry()
    {
        await Connect();
        var invalid = new Edit(Wire.Id(), "checklistItem", "create", new() { ["title"] = Wire.Value("Missing parent") });
        await Assert.ThrowsAsync<ArgumentException>(() => store.EditAsync(TaskRulesTests.Profile.Workspace, [TaskRules.CreateTask("Should roll back", "inbox"), invalid], 0));
        var library = await store.ReadAsync(); Assert.Empty(library.Tasks); Assert.Empty(library.Queue);
    }
    [Fact] public async Task SnapshotReplacementPreservesPendingChangesAndAcknowledgementIsAtomic()
    {
        await Connect(); var edit = TaskRules.CreateTask("Offline edit", "week");
        await store.EditAsync(TaskRulesTests.Profile.Workspace, [edit], 0);
        var queued = (await store.BatchAsync(TaskRulesTests.Profile.Workspace)).Single();
        await store.SnapshotAsync(TaskRulesTests.Profile.Workspace, new(1, TaskRulesTests.LibraryId, "0", true, []));
        Assert.Equal(queued.OperationId, (await store.BatchAsync(TaskRulesTests.Profile.Workspace)).Single().OperationId);
        var confirmed = queued.Overlay(null)! with { Revision = "1" };
        await store.AcceptAsync(TaskRulesTests.Profile.Workspace, [new(queued.OperationId, "applied", confirmed, null)]);
        var library = await store.ReadAsync(); Assert.Single(library.Tasks); Assert.Empty(library.Queue);
    }
    [Fact] public async Task RejectedEditsAreRetainedForExplicitReview()
    {
        await Connect(); await store.EditAsync(TaskRulesTests.Profile.Workspace, [TaskRules.CreateTask("Keep my text", "inbox")], 0);
        var queued = (await store.BatchAsync(TaskRulesTests.Profile.Workspace)).Single();
        await store.AcceptAsync(TaskRulesTests.Profile.Workspace, [new(queued.OperationId, "rejected", null, new("clock_skew"))]);
        Assert.Empty(await store.BatchAsync(TaskRulesTests.Profile.Workspace));
        var library = await store.ReadAsync(); Assert.Single(library.Tasks); Assert.Equal("clock_skew", library.Queue.Single().Error);
    }
    [Fact] public async Task SigningOutPreservesBothLocalAndAccountWorkspaces()
    {
        await store.EditAsync("local", [TaskRules.CreateTask("Personal local task", "inbox")], 0); await Connect();
        await store.EditAsync(TaskRulesTests.Profile.Workspace, [TaskRules.CreateTask("Account task", "inbox")], 0);
        await store.UseLocalAsync(); Assert.Equal("Personal local task", (await store.ReadAsync()).Tasks.Single().Text("title"));
        await Connect(); Assert.Equal("Account task", (await store.ReadAsync()).Tasks.Single().Text("title"));
    }
    [Fact] public async Task RecoverableRefreshReplaysThePersistedOperationAfterALostResponse()
    {
        await Connect(); var api = new FakeApi { FailRefreshOnce = true };
        var first = new CloudSync(store, api, new FixtureVault());
        await Assert.ThrowsAsync<IOException>(() => first.SynchronizeAsync());
        string operation = (await store.ConnectionAsync())!.RefreshOperationId!; Assert.NotEmpty(operation);
        // New engine simulates process restart with no cached access token.
        await new CloudSync(store, api, new FixtureVault()).SynchronizeAsync();
        Assert.Equal(2, api.RefreshOperations.Count); Assert.All(api.RefreshOperations, value => Assert.Equal(operation, value));
        Assert.Null((await store.ConnectionAsync())!.RefreshOperationId);
    }
    [Fact] public async Task RevokedSessionKeepsPendingEditsAndCachedTasks()
    {
        await Connect(); await store.EditAsync(TaskRulesTests.Profile.Workspace, [TaskRules.CreateTask("Unsent task", "inbox")], 0);
        var api = new FakeApi { Revoke = true };
        var error = await Assert.ThrowsAsync<ApiException>(() => new CloudSync(store, api, new FixtureVault()).SynchronizeAsync());
        Assert.Equal(401, error.Status); Assert.Null((await store.ConnectionAsync())!.Credential);
        var library = await store.ReadAsync(); Assert.Single(library.Tasks); Assert.Single(library.Queue); Assert.NotNull(library.Profile);
    }
    [Fact] public async Task LegacyRefreshDoesNotReplayAnUncertainCredential()
    {
        await Connect(); var api = new FakeApi { Recoverable = false, FailRefreshOnce = true };
        await Assert.ThrowsAsync<IOException>(() => new CloudSync(store, api, new FixtureVault()).SynchronizeAsync());
        var error = await Assert.ThrowsAsync<ApiException>(() => new CloudSync(store, api, new FixtureVault()).SynchronizeAsync());
        Assert.Equal("sign_in_required", error.Code); Assert.Single(api.RefreshOperations);
    }
    private sealed class FixtureVault : ICredentialVault
    {
        public string Seal(string scope, string plaintext) => "sealed-" + plaintext;
        public string Open(string scope, string ciphertext) => ciphertext[7..];
    }
    private sealed class FakeApi : IApiClient
    {
        public bool FailRefreshOnce { get; set; }
        public bool Revoke { get; init; }
        public bool Recoverable { get; init; } = true;
        public List<string?> RefreshOperations { get; } = [];
        public Task<T> SendAsync<T>(string origin, string path, object? body = null, string? token = null, CancellationToken cancellation = default)
        {
            object response;
            switch (path)
            {
                case "/v1/config": response = new Config(1, DateTimeOffset.UtcNow, new(RefreshOperationVersion: Recoverable ? 1 : null)); break;
                case "/v1/auth/refresh":
                    var data = Wire.Value(body); RefreshOperations.Add(data.TryGetProperty("operationId", out var op) ? op.GetString() : null);
                    if (FailRefreshOnce) { FailRefreshOnce = false; throw new IOException("Simulated lost response"); }
                    if (Revoke) throw new ApiException(401, "unauthorized");
                    response = new Tokens("fixture-access", "fixture-successor", 900); break;
                case "/v1/sync/changes?cursor=0": response = new ChangePage(TaskRulesTests.LibraryId, [], "0", false); break;
                default: throw new InvalidOperationException("Unexpected test request: " + path);
            }
            return Task.FromResult(JsonSerializer.Deserialize<T>(JsonSerializer.Serialize(response, Wire.Json), Wire.Json)!);
        }
    }
}
