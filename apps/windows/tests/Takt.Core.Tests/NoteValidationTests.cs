using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Takt.Core.Notes;
using Takt.Core.Models;
using Xunit;

namespace Takt.Core.Tests;

public sealed class NoteValidationTests : IAsyncLifetime
{
    private const string Scope = "https://example.com|11111111-1111-4111-8111-111111111111";
    private readonly string directory = Path.Combine(Path.GetTempPath(), "takt-note-validation-" + Guid.NewGuid());
    private NoteStore store = null!;
    public async Task InitializeAsync()
    {
        store = new(Path.Combine(directory, "notes.sqlite"));
        await store.InitializeAsync(); await store.ConfigureAsync(Scope, NoteCodec.MaxBytes, 1);
    }
    public Task DisposeAsync() { store.Dispose(); Directory.Delete(directory, true); return Task.CompletedTask; }
    private static NoteDocument Note(string text = "Body") => NoteDocument.Create() with { Title = "Title", Text = text };

    [Theory]
    [InlineData("id")] [InlineData("folder")] [InlineData("title")] [InlineData("text")] [InlineData("document")]
    [InlineData("pinned")] [InlineData("createdAt")] [InlineData("updatedAt")] [InlineData("richText")]
    public void MissingRequiredDocumentFieldsCannotBecomeDefaultValues(string field)
    {
        var note = Note(); var json = JsonNode.Parse(NoteCodec.Encode(note))!.AsObject(); json.Remove(field);
        Assert.Throws<InvalidDataException>(() => NoteCodec.Decode(Encoding.UTF8.GetBytes(json.ToJsonString()), note.Id));
    }
    [Fact] public void MissingFormattingStartDoesNotSilentlyMoveAStyledRangeToZero()
    {
        var note = Note("hello") with { RichText = new(1, [new(0, 5, Bold: true)]) };
        var json = JsonNode.Parse(NoteCodec.Encode(note))!;
        json["richText"]!["spans"]![0]!.AsObject().Remove("start");
        Assert.Throws<InvalidDataException>(() => NoteCodec.Decode(Encoding.UTF8.GetBytes(json.ToJsonString()), note.Id));
    }
    [Fact] public void AFormattingSpanMustBeAnObject()
    {
        Assert.Throws<InvalidDataException>(() => new SharedNoteText(1, [null!]).Validate("hello"));
    }
    [Fact] public void CurrentNotesNeverFallBackToAnUnformattedDocument()
    {
        Assert.Throws<InvalidDataException>(() => NoteText.NormalizeNewlines("hello", null!));
    }
    [Fact] public void TitlesAndTimestampsCannotBeSilentlyReplacedOrOverflowOnDisplay()
    {
        Assert.Throws<InvalidDataException>(() => NoteCodec.Encode(Note() with { Title = "\uD800" }));
        Assert.Throws<InvalidDataException>(() => NoteCodec.Encode(Note() with { CreatedAt = double.MaxValue }));
        Assert.Throws<InvalidDataException>(() => NoteDocument.Date(double.NaN));
    }
    [Fact] public void FolderKeysUseTheSharedCanonicalUuidFormat()
    {
        string folder = NoteDocument.FolderKey("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
        Assert.Throws<InvalidDataException>(() => NoteCodec.Encode(Note() with { Folder = folder.ToLowerInvariant() }));
        Assert.Throws<InvalidDataException>(() => NoteCodec.Encode(Note() with { Folder = "folder-{aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa}" }));
        NoteCodec.Validate(Note() with { Folder = folder });
    }
    [Theory]
    [InlineData("https://example.com/quoted\"path")] [InlineData("https://example.com/space path")]
    [InlineData("https://example.com\\path")] [InlineData("https://example.com/<tag>")]
    public void HyperlinksDoNotContainUnescapedNativeFieldSyntax(string address) => Assert.False(SharedNoteText.ValidLink(address));
    [Fact] public async Task SaveAndFindUseTheSameUuidIdentityRegardlessOfLetterCase()
    {
        var note = Note() with { Id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" };
        var saved = await store.SaveAsync(Scope, null, note with { Id = note.Id.ToUpperInvariant() });
        Assert.Equal(note.Id, saved.Document.Id);
        Assert.Equal(saved.Digest, (await store.FindAsync(Scope, note.Id.ToUpperInvariant()))!.Digest);
        await store.SaveAsync(Scope, saved.Digest, note with { Id = note.Id.ToUpperInvariant(), Text = "Edited" });
        Assert.Single((await store.ReadAsync(Scope)).Notes);
    }
    [Fact] public async Task UppercaseDownloadIdentifierCannotBypassConflictPreservation()
    {
        var initial = Note() with { Id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" };
        var bytes = NoteCodec.Encode(initial); await store.ReceiveAsync(Scope, initial.Id, NoteCodec.Digest(bytes), bytes);
        var old = (await store.FindAsync(Scope, initial.Id))!;
        await store.SaveAsync(Scope, old.Digest, initial with { Text = "Unsent local draft" });
        var remote = initial with { Text = "Remote edit" }; bytes = NoteCodec.Encode(remote);
        string? copied = await store.ReceiveAsync(Scope, initial.Id.ToUpperInvariant(), NoteCodec.Digest(bytes), bytes);
        Assert.NotNull(copied); Assert.Equal("Unsent local draft", (await store.FindAsync(Scope, copied!))!.Document.Text);
        Assert.Equal("Remote edit", (await store.FindAsync(Scope, initial.Id))!.Document.Text);
    }
    [Fact] public async Task AFailedImportRollsBackAllEarlierRows()
    {
        var good = Note(); var invalid = Note() with { RichText = null };
        await Assert.ThrowsAsync<InvalidDataException>(() => store.ImportAsync(Scope, [good, invalid]));
        Assert.Empty((await store.ReadAsync(Scope)).Notes);
    }
    [Fact] public async Task ImportDoesNotRecreatePermanentlyRemovedDocuments()
    {
        var removed = (Note() with { DeletedAt = NoteDocument.Now }).WithoutContent();
        await Assert.ThrowsAsync<InvalidDataException>(() => store.ImportAsync(Scope, [removed]));
        Assert.Empty((await store.ReadAsync(Scope)).Notes);
    }
    [Fact] public async Task AMatchingDownloadStillPurgesExpiredContent()
    {
        var expired = Note("Expired content") with { DeletedAt = NoteDocument.Now - 31 * 24 * 60 * 60 };
        await store.SaveAsync(Scope, null, expired);
        var bytes = NoteCodec.Encode(expired);
        await store.ReceiveAsync(Scope, expired.Id, NoteCodec.Digest(bytes), bytes);
        var current = (await store.FindAsync(Scope, expired.Id))!;
        Assert.True(current.Document.IsPurged); Assert.Empty(current.Document.Text);
        Assert.Single(await store.PendingAsync(Scope));
    }
    [Fact] public async Task AnAcknowledgementCannotMarkDifferentBytesAsSynced()
    {
        await store.SaveAsync(Scope, null, Note());
        var sent = (await store.PendingAsync(Scope)).Single();
        await Assert.ThrowsAsync<InvalidDataException>(() => store.AcknowledgeAsync(Scope, sent with { Bytes = Encoding.UTF8.GetBytes("{}") }));
        Assert.Single(await store.PendingAsync(Scope));
    }
    [Fact] public void BackupRejectsNullRowsWithADataError()
    {
        Assert.Throws<InvalidDataException>(() => NoteBackup.Import("{\"formatVersion\":1,\"createdAt\":\"2026-11-27T00:00:00Z\",\"notes\":[null]}", Library.Empty));
    }
    [Fact] public async Task InvalidIndexRowsFailBeforeAnyUpload()
    {
        bool uploaded = false;
        Task<JsonElement> Request(string path, object? body, CancellationToken ct)
        {
            uploaded |= body is not null;
            using var json = JsonDocument.Parse("{\"notes\":[null]}"); return Task.FromResult(json.RootElement.Clone());
        }
        await Assert.ThrowsAsync<InvalidDataException>(() => new NoteSync(store).SynchronizeAsync(Scope, NoteCodec.MaxBytes, 1, Request));
        Assert.False(uploaded);
    }
}
