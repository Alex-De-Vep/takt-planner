using System.Net;
using System.Text;
using System.Text.Json;
using Takt.Core.Models;
using Takt.Core.Notes;
using Takt.Core.Sync;
using Xunit;

namespace Takt.Core.Tests;

public sealed class NoteTests : IAsyncLifetime
{
    private const string Scope = "https://example.com|11111111-1111-4111-8111-111111111111";
    private readonly string directory = Path.Combine(Path.GetTempPath(), "takt-notes-test-" + Guid.NewGuid());
    private NoteStore store = null!;
    public async Task InitializeAsync() { store = new(Path.Combine(directory, "notes.sqlite")); await store.InitializeAsync(); await store.ConfigureAsync(Scope, NoteCodec.MaxBytes, 1); }
    public Task DisposeAsync() { store.Dispose(); Directory.Delete(directory, true); return Task.CompletedTask; }
    private static NoteDocument Note(string text = "Shared note") => NoteDocument.Create() with { Title = "Release notes", Text = text };
    [Fact] public void FoundationEpochMatchesMacAndAndroid()
    {
        Assert.Equal(new DateTimeOffset(2001, 1, 1, 0, 0, 0, TimeSpan.Zero), NoteDocument.Date(0));
        Assert.Equal("folder-22222222-2222-4222-8222-222222222222", NoteDocument.FolderKey(TaskRulesTests.TaskId));
        Assert.Equal("folder-AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", NoteDocument.FolderKey("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"));
    }
    [Fact] public void OnlyCurrentSharedDocumentsAreAccepted()
    {
        Assert.Throws<InvalidDataException>(() => NoteCodec.Encode(Note() with { RichText = null }));
        Assert.Throws<InvalidDataException>(() => NoteCodec.Encode(Note() with { Document = "b3BhcXVl" }));
        Assert.Throws<InvalidDataException>(() => NoteCodec.Encode(Note() with { RichText = new(2, []) }));
        var note = Note(); Assert.Equal(note.Id, NoteCodec.Decode(NoteCodec.Encode(note), note.Id).Id);
    }
    [Fact] public void FormattingOffsetsUseUtf16AndDoNotSplitEmoji()
    {
        new SharedNoteText(1, [new(1, 3, Bold: true)]).Validate("a😀z");
        Assert.Throws<InvalidDataException>(() => new SharedNoteText(1, [new(2, 3, Bold: true)]).Validate("a😀z"));
        Assert.Throws<InvalidDataException>(() => new SharedNoteText(1, []).Validate("\uD800"));
        Assert.Throws<InvalidDataException>(() => new SharedNoteText(1, [new(0, 2, Bold: true), new(1, 3, Italic: true)]).Validate("abc"));
    }
    [Fact] public void NativeNewlineNormalizationKeepsFormattingAndTrailingNewlines()
    {
        var normalized = NoteText.NormalizeNewlines("A\r\n😀\rB\r\n", new(1, [new(3, 5, Bold: true)]));
        Assert.Equal("A\n😀\nB\n", normalized.Text);
        Assert.Equal(new NoteSpan(2, 4, Bold: true), normalized.RichText.Spans.Single());
    }
    [Fact] public void InlineImagesRequireMatchingObjectsAndBoundedPngData()
    {
        var png = Png(); new SharedNoteText(1, [new(2, 3, Image: Convert.ToBase64String(png))]).Validate("😀\uFFFC");
        Assert.Throws<InvalidDataException>(() => SharedNoteText.Empty.Validate("\uFFFC"));
        Assert.Throws<InvalidDataException>(() => new SharedNoteText(1, [new(0, 1, Image: Convert.ToBase64String(png))]).Validate("x"));
        png[16] = 255; Assert.Throws<InvalidDataException>(() => SharedNoteText.ValidatePng(png));
    }
    [Theory] [InlineData("javascript:alert(1)")] [InlineData("file:///c:/private.txt")] [InlineData("data:text/html,hello")] [InlineData("https://example.com/\nsecret")]
    public void NoteLinksDoNotAllowExecutableOrLocalSchemes(string uri) => Assert.False(SharedNoteText.ValidLink(uri));
    [Fact] public void NativeRtfClipboardPngExtractionDoesNotMixMetadataIntoImageBytes()
    {
        var png = Png(); var hex = Convert.ToHexString(png);
        Assert.Equal(png, NoteText.RtfPngImages("{\\rtf1{\\pict\\pngblip\\picw1\\pich1{\\*\\blipuid aabb} " + hex + "}}").Single());
        Assert.Throws<InvalidDataException>(() => NoteText.RtfPngImages("{\\rtf1{\\pict\\jpegblip abcd}}"));
        Assert.Throws<InvalidDataException>(() => NoteText.RtfPngImages("{\\rtf1{\\pict\\pngblip\\bin4 abcd}}"));
    }
    [Fact] public async Task LocalNotesPersistAcrossRestartAndStaySeparateFromAccounts()
    {
        var note = Note(); await store.SaveAsync("local", null, note);
        store.Dispose(); store = new(Path.Combine(directory, "notes.sqlite")); await store.InitializeAsync();
        Assert.Single((await store.ReadAsync("local")).Notes); Assert.Empty((await store.ReadAsync(Scope)).Notes);
        Assert.Equal(0, (await store.ReadAsync("local")).Pending);
    }
    [Fact] public async Task SavingAgainstAStaleEditorCreatesACopyInsteadOfOverwriting()
    {
        var note = Note(); var original = await store.SaveAsync(Scope, null, note);
        var newer = await store.SaveAsync(Scope, original.Digest, note with { Text = "Newer text" });
        var copy = await store.SaveAsync(Scope, original.Digest, note with { Text = "Open editor draft" });
        Assert.NotEqual(note.Id, copy.Document.Id); Assert.Equal(note.Id, copy.ConflictOf);
        Assert.Equal(newer.Digest, (await store.FindAsync(Scope, note.Id))!.Digest);
        Assert.Equal(2, (await store.ReadAsync(Scope)).Notes.Count);
    }
    [Fact] public async Task RemoteConflictKeepsBothDocumentsAndQueuesTheLocalCopy()
    {
        var initial = Note(); var bytes = NoteCodec.Encode(initial); await store.ReceiveAsync(Scope, initial.Id, NoteCodec.Digest(bytes), bytes);
        var original = (await store.FindAsync(Scope, initial.Id))!;
        await store.SaveAsync(Scope, original.Digest, initial with { Text = "Offline Windows edit" });
        var remote = initial with { Text = "Concurrent Mac edit" }; bytes = NoteCodec.Encode(remote);
        string? copyId = await store.ReceiveAsync(Scope, initial.Id, NoteCodec.Digest(bytes), bytes);
        Assert.NotNull(copyId); Assert.Equal("Offline Windows edit", (await store.FindAsync(Scope, copyId!))!.Document.Text);
        Assert.Equal("Concurrent Mac edit", (await store.FindAsync(Scope, initial.Id))!.Document.Text);
        Assert.Single(await store.PendingAsync(Scope));
    }
    [Fact] public async Task AcknowledgingAnUploadDoesNotEraseAnEditMadeWhileItWasInFlight()
    {
        var note = Note(); byte[] bytes = NoteCodec.Encode(note); await store.ReceiveAsync(Scope, note.Id, NoteCodec.Digest(bytes), bytes);
        var original = (await store.FindAsync(Scope, note.Id))!;
        var first = await store.SaveAsync(Scope, original.Digest, note with { Text = "First edit" });
        var sent = (await store.PendingAsync(Scope)).Single();
        var second = await store.SaveAsync(Scope, first.Digest, note with { Text = "Second edit" });
        await store.AcknowledgeAsync(Scope, sent);
        var pending = (await store.PendingAsync(Scope)).Single();
        Assert.Equal(second.Digest, pending.Digest); Assert.Equal(first.Digest, pending.Revision);
    }
    [Fact] public async Task DownloadHashMismatchNeverReplacesTheSavedDocument()
    {
        var note = Note(); var saved = await store.SaveAsync(Scope, null, note);
        await Assert.ThrowsAsync<InvalidDataException>(() => store.ReceiveAsync(Scope, note.Id, new string('0', 64), NoteCodec.Encode(note with { Text = "Corrupt transport" })));
        Assert.Equal(saved.Digest, (await store.FindAsync(Scope, note.Id))!.Digest);
    }
    [Fact] public async Task TrashIsRestorableBeforeRetentionAndPurgedAfterThirtyDays()
    {
        var note = Note(); var saved = await store.SaveAsync(Scope, null, note);
        var trashed = await store.SaveAsync(Scope, saved.Digest, note with { DeletedAt = NoteDocument.Now });
        var restored = await store.SaveAsync(Scope, trashed.Digest, note);
        Assert.Null(restored.Document.DeletedAt);
        double deleted = NoteDocument.Now - 31 * 24 * 60 * 60;
        await store.SaveAsync(Scope, restored.Digest, note with { DeletedAt = deleted });
        Assert.Single(await store.PurgeExpiredAsync(Scope, NoteDocument.Now));
        var purged = (await store.FindAsync(Scope, note.Id))!;
        Assert.True(purged.Document.IsPurged); Assert.Empty(purged.Document.Text); Assert.Empty(purged.Document.RichText!.Spans);
        await Assert.ThrowsAsync<InvalidOperationException>(() => store.SaveAsync(Scope, purged.Digest, note));
    }
    [Fact] public async Task PurgedRemoteDocumentDoesNotCreateAContentBearingConflictCopy()
    {
        var note = Note(); await store.SaveAsync(Scope, null, note);
        var purged = (note with { DeletedAt = NoteDocument.Now }).WithoutContent(); var bytes = NoteCodec.Encode(purged);
        Assert.Null(await store.ReceiveAsync(Scope, note.Id, NoteCodec.Digest(bytes), bytes));
        Assert.True((await store.ReadAsync(Scope)).Notes.Single().Document.IsPurged);
    }
    [Fact] public async Task RemovingAFolderKeepsFormattingAndMovesNotesToUnfiled()
    {
        string folder = NoteDocument.FolderKey(Wire.Id()); var note = Note("Bold") with { Folder = folder, RichText = new(1, [new(0, 4, Bold: true)]) };
        await store.SaveAsync(Scope, null, note); await store.RehomeFolderAsync(Scope, folder);
        var moved = (await store.FindAsync(Scope, note.Id))!.Document;
        Assert.Equal("inbox", moved.Folder); Assert.True(moved.RichText!.Spans.Single().Bold);
    }
    [Fact] public async Task SyncWritesAnExplicitNullBaseRevisionAndVerifiesItsReceipt()
    {
        var note = Note(); await store.SaveAsync(Scope, null, note); bool uploaded = false;
        Task<JsonElement> Request(string path, object? body, CancellationToken ct)
        {
            if (body is null) return Task.FromResult(Wire.Value(new NoteIndex([])));
            var json = Wire.Value(body); Assert.Equal(JsonValueKind.Null, json.GetProperty("baseRevision").ValueKind);
            var data = Convert.FromBase64String(json.GetProperty("data").GetString()!); uploaded = true;
            return Task.FromResult(Wire.Value(new NoteReceipt(NoteCodec.Digest(data))));
        }
        await new NoteSync(store).SynchronizeAsync(Scope, NoteCodec.MaxBytes, 1, Request);
        Assert.True(uploaded); Assert.Empty(await store.PendingAsync(Scope));
    }
    [Fact] public async Task AFailedDownloadCannotAuthorizeOverwritingANewerRemoteNote()
    {
        var note = Note(); var bytes = NoteCodec.Encode(note); string firstRevision = NoteCodec.Digest(bytes);
        await store.ReceiveAsync(Scope, note.Id, firstRevision, bytes);
        await store.SaveAsync(Scope, firstRevision, note with { Text = "Unsent local edit" });
        Task<JsonElement> Request(string path, object? body, CancellationToken ct)
        {
            if (path == "/v1/notes") return Task.FromResult(Wire.Value(new NoteIndex([new(note.Id, new string('a', 64))])));
            if (body is null) return Task.FromResult(Wire.Value(new NoteDownload(new string('a', 64), Convert.ToBase64String(bytes))));
            Assert.Equal(firstRevision, Wire.Value(body).GetProperty("baseRevision").GetString()); throw new ApiException(409, "note_conflict");
        }
        await new NoteSync(store).SynchronizeAsync(Scope, NoteCodec.MaxBytes, 1, Request);
        Assert.Single(await store.PendingAsync(Scope)); Assert.NotNull((await store.ReadAsync(Scope)).Error);
    }
    [Fact] public async Task BackupImportAddsCopiesAndRetainsOriginalSharedFormatting()
    {
        var note = Note("hello") with { RichText = new(1, [new(0, 5, Italic: true)]) }; await store.SaveAsync("local", null, note);
        string json = NoteBackup.Export(await store.ReadAsync("local")); var documents = NoteBackup.Import(json, Library.Empty);
        await store.ImportAsync("local", documents);
        var notes = (await store.ReadAsync("local")).Notes;
        Assert.Equal(2, notes.Count); Assert.Equal(2, notes.Select(n => n.Document.Id).Distinct().Count());
        Assert.All(notes, n => Assert.True(n.Document.RichText!.Spans.Single().Italic));
        Assert.Throws<InvalidDataException>(() => NoteBackup.Import("{\"formatVersion\":2,\"notes\":[]}", Library.Empty));
    }
    [Fact] public async Task NoteTransportUsesPutWithoutChangingTaskPostRequests()
    {
        using var handler = new CaptureHandler(); using var http = new HttpClient(handler); var api = new ApiClient(http);
        await api.PutAsync<JsonElement>("https://example.com", "/v1/notes/" + Wire.Id(), new Dictionary<string, JsonElement> { ["baseRevision"] = Wire.Null, ["data"] = Wire.Value("e30=") }, "fixture-token");
        Assert.Equal(HttpMethod.Put, handler.Method); Assert.Equal("fixture-token", handler.Token);
        Assert.Equal(JsonValueKind.Null, JsonDocument.Parse(handler.Body!).RootElement.GetProperty("baseRevision").ValueKind);
        await api.SendAsync<JsonElement>("https://example.com", "/v1/sync/mutations", new { mutations = Array.Empty<Mutation>() });
        Assert.Equal(HttpMethod.Post, handler.Method);
    }
    private static byte[] Png() => Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==");
    private sealed class CaptureHandler : HttpMessageHandler
    {
        public HttpMethod? Method; public string? Body; public string? Token;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Method = request.Method; Token = request.Headers.Authorization?.Parameter;
            Body = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
            return new(HttpStatusCode.OK) { Content = new StringContent("{}", Encoding.UTF8, "application/json") };
        }
    }
}
