using System.Text.Json;
using Takt.Core.Models;
using Takt.Core.Storage;
using Xunit;

namespace Takt.Core.Tests;

// Source-only regression scenarios. No .NET test execution was performed.
public sealed class ProposalStorageTests : IAsyncLifetime
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "takt-proposals-test-" + Guid.NewGuid());
    private PlannerStore store = null!;
    public async Task InitializeAsync() { store = new(Path.Combine(directory, "tasks.sqlite")); await store.InitializeAsync(); }
    public Task DisposeAsync() { store.Dispose(); Directory.Delete(directory, true); return Task.CompletedTask; }
    private async Task<Entity> CreateAsync(string title = "Attached task")
    {
        var edit = TaskRules.CreateTask(title, "inbox"); await store.EditAsync("local", [edit], 0);
        return (await store.ReadAsync()).Tasks.Single(t => t.Id == edit.Id);
    }
    private static string Fingerprint(Library library, string id) => PlannerStore.TaskFingerprint(library.Tasks.Single(t => t.Id == id), library.Items(id));
    [Fact] public void FingerprintIgnoresTransportAcknowledgementAndDictionaryInsertionOrder()
    {
        var original = TaskRulesTests.TaskEntity();
        var childEdit = TaskRules.CreateItem(original.Id, "First step", 0);
        var child = new Entity(childEdit.Id, "checklistItem", childEdit.Fields!, []);
        var stamp = new Stamp(500, 1, Wire.Id(), Wire.Id());
        var acknowledged = original with
        {
            Revision = "42", FileReady = true,
            Fields = original.Fields.Reverse().ToDictionary(p => p.Key, p => p.Value),
            Versions = original.Fields.Keys.ToDictionary(k => k, _ => stamp)
        };
        var acknowledgedChild = child with { Revision = "43", Versions = child.Fields.Keys.ToDictionary(k => k, _ => stamp) };
        Assert.Equal(PlannerStore.TaskFingerprint(original, [child]), PlannerStore.TaskFingerprint(acknowledged, [acknowledgedChild]));
    }
    [Fact] public void FingerprintCanonicalizesNestedPlacementAndDeadlineObjects()
    {
        var task = TaskRulesTests.TaskEntity();
        var fields = task.Fields.ToDictionary(p => p.Key, p => p.Value);
        fields["placement"] = JsonSerializer.Deserialize<JsonElement>("{\"kind\":\"folder\",\"folderId\":\"33333333-3333-4333-8333-333333333333\"}");
        fields["deadline"] = JsonSerializer.Deserialize<JsonElement>("{\"timeZoneId\":\"UTC\",\"includesTime\":false,\"date\":\"2026-12-01\"}");
        var original = task with { Fields = fields };
        var reordered = fields.ToDictionary(p => p.Key, p => p.Value);
        reordered["placement"] = JsonSerializer.Deserialize<JsonElement>("{\"folderId\":\"33333333-3333-4333-8333-333333333333\",\"kind\":\"folder\"}");
        reordered["deadline"] = JsonSerializer.Deserialize<JsonElement>("{\"date\":\"2026-12-01\",\"includesTime\":false,\"timeZoneId\":\"UTC\"}");
        Assert.Equal(PlannerStore.TaskFingerprint(original, []), PlannerStore.TaskFingerprint(task with { Fields = reordered }, []));
        reordered["deadline"] = Wire.Value(new Deadline("UTC", false, "2026-12-02"));
        Assert.NotEqual(PlannerStore.TaskFingerprint(original, []), PlannerStore.TaskFingerprint(task with { Fields = reordered }, []));
    }
    [Fact] public async Task MetadataOnlyRemoteAcknowledgementDoesNotInvalidateReviewedTask()
    {
        var original = TaskRulesTests.TaskEntity();
        string scope = TaskRulesTests.Profile.Workspace;
        await store.ActivateAsync(new(TaskRulesTests.Profile, null), new(1, TaskRulesTests.LibraryId, "1", true, [original]));
        string fingerprint = Fingerprint(await store.ReadAsync(), original.Id);
        var acknowledgement = original with
        {
            Revision = "2", Fields = original.Fields.Reverse().ToDictionary(p => p.Key, p => p.Value),
            Versions = original.Fields.Keys.ToDictionary(k => k, _ => new Stamp(100, 0, Wire.Id(), Wire.Id()))
        };
        await store.ChangesAsync(scope, new(TaskRulesTests.LibraryId, [new("2", acknowledgement)], "2", false));
        await store.EditTaskIfUnchangedAsync(scope, original.Id, fingerprint, [TaskRules.Update(original, "title", Wire.Value("Reviewed title"))], 0);
        var saved = await store.ReadAsync(); Assert.Equal("Reviewed title", saved.Tasks.Single().Text("title")); Assert.Single(saved.Queue);
    }
    [Fact] public async Task ChangedTaskTextRejectsStaleProposalWithoutWritingItsSubtasks()
    {
        var original = await CreateAsync(); string fingerprint = Fingerprint(await store.ReadAsync(), original.Id);
        await store.EditAsync("local", [TaskRules.Update(original, "description", Wire.Value("Text typed after the context was attached"))], 0);
        var proposedChild = TaskRules.CreateItem(original.Id, "Stale proposed step", 0);
        await Assert.ThrowsAsync<InvalidOperationException>(() => store.EditTaskIfUnchangedAsync("local", original.Id, fingerprint,
            [TaskRules.Update(original, "description", Wire.Value("Old-context rewrite")), proposedChild], 0));
        var saved = await store.ReadAsync(); Assert.Equal("Text typed after the context was attached", saved.Tasks.Single().Text("description")); Assert.Empty(saved.Items(original.Id));
    }
    [Fact] public async Task ChangedChecklistCompletionOrOrderInvalidatesContext()
    {
        var task = await CreateAsync(); var first = TaskRules.CreateItem(task.Id, "First", 0); var second = TaskRules.CreateItem(task.Id, "Second", 1);
        await store.EditAsync("local", [first, second], 0);
        var before = await store.ReadAsync(); string fingerprint = Fingerprint(before, task.Id);
        Assert.Equal(fingerprint, PlannerStore.TaskFingerprint(before.Tasks.Single(), before.Items(task.Id).Reverse()));
        await store.EditAsync("local", [TaskRules.Update(before.Items(task.Id).First(), "isCompleted", Wire.Value(true))], 0);
        await Assert.ThrowsAsync<InvalidOperationException>(() => store.EditTaskIfUnchangedAsync("local", task.Id, fingerprint, [TaskRules.Update(task, "title", Wire.Value("Stale result"))], 0));
        var completed = await store.ReadAsync(); string secondFingerprint = Fingerprint(completed, task.Id);
        await store.EditAsync("local", [TaskRules.Update(completed.Items(task.Id).First(), "sortOrder", Wire.Value(2))], 0);
        Assert.NotEqual(secondFingerprint, Fingerprint(await store.ReadAsync(), task.Id));
    }
    [Fact] public async Task ConcurrentApplicationsFromTheSameSnapshotHaveOnlyOneWinner()
    {
        var task = await CreateAsync(); string fingerprint = Fingerprint(await store.ReadAsync(), task.Id);
        var start = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task<bool> Apply(string title)
        {
            await start.Task;
            try { await store.EditTaskIfUnchangedAsync("local", task.Id, fingerprint, [TaskRules.Update(task, "title", Wire.Value(title))], 0); return true; }
            catch (InvalidOperationException) { return false; }
        }
        // Both callers have already captured the same context before either commit.
        var a = Task.Run(() => Apply("First reviewed result")); var b = Task.Run(() => Apply("Second reviewed result"));
        start.SetResult(); var outcomes = await Task.WhenAll(a, b);
        Assert.Single(outcomes.Where(success => success)); Assert.Single(outcomes.Where(success => !success));
        var title = (await store.ReadAsync()).Tasks.Single().Text("title");
        Assert.True(title is "First reviewed result" or "Second reviewed result");
    }
    [Fact] public async Task IncomingSyncAndProposalRaceCannotLoseNewerConfirmedText()
    {
        var original = TaskRulesTests.TaskEntity(); string scope = TaskRulesTests.Profile.Workspace;
        await store.ActivateAsync(new(TaskRulesTests.Profile, null), new(1, TaskRulesTests.LibraryId, "1", true, [original]));
        string fingerprint = Fingerprint(await store.ReadAsync(), original.Id);
        var fields = original.Fields.ToDictionary(p => p.Key, p => p.Value); fields["description"] = Wire.Value("Newer confirmed text");
        var incoming = original with { Fields = fields, Revision = "2", Versions = new() { ["description"] = new Stamp(DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeMilliseconds(), 0, Wire.Id(), Wire.Id()) } };
        var start = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var sync = Task.Run(async () => { await start.Task; await store.ChangesAsync(scope, new(TaskRulesTests.LibraryId, [new("2", incoming)], "2", false)); });
        var apply = Task.Run(async () =>
        {
            await start.Task;
            try { await store.EditTaskIfUnchangedAsync(scope, original.Id, fingerprint, [TaskRules.Update(original, "description", Wire.Value("Reviewed older text"))], 0); }
            catch (InvalidOperationException) { /* Sync won the gate: the context is stale. */ }
        });
        start.SetResult(); await Task.WhenAll(sync, apply);
        var saved = await store.ReadAsync(); Assert.Equal("Newer confirmed text", saved.Tasks.Single().Text("description"));
        Assert.True(saved.Queue.Count <= 1);
    }
    [Fact] public async Task AccountSwitchRejectsTheOldWorkspaceAndKeepsBothLibraries()
    {
        var original = await CreateAsync(); string fingerprint = Fingerprint(await store.ReadAsync(), original.Id);
        await store.ActivateAsync(new(TaskRulesTests.Profile, null), new(1, TaskRulesTests.LibraryId, "0", true, []));
        await Assert.ThrowsAsync<InvalidOperationException>(() => store.EditTaskIfUnchangedAsync("local", original.Id, fingerprint, [TaskRules.Update(original, "title", Wire.Value("Wrong account"))], 0));
        Assert.Empty((await store.ReadAsync()).Tasks); Assert.Empty((await store.ReadAsync()).Queue);
        await store.UseLocalAsync(); Assert.Equal(original.Text("title"), (await store.ReadAsync()).Tasks.Single().Text("title"));
    }
    [Fact] public async Task UnrelatedTaskEditsAndForeignChecklistReuseAreRejected()
    {
        var attached = await CreateAsync(); var other = await CreateAsync("Other task");
        var child = TaskRules.CreateItem(other.Id, "Keep this parent", 0); await store.EditAsync("local", [child], 0);
        string fingerprint = Fingerprint(await store.ReadAsync(), attached.Id);
        await Assert.ThrowsAsync<InvalidDataException>(() => store.EditTaskIfUnchangedAsync("local", attached.Id, fingerprint, [TaskRules.Update(other, "title", Wire.Value("Unexpected change"))], 0));
        var reused = TaskRules.CreateItem(attached.Id, "Must not reparent", 0) with { Id = child.Id };
        await Assert.ThrowsAsync<InvalidDataException>(() => store.EditTaskIfUnchangedAsync("local", attached.Id, fingerprint, [reused], 0));
        var saved = await store.ReadAsync(); Assert.Single(saved.Items(other.Id)); Assert.Empty(saved.Items(attached.Id)); Assert.Equal("Other task", saved.Tasks.Single(t => t.Id == other.Id).Text("title"));
    }
    [Fact] public async Task TombstonedChecklistIdsAndDuplicateBatchIdsCannotBeReused()
    {
        var task = await CreateAsync(); var child = TaskRules.CreateItem(task.Id, "Retired", 0); await store.EditAsync("local", [child, new(child.Id, "checklistItem", "delete")], 0);
        string fingerprint = Fingerprint(await store.ReadAsync(), task.Id);
        await Assert.ThrowsAsync<InvalidDataException>(() => store.EditTaskIfUnchangedAsync("local", task.Id, fingerprint, [child], 0));
        await Assert.ThrowsAsync<InvalidDataException>(() => store.EditTaskIfUnchangedAsync("local", task.Id, fingerprint,
            [TaskRules.Update(task, "title", Wire.Value("First")), TaskRules.Update(task, "description", Wire.Value("Second"))], 0));
        Assert.Equal(fingerprint, Fingerprint(await store.ReadAsync(), task.Id));
    }
    [Fact] public async Task InvalidLaterEditRollsBackTheReviewedTaskWriteAtomically()
    {
        var task = await CreateAsync(); string fingerprint = Fingerprint(await store.ReadAsync(), task.Id);
        var invalid = new Edit(Wire.Id(), "checklistItem", "create", new() { ["taskId"] = Wire.Value(task.Id) });
        await Assert.ThrowsAsync<ArgumentException>(() => store.EditTaskIfUnchangedAsync("local", task.Id, fingerprint,
            [TaskRules.Update(task, "title", Wire.Value("Must roll back")), invalid], 0));
        var saved = await store.ReadAsync(); Assert.Equal(fingerprint, Fingerprint(saved, task.Id)); Assert.Empty(saved.Items(task.Id)); Assert.Empty(saved.Queue);
    }
}
