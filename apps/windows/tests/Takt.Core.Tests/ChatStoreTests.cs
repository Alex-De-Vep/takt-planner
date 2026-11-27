using Takt.Core.Assistant;
using Takt.Core.Models;
using Xunit;

namespace Takt.Core.Tests;

public sealed class ChatStoreTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "takt-chat-test-" + Guid.NewGuid());
    private string Database => Path.Combine(directory, "assistant.sqlite");
    private static ChatContext Context(string workspace = "local") => new(workspace, null, null,
        new("22222222-2222-4222-8222-222222222222", "Reference note", "Captured body", "captured-digest", true, false), new(2026, 11, 27), "UTC");
    private static ChatThread Thread(string workspace = "local")
    {
        var proposal = new ChatProposal(Wire.Id(), "noteEdit", Text: "Proposed replacement");
        var reply = new ChatMessage(Wire.Id(), "assistant", "Review changes", DateTimeOffset.UtcNow, [proposal], Context(workspace));
        return new(Wire.Id(), workspace, "A conversation", DateTimeOffset.UtcNow, [reply]);
    }
    public void Dispose() { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    [Fact] public async Task HistoryInitializesLazilyAndPersistsCapturedContextAndAppliedIdentityAcrossRestart()
    {
        var thread = Thread(); thread.Messages[0] = thread.Messages[0] with { Applied = [thread.Messages[0].Proposals[0].Id] };
        using (var store = new ChatStore(Database)) { Assert.False(File.Exists(Database)); await store.SaveAsync(thread); }
        using var reopened = new ChatStore(Database); var restored = Assert.Single(await reopened.ListAsync("local"));
        Assert.Equal("captured-digest", restored.Messages[0].Context!.Note!.Digest);
        Assert.Equal(thread.Messages[0].Proposals[0].Id, Assert.Single(restored.Messages[0].Applied!));
    }
    [Fact] public async Task TheSameThreadIdentifierInDifferentWorkspacesIsFullyIsolated()
    {
        using var store = new ChatStore(Database); var local = Thread(); var other = Thread("other") with { Id = local.Id };
        await store.SaveAsync(local); await store.SaveAsync(other);
        await store.DeleteAsync("local", local.Id); Assert.Empty(await store.ListAsync("local")); Assert.Single(await store.ListAsync("other"));
        await store.SaveAsync(local); await store.ClearAsync("other"); Assert.Empty(await store.ListAsync("other")); Assert.Single(await store.ListAsync("local"));
    }
    [Fact] public async Task StaleAutosaveCannotEraseAppliedMarkersOrANewerReply()
    {
        using var store = new ChatStore(Database); var original = Thread(); await store.SaveAsync(original);
        var updated = original with { Messages = [original.Messages[0] with { Applied = [original.Messages[0].Proposals[0].Id] }, new(Wire.Id(), "user", "Thanks", DateTimeOffset.UtcNow, [], Context())] };
        await store.SaveAsync(updated); await store.SaveAsync(original);
        var restored = Assert.Single(await store.ListAsync("local")); Assert.Equal(2, restored.Messages.Length);
        Assert.Single(restored.Messages[0].Applied!);
    }
    [Fact]
    public async Task DismissalSurvivesStaleSaveAndRestart()
    {
        var original = Thread();
        var reply = original.Messages[0];
        string proposalId = reply.Proposals[0].Id;
        var dismissed = original with { Messages = [reply with { Dismissed = [proposalId] }] };
        using (var store = new ChatStore(Database))
        {
            await store.SaveAsync(original);
            await store.SaveAsync(dismissed);
            await store.SaveAsync(original);
        }

        using var reopened = new ChatStore(Database);
        var restored = Assert.Single(await reopened.ListAsync("local"));
        Assert.Equal(proposalId, Assert.Single(restored.Messages[0].Dismissed!));
        Assert.Empty(restored.Messages[0].Applied!);

        // Once a write has been applied it remains handled, even if an older
        // caller tries to save a separate dismissal of that same proposal.
        await reopened.SaveAsync(original with { Messages = [reply with { Applied = [proposalId] }] });
        await reopened.SaveAsync(dismissed);
        var applied = Assert.Single(await reopened.ListAsync("local"));
        Assert.Equal(proposalId, Assert.Single(applied.Messages[0].Applied!));
        Assert.Empty(applied.Messages[0].Dismissed!);
    }
    [Fact] public async Task AStaleContextCannotReplaceTheCapturedTargetOfASavedProposal()
    {
        using var store = new ChatStore(Database); var original = Thread(); await store.SaveAsync(original);
        var stale = original with { Messages = [original.Messages[0] with { Context = Context() with { Note = Context().Note! with { Digest = "different-digest" } } }] };
        await Assert.ThrowsAsync<InvalidDataException>(() => store.SaveAsync(stale));
        Assert.Equal("captured-digest", (await store.ListAsync("local"))[0].Messages[0].Context!.Note!.Digest);
    }
    [Fact] public async Task ProposalChangesRequireANewMessageRatherThanReplacingAnAppliedIdentity()
    {
        using var store = new ChatStore(Database); var original = Thread(); await store.SaveAsync(original);
        var edited = original with { Messages = [original.Messages[0] with { Proposals = [original.Messages[0].Proposals[0] with { Text = "Different proposal" }] }] };
        await Assert.ThrowsAsync<InvalidDataException>(() => store.SaveAsync(edited));
        Assert.Equal("Proposed replacement", (await store.ListAsync("local"))[0].Messages[0].Proposals[0].Text);
    }
    [Fact] public async Task ReviewAuditMessagesKeepActualReviewedTextWithoutCreatingAnotherExecutableCard()
    {
        using var store = new ChatStore(Database); var thread = Thread();
        var audit = new ChatMessage(Wire.Id(), "user", "Reviewed replacement: corrected body", DateTimeOffset.UtcNow, [], Context());
        await store.SaveAsync(thread with { Messages = [thread.Messages[0], audit] });
        var restored = Assert.Single(await store.ListAsync("local")); Assert.Equal(2, restored.Messages.Length); Assert.Empty(restored.Messages[1].Proposals);
    }
    [Fact] public async Task SavingSnapshotsMutableArraysBeforeAwaitingSqlite()
    {
        using var store = new ChatStore(Database); var thread = Thread(); string body = thread.Messages[0].Text;
        var save = store.SaveAsync(thread); thread.Messages[0] = thread.Messages[0] with { Text = "Changed caller buffer" }; await save;
        Assert.Equal(body, (await store.ListAsync("local"))[0].Messages[0].Text);
    }
    [Fact] public async Task InvalidOrForeignContextsFailBeforeWritingAnyThread()
    {
        using var store = new ChatStore(Database); var thread = Thread();
        var wrong = thread with { Messages = [thread.Messages[0] with { Context = Context("other-workspace") }] };
        await Assert.ThrowsAsync<InvalidDataException>(() => store.SaveAsync(wrong));
        await Assert.ThrowsAsync<InvalidDataException>(() => store.SaveAsync(thread with { Title = new string('x', 1025) }));
        Assert.Empty(await store.ListAsync("local"));
    }
    [Fact] public void AppliedMarkersCannotInventAProposalAndOversizedRepliesAreRejected()
    {
        var thread = Thread();
        Assert.Throws<InvalidDataException>(() => ChatRules.Thread(thread with { Messages = [thread.Messages[0] with { Applied = [Wire.Id()] }] }));
        Assert.Throws<InvalidDataException>(() => ChatRules.Thread(thread with { Messages = [thread.Messages[0] with { Text = new string('x', ChatRules.MaxTextBytes + 1) }] }));
    }
}
